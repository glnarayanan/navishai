//go:build linux && amd64

package isolation

import (
	"errors"
	"fmt"
	"syscall"
	"unsafe"
)

type Limits struct {
	CPUSeconds  uint64
	MemoryBytes uint64
	FileBytes   uint64
	OpenFiles   uint64
	Processes   uint64
}

func Apply(limits Limits, denyNetwork, allowNetwork bool, readRoots, writeRoots []string) error {
	if limits.CPUSeconds < 1 || limits.MemoryBytes < 32*1024*1024 || limits.OpenFiles < 3 || limits.Processes < 1 {
		return errors.New("invalid process limits")
	}
	const rlimitProcesses = 6
	for resource, limit := range map[int]uint64{
		syscall.RLIMIT_CPU:    limits.CPUSeconds,
		syscall.RLIMIT_AS:     limits.MemoryBytes,
		syscall.RLIMIT_NOFILE: limits.OpenFiles,
		rlimitProcesses:       limits.Processes,
	} {
		if err := syscall.Setrlimit(resource, &syscall.Rlimit{Cur: limit, Max: limit}); err != nil {
			return err
		}
	}
	if limits.FileBytes > 0 {
		if err := syscall.Setrlimit(syscall.RLIMIT_FSIZE, &syscall.Rlimit{Cur: limits.FileBytes, Max: limits.FileBytes}); err != nil {
			return err
		}
	}
	if denyNetwork == allowNetwork {
		return errors.New("exactly one network policy is required")
	}
	if err := restrictFilesystem(readRoots, writeRoots); err != nil {
		return fmt.Errorf("restrict filesystem: %w", err)
	}
	return restrictNetworkSyscalls(denyNetwork)
}

func restrictFilesystem(readRoots, writeRoots []string) error {
	const (
		landlockCreateRuleset = 444
		landlockAddRule       = 445
		landlockRestrictSelf  = 446
		landlockCreateVersion = 1
		landlockRulePath      = 1
		prSetNoNewPrivileges  = 38
		oPath                 = 0x200000
	)
	const (
		accessExecute = uint64(1 << iota)
		accessWriteFile
		accessReadFile
		accessReadDir
		accessRemoveDir
		accessRemoveFile
		accessMakeChar
		accessMakeDir
		accessMakeReg
		accessMakeSock
		accessMakeFIFO
		accessMakeBlock
		accessMakeSym
		accessRefer
		accessTruncate
	)
	if len(readRoots) == 0 || len(writeRoots) == 0 {
		return errors.New("filesystem roots are required")
	}
	abi, _, errno := syscall.RawSyscall(landlockCreateRuleset, 0, 0, landlockCreateVersion)
	if errno != 0 {
		return fmt.Errorf("query Landlock ABI: %w", errno)
	}
	handled := accessExecute | accessWriteFile | accessReadFile | accessReadDir |
		accessRemoveDir | accessRemoveFile | accessMakeChar | accessMakeDir |
		accessMakeReg | accessMakeSock | accessMakeFIFO | accessMakeBlock | accessMakeSym
	if abi >= 2 {
		handled |= accessRefer
	}
	if abi >= 3 {
		handled |= accessTruncate
	}
	type rulesetAttribute struct{ HandledAccessFS uint64 }
	ruleset := rulesetAttribute{HandledAccessFS: handled}
	fd, _, errno := syscall.RawSyscall(landlockCreateRuleset, uintptr(unsafe.Pointer(&ruleset)), unsafe.Sizeof(ruleset), 0)
	if errno != 0 {
		return fmt.Errorf("create Landlock ruleset: %w", errno)
	}
	defer syscall.Close(int(fd))

	type pathBeneathAttribute struct {
		AllowedAccess uint64
		ParentFD      int32
		_             uint32
	}
	addPath := func(path string, access uint64) error {
		pathFD, err := syscall.Open(path, oPath|syscall.O_CLOEXEC, 0)
		if err != nil {
			return fmt.Errorf("open %q: %w", path, err)
		}
		defer syscall.Close(pathFD)
		var stat syscall.Stat_t
		if err := syscall.Fstat(pathFD, &stat); err != nil {
			return err
		}
		if stat.Mode&syscall.S_IFMT != syscall.S_IFDIR {
			access &= accessReadFile | accessWriteFile | accessTruncate
		}
		attribute := pathBeneathAttribute{AllowedAccess: access & handled, ParentFD: int32(pathFD)}
		_, _, callErr := syscall.RawSyscall6(landlockAddRule, fd, landlockRulePath, uintptr(unsafe.Pointer(&attribute)), 0, 0, 0)
		if callErr != 0 {
			return fmt.Errorf("allow %q: %w", path, callErr)
		}
		return nil
	}
	readAccess := accessExecute | accessReadFile | accessReadDir
	for _, root := range readRoots {
		if err := addPath(root, readAccess); err != nil {
			return err
		}
	}
	for _, root := range writeRoots {
		if err := addPath(root, handled&^accessExecute); err != nil {
			return err
		}
	}
	if _, _, errno := syscall.RawSyscall6(syscall.SYS_PRCTL, prSetNoNewPrivileges, 1, 0, 0, 0, 0); errno != 0 {
		return errno
	}
	_, _, errno = syscall.RawSyscall(landlockRestrictSelf, fd, 0, 0)
	if errno != 0 {
		return fmt.Errorf("enforce Landlock ruleset: %w", errno)
	}
	return nil
}

func restrictNetworkSyscalls(denyNetwork bool) error {
	const (
		prSetNoNewPrivileges   = 38
		prSetSeccomp           = 22
		seccompModeFilter      = 2
		bpfLoadWordAbsolute    = 0x20
		bpfJumpEqual           = 0x15
		bpfAnd                 = 0x54
		bpfReturn              = 0x06
		seccompAllow           = 0x7fff0000
		seccompErrno           = 0x00050000
		seccompKillProcess     = 0x80000000
		auditArchitectureAMD64 = 0xc000003e
		bpfJumpGreaterEqual    = 0x35
		setns                  = 308
		ioUringSetup           = 425
		clone3                 = 435
		cloneNamespaceFlags    = 0x7e020080
	)
	denied := []uint32{
		setns, syscall.SYS_UNSHARE, syscall.SYS_MOUNT, syscall.SYS_UMOUNT2,
	}
	if denyNetwork {
		denied = append(denied,
			syscall.SYS_SOCKET, syscall.SYS_SOCKETPAIR, syscall.SYS_CONNECT,
			syscall.SYS_ACCEPT, syscall.SYS_ACCEPT4, syscall.SYS_BIND, syscall.SYS_LISTEN,
			syscall.SYS_SENDTO, syscall.SYS_RECVFROM, syscall.SYS_SENDMSG, syscall.SYS_RECVMSG,
			ioUringSetup,
		)
	}
	filters := []syscall.SockFilter{
		{Code: bpfLoadWordAbsolute, K: 4},
		{Code: bpfJumpEqual, Jt: 1, Jf: 0, K: auditArchitectureAMD64},
		{Code: bpfReturn, K: seccompKillProcess},
		{Code: bpfLoadWordAbsolute, K: 0},
		{Code: bpfJumpGreaterEqual, Jt: 0, Jf: 1, K: 0x40000000},
		{Code: bpfReturn, K: seccompErrno | uint32(syscall.EPERM)},
	}
	for _, number := range denied {
		filters = append(filters,
			syscall.SockFilter{Code: bpfJumpEqual, Jt: 0, Jf: 1, K: number},
			syscall.SockFilter{Code: bpfReturn, K: seccompErrno | uint32(syscall.EPERM)},
		)
	}
	filters = append(filters,
		syscall.SockFilter{Code: bpfJumpEqual, Jt: 0, Jf: 1, K: clone3},
		syscall.SockFilter{Code: bpfReturn, K: seccompErrno | uint32(syscall.ENOSYS)},
		syscall.SockFilter{Code: bpfJumpEqual, Jt: 0, Jf: 4, K: syscall.SYS_CLONE},
		syscall.SockFilter{Code: bpfLoadWordAbsolute, K: 16},
		syscall.SockFilter{Code: bpfAnd, K: cloneNamespaceFlags},
		syscall.SockFilter{Code: bpfJumpEqual, Jt: 1, Jf: 0, K: 0},
		syscall.SockFilter{Code: bpfReturn, K: seccompErrno | uint32(syscall.EPERM)},
	)
	filters = append(filters, syscall.SockFilter{Code: bpfReturn, K: seccompAllow})
	program := syscall.SockFprog{Len: uint16(len(filters)), Filter: &filters[0]}
	if _, _, errno := syscall.Syscall6(syscall.SYS_PRCTL, prSetNoNewPrivileges, 1, 0, 0, 0, 0); errno != 0 {
		return errno
	}
	if _, _, errno := syscall.Syscall6(
		syscall.SYS_PRCTL, prSetSeccomp, seccompModeFilter,
		uintptr(unsafe.Pointer(&program)), 0, 0, 0,
	); errno != 0 {
		return errno
	}
	return nil
}

package documents

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/glnarayanan/navishai/runner/internal/adapters"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

const MaxInput = 5 * 1024 * 1024
const MaxText = 1024 * 1024
const ExecutableName = "navishai-document"

var ErrUnavailable = errors.New("document conversion unavailable")
var ErrInvalid = errors.New("document conversion failed")
var compoundSignature = []byte{0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1}

type Converter struct {
	root       string
	executable string
	runner     adapters.ProcessRunner
}

func New(root, helper string, excludedRoots ...string) (*Converter, error) {
	if !supervisor.Supported() || !filepath.IsAbs(root) {
		return nil, ErrUnavailable
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, ErrUnavailable
	}
	resolved, err := filepath.EvalSymlinks(root)
	info, statErr := os.Lstat(root)
	if err != nil || statErr != nil || resolved != root || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return nil, ErrUnavailable
	}
	roots := []string{"/usr/lib", "/usr/share/libreoffice", "/usr/share/fonts", "/usr/share/liblangtag", "/etc/fonts", "/etc/libreoffice", "/etc/passwd", "/etc/nsswitch.conf", "/dev/urandom"}
	executable := filepath.Join(filepath.Dir(helper), ExecutableName)
	excludedRoots = append(excludedRoots, filepath.Dir(executable))
	for _, readRoot := range append(append([]string{}, roots...), excludedRoots...) {
		if readRoot == "" {
			continue
		}
		resolvedRead, err := resolveConfiguredRoot(readRoot)
		if err != nil {
			return nil, ErrUnavailable
		}
		relative, err := filepath.Rel(resolvedRead, root)
		if err != nil || (relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))) {
			return nil, ErrUnavailable
		}
	}
	process, err := supervisor.New(supervisor.Config{
		HelperPath: helper, AllowedExecutableRoots: []string{filepath.Dir(executable)}, ApprovedExecutables: []string{executable},
		AllowedWorkingRoots: []string{root}, RuntimeReadRoots: roots,
		Limits: supervisor.Limits{WallTime: 30 * time.Second, CPUSeconds: 20, MemoryBytes: 2 * 1024 * 1024 * 1024, OpenFiles: 128, Processes: 64, OutputBytes: 16 * 1024, FileBytes: 8 * 1024 * 1024, KillGrace: time.Second},
	})
	if err != nil {
		return nil, ErrUnavailable
	}
	return &Converter{root: root, executable: executable, runner: process}, nil
}

func (converter *Converter) Extract(ctx context.Context, content []byte) ([]byte, error) {
	if len(content) > MaxInput || !bytes.HasPrefix(content, compoundSignature) {
		return nil, ErrInvalid
	}
	dir, err := os.MkdirTemp(converter.root, "extract-")
	if err != nil {
		return nil, ErrUnavailable
	}
	defer os.RemoveAll(dir)
	profile := filepath.Join(dir, "profile")
	if os.MkdirAll(filepath.Join(profile, "user"), 0700) != nil {
		return nil, ErrUnavailable
	}
	if os.WriteFile(filepath.Join(profile, "user", "registrymodifications.xcu"), []byte(lockedProfile), 0600) != nil {
		return nil, ErrUnavailable
	}
	if os.WriteFile(filepath.Join(dir, "input.doc"), content, 0600) != nil {
		return nil, ErrUnavailable
	}
	result, err := converter.runner.Run(ctx, supervisor.Request{
		Executable: converter.executable, WorkingDir: dir, HomeDir: dir,

		Credentials: map[string]string{"TMPDIR": dir, "SAL_USE_VCLPLUGIN": "svp", "SAL_DISABLE_OPENCL": "1"},
	})
	if err != nil || result.ExitCode != 0 || result.TimedOut || result.Canceled || result.OutputExceeded {
		return nil, ErrInvalid
	}
	output := filepath.Join(dir, "input.txt")
	info, err := os.Lstat(output)
	if err != nil || !info.Mode().IsRegular() || info.Size() > MaxText {
		return nil, ErrInvalid
	}
	file, err := os.Open(output)
	if err != nil {
		return nil, ErrInvalid
	}
	defer file.Close()
	text, err := io.ReadAll(io.LimitReader(file, MaxText+1))
	if err != nil || len(text) > MaxText || !utf8.Valid(text) || bytes.IndexByte(text, 0) >= 0 {
		return nil, ErrInvalid
	}
	return text, nil
}

const lockedProfile = `<?xml version="1.0" encoding="UTF-8"?><oor:items xmlns:oor="http://openoffice.org/2001/registry"><item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop></item><item oor:path="/org.openoffice.Office.Writer/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>2</value></prop></item></oor:items>`

func resolveConfiguredRoot(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", ErrUnavailable
	}
	suffix := []string{}
	for {
		resolved, err := filepath.EvalSymlinks(path)
		if err == nil {
			for i := len(suffix) - 1; i >= 0; i-- {
				resolved = filepath.Join(resolved, suffix[i])
			}
			return resolved, nil
		}
		if info, statErr := os.Lstat(path); statErr == nil && info.Mode()&os.ModeSymlink != 0 {
			return "", ErrUnavailable
		}
		if !os.IsNotExist(err) || path == filepath.Dir(path) {
			return "", ErrUnavailable
		}
		suffix = append(suffix, filepath.Base(path))
		path = filepath.Dir(path)
	}
}

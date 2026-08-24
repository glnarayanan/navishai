#define _GNU_SOURCE

#include <errno.h>
#include <linux/capability.h>
#include <linux/securebits.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

static int drop_capabilities(void) {
  unsigned int securebits =
      SECBIT_NOROOT | SECBIT_NOROOT_LOCKED |
      SECBIT_NO_SETUID_FIXUP | SECBIT_NO_SETUID_FIXUP_LOCKED |
      SECBIT_KEEP_CAPS_LOCKED |
      SECBIT_NO_CAP_AMBIENT_RAISE | SECBIT_NO_CAP_AMBIENT_RAISE_LOCKED;
  if (prctl(PR_SET_SECUREBITS, securebits, 0, 0, 0) != 0) {
    return -1;
  }
  for (int capability = 0; capability <= CAP_LAST_CAP; capability++) {
    if (prctl(PR_CAPBSET_DROP, capability, 0, 0, 0) != 0 && errno != EINVAL) {
      return -1;
    }
  }
  struct __user_cap_header_struct header = {
      .version = _LINUX_CAPABILITY_VERSION_3,
      .pid = 0,
  };
  struct __user_cap_data_struct data[2] = {{0}};
  if (syscall(SYS_capset, &header, data) != 0) {
    return -1;
  }
  if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) != 0) {
    return -1;
  }
  return prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fputs("missing helper or executable\n", stderr);
    return 125;
  }
  if (setns(3, CLONE_NEWUSER) != 0) {
    perror("cannot enter user namespace");
    return 125;
  }
  if (setns(4, CLONE_NEWNET) != 0) {
    perror("cannot enter network namespace");
    return 125;
  }
  close(3);
  close(4);
  if (drop_capabilities() != 0) {
    fputs("cannot drop namespace capabilities\n", stderr);
    return 125;
  }
  execv(argv[1], &argv[1]);
  fputs("cannot start execution helper\n", stderr);
  return 126;
}

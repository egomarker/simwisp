// Launched with the PTY slave on stdin/out/err. Session/controlling-terminal
// setup runs in this tiny, separate process, never in a forked Swift runtime.
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

extern char **environ;

int main(int argc, char **argv) {
    if (argc != 3) return 64;
    if (setsid() == -1 || ioctl(STDIN_FILENO, TIOCSCTTY, 0) == -1 || chdir(argv[1]) == -1) {
        dprintf(STDERR_FILENO, "Simwisp: cannot start terminal: %s\r\n", strerror(errno));
        return 71;
    }
    char *shell_args[] = {argv[2], "-l", NULL};
    execve(argv[2], shell_args, environ);
    dprintf(STDERR_FILENO, "Simwisp: cannot execute shell: %s\r\n", strerror(errno));
    return 71;
}

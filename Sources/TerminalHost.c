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
    if (argc != 3 && argc != 4) return 64;
    if (setsid() == -1 || ioctl(STDIN_FILENO, TIOCSCTTY, 0) == -1 || chdir(argv[1]) == -1) {
        dprintf(STDERR_FILENO, "Simwisp: cannot start terminal: %s\r\n", strerror(errno));
        return 71;
    }
    char *shell_args[] = {argv[2], "-l", NULL};
    // Positional arguments, never interpolation into shell code. Interactive
    // login startup preserves normal Node/NVM setup; Metro owns this new PTY.
    char *command_args[] = {argv[2], "-l", "-i", "-c", "exec /bin/bash -- \"$1\"", "simwisp-metro", argc == 4 ? argv[3] : NULL, NULL};
    execve(argv[2], argc == 4 ? command_args : shell_args, environ);
    dprintf(STDERR_FILENO, "Simwisp: cannot execute shell: %s\r\n", strerror(errno));
    return 71;
}

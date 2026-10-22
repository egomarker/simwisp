#!/bin/bash
set -Eeuo pipefail
SECONDS=0
stage="setup"
status_file=""
log() { printf '[simwisp +%ss] %s\n' "$SECONDS" "$*" >&2; }
on_error() {
    local code="$1" line="$2" command="$3"
    log "ERROR: $stage failed at line $line (exit $code): $command"
    exit "$code"
}
on_exit() {
    local code=$?
    if (( code != 0 )); then log "FAILED: $stage (exit $code)."; fi
    if [[ -n "$status_file" ]]; then
        printf '%s\n' "$code" > "$status_file.tmp"
        mv -- "$status_file.tmp" "$status_file"
    fi
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap on_exit EXIT
trap 'log "ERROR: interrupted by SIGINT during $stage."; exit 130' INT
trap 'log "ERROR: terminated by SIGTERM during $stage."; exit 143' TERM
trap 'log "ERROR: disconnected by SIGHUP during $stage."; exit 129' HUP

log "Launcher PID $$, parent $PPID; Bash $BASH_VERSION."
if [[ "${1:-}" == --restart-worker ]]; then
    stage="validate restart worker"
    if [[ $# != 3 || ! -d "$3" || ! -O "$3" || ! -p "$3/go" || "${BASH_SOURCE[0]}" != "$3/worker.sh" ]]; then
        log "ERROR: internal worker requires its private handoff directory."
        exit 64
    fi
    directory="$3"
    status_file="$directory/exit-status"
    printf '%s\n' "$$" > "$directory/worker.pid"
    cd -- "$2"
    log "Checkout: $PWD"
    stage="wait for foreground handoff"
    # O_RDWR opens this private FIFO without blocking at open; read has a
    # bounded timeout if the foreground launcher dies before releasing us.
    exec 3<> "$directory/go"
    if ! IFS= read -r -t 5 release <&3; then
        log "ERROR: foreground handoff was not released within 5 seconds; no signal sent."
        exit 1
    fi
    exec 3>&-
    if [[ "$release" != restart ]]; then log "ERROR: invalid handoff; no signal sent."; exit 64; fi
    log "Detached restart worker released; output is saved in $directory/restart.log."
else
    if (( $# != 0 )); then log "ERROR: usage: ./simwisp.sh"; exit 64; fi
    script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    script_path="$script_directory/$(basename -- "${BASH_SOURCE[0]}")"
    cd -- "$script_directory"
    log "Checkout: $PWD"
    stage="build"
    log "Running: make check (no shutdown signal unless the build succeeds)."
    make check
    log "Build succeeded: make check exited 0."

    stage="prepare restart handoff"
    directory="$(mktemp -d "${TMPDIR:-/tmp}/simwisp-restart.XXXXXX")"
    # Copy this exact launcher so later source edits cannot change this job.
    (umask 077; cp -- "$script_path" "$directory/worker.sh"; chmod 600 "$directory/worker.sh"; mkfifo -m 600 "$directory/go"; : > "$directory/restart.log")
    log "Restart log: $directory/restart.log"
    log "Restart status: $directory/exit-status (0 means open accepted, not app readiness)."
    stage="detach restart worker"
    # System Perl is shipped with macOS. Double fork + setsid removes the
    # controlling PTY/session; redirected stdio and closed inherited FDs keep
    # host terminal cleanup from killing or retaining the restart worker.
    /usr/bin/perl - "$directory/worker.sh" "$PWD" "$directory" <<'PERL'
use strict;
use warnings;
use POSIX qw(setsid _exit);
use Fcntl qw(F_SETFD FD_CLOEXEC);
my ($script, $checkout, $directory) = @ARGV;
pipe(my $reader, my $writer) or die "detach pipe: $!\n";
fcntl($writer, F_SETFD, FD_CLOEXEC) or die "detach close-on-exec: $!\n";
my $child = fork();
defined($child) or die "detach fork: $!\n";
if ($child) {
    close($writer);
    my $error = do { local $/; <$reader> };
    close($reader);
    waitpid($child, 0);
    die "detach failed: " . ($error || "intermediate child exit $?\n") if length($error || '') || $? != 0;
    exit 0;
}
close($reader);
eval {
    setsid() != -1 or die "detach setsid: $!\n";
    open(STDIN, '<', '/dev/null') or die "detach stdin: $!\n";
    open(STDOUT, '>>', "$directory/restart.log") or die "detach stdout: $!\n";
    open(STDERR, '>&', \*STDOUT) or die "detach stderr: $!\n";
    opendir(my $fds, '/dev/fd') or die "detach fd directory: $!\n";
    my @fds = grep { /^\d+$/ && $_ > 2 && $_ != fileno($writer) } readdir($fds);
    closedir($fds);
    POSIX::close($_) for @fds;
    my $grandchild = fork();
    defined($grandchild) or die "detach second fork: $!\n";
    _exit(0) if $grandchild;
    exec('/bin/bash', $script, '--restart-worker', $checkout, $directory);
    die "detach exec: $!\n";
};
my $error = $@ || "detach failed\n";
syswrite($writer, $error);
_exit(1);
PERL
    log "Restart worker detached. This terminal may disconnect; check the log/status above."
    # The worker cannot signal the app until the detach acknowledgement and
    # log paths are visible. If this process dies earlier it fails closed.
    printf 'restart\n' > "$directory/go"
    exit 0
fi

# macOS excludes ancestors by default: include them explicitly even after
# detaching, and pin the macOS tools so PATH cannot change -a semantics.
stage="identify user"
uid="$(id -u)"
log "Process selector: exact Simwisp, UID $uid; macOS system tools, ancestors included."
stage="find existing app"
status=0
pids="$(/usr/bin/pgrep -a -u "$uid" -x Simwisp)" || status=$?
case "$status" in
    0) log "Existing Simwisp PID(s): ${pids//$'\n'/, } (snapshot before signalling)." ;;
    1) log "No existing Simwisp process matched (pgrep exit 1)." ;;
    *) log "ERROR: Could not list Simwisp processes (pgrep exit $status)."; exit "$status" ;;
esac
stage="request graceful shutdown"
log "Running: pkill -TERM -a -u $uid -x Simwisp (macOS system tool)"
status=0
/usr/bin/pkill -TERM -a -u "$uid" -x Simwisp || status=$?
case "$status" in
    0) log "Shutdown signal requested (pkill exit 0); exit is not confirmed yet." ;;
    1) log "No matching app at signal time (pkill exit 1); still verifying absence." ;;
    *) log "ERROR: Could not stop Simwisp (pkill exit $status)."; exit "$status" ;;
esac
stage="wait for app exit"
log "Verifying: pgrep -a -u $uid -x Simwisp (up to 100 checks, 0.1s between checks; no force kill)."
for (( attempt = 0; attempt < 100; attempt++ )); do
    status=0
    pids="$(/usr/bin/pgrep -a -u "$uid" -x Simwisp)" || status=$?
    case "$status" in
        1)
            log "Exit confirmed: no matching process (pgrep exit 1; check $((attempt + 1))/100)."
            stage="launch app"
            log "Running: open build/Simwisp.app --args --lan"
            open build/Simwisp.app --args --lan
            log "Launch request accepted (open exit 0). App startup/readiness is not verified."
            exit 0 ;;
        0)
            if (( attempt % 10 == 0 )); then log "Waiting for Simwisp exit: check $((attempt + 1))/100; PID(s): ${pids//$'\n'/, }"; fi
            sleep 0.1 ;;
        *) log "ERROR: Could not verify Simwisp exit (pgrep exit $status)."; exit "$status" ;;
    esac
done
log "ERROR: Simwisp did not exit within 10 seconds; refusing to start another instance. Last seen PID(s): ${pids//$'\n'/, }"
exit 1

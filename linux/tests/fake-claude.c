// A stand-in for Claude on Linux, for the tests. It behaves the way the switcher relies on
// Electron behaving:
//  - it records how it was started (arguments and MY_PEER) in $FAKE_CLAUDE_LOG;
//  - it starts a helper child with --type=renderer and the same --user-data-dir, as
//    Electron does, which the switcher must not take for the account itself;
//  - a second start on a folder already in use hands its arguments (a claude:// link, say)
//    to the first copy and exits, like Electron's single-instance lock.
#define _GNU_SOURCE
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <unistd.h>

static char lockpath[4096];
static pid_t child = 0;

static void on_term(int sig) {
    (void)sig;
    if (child > 0) kill(child, SIGTERM);
    unlink(lockpath);
    _exit(0);
}

int main(int argc, char **argv) {
    const char *log = getenv("FAKE_CLAUDE_LOG");
    if (!log) log = "/tmp/fake-claude-linux.log";
    const char *udd = NULL;
    int helper = 0;
    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "--type=", 7)) helper = 1;
        if (!strncmp(argv[i], "--user-data-dir=", 16)) udd = argv[i] + 16;
    }
    if (helper) {
        prctl(PR_SET_PDEATHSIG, SIGTERM);
        if (getppid() == 1) return 0;
        for (;;) pause();
    }

    const char *dir = udd ? udd : getenv("FAKE_DEFAULT_DIR");
    if (!dir) dir = "/tmp";
    mkdir(dir, 0755);
    snprintf(lockpath, sizeof lockpath, "%s/FakeSingletonLock", dir);

    char args[16384] = "";
    for (int i = 1; i < argc; i++) {
        if (i > 1) strncat(args, "|", sizeof args - strlen(args) - 1);
        strncat(args, argv[i], sizeof args - strlen(args) - 1);
    }
    const char *peer = getenv("MY_PEER");
    if (!peer) peer = "";

    int other = 0;
    FILE *lf = fopen(lockpath, "r");
    if (lf) {
        if (fscanf(lf, "%d", &other) != 1) other = 0;
        fclose(lf);
    }
    FILE *out = fopen(log, "a");
    if (other > 0 && other != getpid() && kill(other, 0) == 0) {
        if (out) { fprintf(out, "pid=%d forwarded-to=%d args=[%s]\n", getpid(), other, args); fclose(out); }
        return 0;
    }
    lf = fopen(lockpath, "w");
    if (lf) { fprintf(lf, "%d\n", getpid()); fclose(lf); }
    if (out) { fprintf(out, "pid=%d args=[%s] MY_PEER=[%s]\n", getpid(), args, peer); fclose(out); }

    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    child = fork();
    if (child == 0) {
        char uddarg[4200];
        if (udd) {
            snprintf(uddarg, sizeof uddarg, "--user-data-dir=%s", udd);
            execl("/proc/self/exe", argv[0], "--type=renderer", uddarg, (char *)NULL);
        } else {
            execl("/proc/self/exe", argv[0], "--type=renderer", (char *)NULL);
        }
        _exit(1);
    }
    for (;;) pause();
}

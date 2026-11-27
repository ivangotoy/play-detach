// Host test of writeStatus() in src/zygisk/main.cpp, called by tests/run.sh.
// tests/run.sh copies writeAll() and writeStatus() out of the real main.cpp
// into status_functions.inc (no Android headers needed) and builds this file
// with the host compiler: native_status <scratch folder>
// The status file is "status" in that folder. Prints "ok <name>" / "FAIL <name>".

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

namespace {
constexpr char kStatusPath[] = "status";
#include "status_functions.inc"
}  // namespace

static int fails = 0;

static void check(const char* name, bool good) {
    printf("%s %s\n", good ? "ok" : "FAIL", name);
    if (!good) fails++;
}

// No status.tmp.<tid> file left in the folder
static bool noTmp() {
    DIR* d = opendir(".");
    if (!d) return false;
    bool clean = true;
    while (struct dirent* e = readdir(d)) {
        if (strncmp(e->d_name, "status.tmp.", 11) == 0) clean = false;
    }
    closedir(d);
    return clean;
}

static bool statusEndsWith(const char* tail) {
    char buf[128] = {0};
    int fd = open("status", O_RDONLY);
    if (fd < 0) return false;
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    size_t t = strlen(tail);
    return n > 0 && static_cast<size_t>(n) >= t && strcmp(buf + n - t, tail) == 0 && strncmp(buf, "loaded=", 7) == 0;
}

int main(int argc, char** argv) {
    if (argc != 2 || chdir(argv[1]) != 0) return 2;

    writeStatus(3);
    check("status written", statusEndsWith(" packages=3\n"));
    check("status written: no temporary file left", noTmp());

    // The rename fails: "status" is a folder with a file in it
    unlink("status");
    mkdir("status", 0700);
    close(open("status/x", O_WRONLY | O_CREAT, 0600));
    writeStatus(4);
    struct stat st;
    check("rename failed: no temporary file left", noTmp());
    check("rename failed: folder untouched", stat("status/x", &st) == 0);
    unlink("status/x");
    rmdir("status");

    // The write fails: a file size limit of 0 (SIGXFSZ ignored) fails every write
    writeStatus(5);
    signal(SIGXFSZ, SIG_IGN);
    struct rlimit old, zero;
    getrlimit(RLIMIT_FSIZE, &old);
    zero = old;
    zero.rlim_cur = 0;
    setrlimit(RLIMIT_FSIZE, &zero);
    writeStatus(6);
    setrlimit(RLIMIT_FSIZE, &old);
    check("write failed: no temporary file left", noTmp());
    check("write failed: old status kept", statusEndsWith(" packages=5\n"));
    unlink("status");
    return fails ? 1 : 0;
}

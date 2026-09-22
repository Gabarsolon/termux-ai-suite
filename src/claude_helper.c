#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <sys/syscall.h>

extern char **environ;

int main(int argc, char** argv) {
    unsetenv("LD_PRELOAD");
    unsetenv("LD_LIBRARY_PATH");

    setenv("SSL_CERT_FILE", "/data/data/com.termux/files/usr/etc/tls/cert.pem", 1);
    setenv("NODE_EXTRA_CA_CERTS", "/data/data/com.termux/files/usr/etc/tls/cert.pem", 1);
    setenv("NODE_OPTIONS", "--dns-result-order=ipv4first", 1);
    setenv("TMPDIR", "/data/data/com.termux/files/usr/tmp", 1);
    setenv("PREFIX", "/data/data/com.termux/files/usr", 1);

    char* home = getenv("HOME");
    if (!home || strcmp(home, "/data") == 0 || strcmp(home, "/") == 0 || strcmp(home, "/root") == 0) {
        setenv("HOME", "/data/data/com.termux/files/home", 1);
    }

    if (!getenv("TERM")) {
        setenv("TERM", "xterm-256color", 1);
    }

    char* current_path = getenv("PATH");
    char new_path[4096];
    if (current_path && !strstr(current_path, "/data/data/com.termux/files/usr/bin")) {
        snprintf(new_path, sizeof(new_path), "/data/data/com.termux/files/usr/bin:%s", current_path);
        setenv("PATH", new_path, 1);
    } else if (!current_path) {
        setenv("PATH", "/data/data/com.termux/files/usr/bin:/system/bin", 1);
    }

    char* loader = "/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1";
    char real_bin[] = "/data/data/com.termux/files/home/.local/share/claude/claude.real";
    char lib_path[] = "/data/data/com.termux/files/usr/glibc/lib";

    char** new_argv = malloc((argc + 4) * sizeof(char*));
    if (!new_argv) {
        return 1;
    }

    new_argv[0] = loader;
    new_argv[1] = "--library-path";
    new_argv[2] = lib_path;
    new_argv[3] = real_bin;

    for (int i = 1; i < argc; i++) {
        new_argv[i + 3] = argv[i];
    }
    new_argv[argc + 3] = NULL;

    syscall(SYS_execve, loader, new_argv, environ);

    perror("execve");
    free(new_argv);
    return 1;
}

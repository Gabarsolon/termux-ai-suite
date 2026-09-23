#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <sys/types.h>

extern char **environ;

static int is_seccomp_active(void) {
    if (getenv("_GLIBC_UNCONFINED")) {
        return 0;
    }
    FILE* f = fopen("/proc/self/status", "r");
    if (!f) return 0;
    char line[256];
    int active = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "Seccomp:", 8) == 0) {
            int val = atoi(line + 8);
            if (val > 0) active = 1;
            break;
        }
    }
    fclose(f);
    return active;
}

static void escape_arg(const char* in, char* out, size_t out_size) {
    size_t j = 0;
    out[j++] = '\'';
    for (size_t i = 0; in[i] && j + 5 < out_size; i++) {
        if (in[i] == '\'') {
            out[j++] = '\'';
            out[j++] = '\\';
            out[j++] = '\'';
            out[j++] = '\'';
        } else {
            out[j++] = in[i];
        }
    }
    out[j++] = '\'';
    out[j] = '\0';
}

int main(int argc, char** argv) {
    if (is_seccomp_active()) {
        uid_t uid = getuid();
        gid_t gid = getgid();

        char su_path[64] = "";
        if (access("/system/bin/su", X_OK) == 0) strcpy(su_path, "/system/bin/su");
        else if (access("/data/adb/ksu/bin/su", X_OK) == 0) strcpy(su_path, "/data/adb/ksu/bin/su");

        if (su_path[0]) {
            char cmd_buf[32768];
            snprintf(cmd_buf, sizeof(cmd_buf), "export _GLIBC_UNCONFINED=1 PATH=/data/data/com.termux/files/usr/bin:$PATH; exec ");

            char exec_path[PATH_MAX];
            ssize_t len = readlink("/proc/self/exe", exec_path, sizeof(exec_path) - 1);
            if (len > 0) {
                exec_path[len] = '\0';
            } else {
                strcpy(exec_path, argv[0]);
            }

            char escaped[PATH_MAX * 2];
            escape_arg(exec_path, escaped, sizeof(escaped));
            strncat(cmd_buf, escaped, sizeof(cmd_buf) - strlen(cmd_buf) - 1);

            for (int i = 1; i < argc; i++) {
                strncat(cmd_buf, " ", sizeof(cmd_buf) - strlen(cmd_buf) - 1);
                char esc_arg[8192];
                escape_arg(argv[i], esc_arg, sizeof(esc_arg));
                strncat(cmd_buf, esc_arg, sizeof(cmd_buf) - strlen(cmd_buf) - 1);
            }

            char uid_str[32], gid_str[32];
            snprintf(uid_str, sizeof(uid_str), "%u", (unsigned int)uid);
            snprintf(gid_str, sizeof(gid_str), "%u", (unsigned int)gid);

            char* su_argv[] = {
                su_path,
                "-p",
                "-g", gid_str,
                "-G", "3003",
                uid_str,
                "-c", cmd_buf,
                NULL
            };

            execv(su_path, su_argv);
        }
    }

    unsetenv("LD_PRELOAD");
    unsetenv("LD_LIBRARY_PATH");

    setenv("GODEBUG", "netdns=cgo", 1);
    setenv("SSL_CERT_FILE", "/data/data/com.termux/files/usr/etc/tls/cert.pem", 1);
    setenv("TMPDIR", "/data/data/com.termux/files/usr/tmp", 1);
    setenv("PREFIX", "/data/data/com.termux/files/usr", 1);

    char* home = getenv("HOME");
    if (!home || strcmp(home, "/data") == 0 || strcmp(home, "/") == 0 || strcmp(home, "/root") == 0) {
        setenv("HOME", "/data/data/com.termux/files/home", 1);
    }
    if (!getenv("TERM")) setenv("TERM", "xterm-256color", 1);

    char* current_path = getenv("PATH");
    char new_path[4096];
    if (current_path && !strstr(current_path, "/data/data/com.termux/files/usr/bin")) {
        snprintf(new_path, sizeof(new_path), "/data/data/com.termux/files/usr/bin:%s", current_path);
        setenv("PATH", new_path, 1);
    } else if (!current_path) {
        setenv("PATH", "/data/data/com.termux/files/usr/bin:/system/bin", 1);
    }

    char* loader = "/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1";
    char real_bin[] = "/data/data/com.termux/files/home/.local/share/opencode/opencode.real";
    char lib_path[] = "/data/data/com.termux/files/usr/glibc/lib";

    char** new_argv = malloc((argc + 4) * sizeof(char*));
    if (!new_argv) return 1;

    new_argv[0] = loader;
    new_argv[1] = "--library-path";
    new_argv[2] = lib_path;
    new_argv[3] = real_bin;
    for (int i = 1; i < argc; i++) new_argv[i + 3] = argv[i];
    new_argv[argc + 3] = NULL;

    syscall(SYS_execve, loader, new_argv, environ);
    perror("execve");
    free(new_argv);
    return 1;
}

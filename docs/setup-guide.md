# Comprehensive Guide: Running OpenCode, Claude Code & Antigravity CLI in Termux (Android 14)

This document details the complete architecture, technical root causes, and exact steps required to install, configure, harden, and run **OpenCode**, **Claude Code**, and **Antigravity CLI (`agy`)** inside Termux on modern Android (Android 14, ARM64) with root (**Magisk** or **KernelSU**) — without needing to run `sudo` manually.

---

## 1. System Architecture & Core Challenges

Android is not a standard GNU/Linux distribution. Attempting to run desktop Linux CLI agents on Android encounters four fundamental barriers:

```
┌─────────────────────────────────────────────────────────────┐
│                       Termux (Bionic)                       │
│  UID: u0_aXXX (e.g. 10171 / 10602)   SELinux: untrusted_app │
└──────────────────────────────┬──────────────────────────────┘
                               │
       ┌───────────────────────┼────────────────────────┐
       ▼                       ▼                        ▼
┌───────────────┐      ┌───────────────┐       ┌─────────────────┐
│   OpenCode    │      │  Claude Code  │       │ Antigravity CLI │
│  (Node / Bun) │      │  (V8 Native)  │       │  (Go + CGO)     │
└───────┬───────┘      └───────┬───────┘       └────────┬────────┘
        │                      │                        │
        └──────────────────────┼────────────────────────┘
                               ▼
            ┌────────────────────────────────────┐
            │       Glibc Compatibility Layer    │
            │      (/usr/glibc/lib/ld.so)        │
            └──────────────────┬─────────────────┘
                               │
            ┌──────────────────┴─────────────────┐
            ▼                                    ▼
┌───────────────────────────────┐   ┌────────────────────────────┐
│      SELinux MLS & Seccomp    │   │     Networking & DNS       │
│ • execute_no_trans on app_data│   │ • Missing /etc/resolv.conf │
│ • Multi-Level Security labels │   │ • Dual-stack IPv6 blackhole│
│   (s0:cXXX,cYYY,c512,c768)    │   │ • Missing table main route │
│ • Zygote Seccomp (faccessat2) │   │ • PMTU handshake drops     │
└───────────────────────────────┘   └────────────────────────────┘
```

1. **C Library Mismatch (Bionic vs. Glibc):** Standard Linux binaries expect GNU `libc.so.6`, `ld-linux-aarch64.so.1`, and dynamic linker conventions absent in Android's native Bionic libc.
2. **SELinux Android 14 Hardening (W^X & MLS Categories):** Android 14 forbids `untrusted_app` contexts from executing binaries directly within application writable data directories (`app_data_file`). Furthermore, each app is constrained to Multi-Level Security (MLS) category pairs (e.g., `s0:c90,c258,c512,c768`). Any file without matching MLS labels triggers `cannot open shared object file: Permission denied`.
3. **Android App Seccomp Sandbox (`invalid system call` / `SIGSYS`):** Zygote applies a Seccomp BPF filter to all app processes. Modern runtimes (Go 1.21+ in Antigravity, Bun in OpenCode) issue modern syscalls such as **`faccessat2` (syscall 439)** or **`clone3` (syscall 435)**. Instead of returning `ENOSYS`, Android's Seccomp filter traps them with `SIGSYS` ("invalid system call").
4. **Go Runtime DNS Resolution Failure:** Go binaries use a pure-Go DNS resolver by default on Linux that expects `/etc/resolv.conf`. Because Android lacks `/etc/resolv.conf`, Go falls back to querying `127.0.0.1:53` and `[::1]:53`, failing with `connect: cannot assign requested address`.
5. **Android Policy Routing & PMTU Black Holes:** Android does not populate a default gateway in the kernel `main` routing table. Large TLS `Client Hello` packets drop silently due to Path MTU (PMTU) black holes, and IPv6 without default internet routes causes connection hangs.

---

## 2. Kernel & SELinux Policy Setup

### A. Magisk vs. KernelSU Policy Patching
To allow Termux to execute glibc binaries residing in `/data/data/com.termux/files`, live SELinux rules must permit `execute_no_trans`:

- **For Magisk:**
  ```bash
  magiskpolicy --live "allow untrusted_app app_data_file file execute_no_trans"
  magiskpolicy --live "allow untrusted_app_all app_data_file file execute_no_trans"
  ```
- **For KernelSU / APatch:**
  ```bash
  /data/adb/ksud sepolicy patch "allow untrusted_app app_data_file file execute_no_trans"
  /data/adb/ksud sepolicy patch "allow untrusted_app_all app_data_file file execute_no_trans"
  ```

### B. Persistent Boot Script
Create a persistent boot service script so all optimizations survive reboots:
**`/data/adb/service.d/opencode_sepolicy.sh`**

```sh
#!/system/bin/sh
# 1. SELinux execution policies
if [ -x /data/adb/ksud ]; then
    /data/adb/ksud sepolicy patch "allow untrusted_app app_data_file file execute_no_trans" 2>/dev/null
    /data/adb/ksud sepolicy patch "allow untrusted_app_all app_data_file file execute_no_trans" 2>/dev/null
elif command -v magiskpolicy >/dev/null 2>&1; then
    magiskpolicy --live "allow untrusted_app app_data_file file execute_no_trans" 2>/dev/null
    magiskpolicy --live "allow untrusted_app_all app_data_file file execute_no_trans" 2>/dev/null
fi

# 2. Network PMTU Black Hole Fix & Route Sync
sysctl -w net.ipv4.tcp_mtu_probing=2 2>/dev/null
ip route add default via 192.168.1.1 dev wlan0 2>/dev/null

# 3. Dual-stack IPv6 Stabilization (Disable on physical, retain on loopback)
sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null
sysctl -w net.ipv6.conf.lo.disable_ipv6=0 2>/dev/null

# 4. Systemless Hosts Bind Mount
[ -f /data/adb/hosts ] && mount --bind /data/adb/hosts /system/etc/hosts 2>/dev/null
```
Make executable:
```bash
chmod 755 /data/adb/service.d/opencode_sepolicy.sh
```

---

## 3. Network, DNS & Systemless Hosts Configuration

### A. Termux DNS & Glibc Sorting
Configure fallback DNS servers in `$PREFIX/etc/resolv.conf`:
```text
nameserver 192.168.1.1
nameserver 1.1.1.1
nameserver 8.8.8.8
```

Symlink it into the glibc environment:
```bash
ln -sf /data/data/com.termux/files/usr/etc/resolv.conf /data/data/com.termux/files/usr/glibc/etc/resolv.conf
```

In `/data/data/com.termux/files/usr/glibc/etc/gai.conf`, prioritize IPv4:
```text
precedence ::ffff:0:0/96  100
```

### B. Systemless Hosts Bind Mount
Android's `/system/etc/hosts` only contains loopback entries. Create `/data/adb/hosts` with static endpoints and bind-mount it over `/system/etc/hosts`:

```text
127.0.0.1 localhost
::1 ip6-localhost
172.65.90.22 opencode.ai
104.20.32.17 models.opencode.ai
160.79.104.10 api.anthropic.com
160.79.104.10 code.claude.com
35.190.46.17 downloads.claude.ai
142.251.127.95 oauth2.googleapis.com
142.251.127.84 accounts.google.com
172.217.115.4 play.googleapis.com
172.217.116.4 cloudaicompanion.googleapis.com
142.251.98.95 cloudresourcemanager.googleapis.com
142.250.130.207 storage.googleapis.com
172.217.119.4 serviceusage.googleapis.com
142.250.130.95 www.googleapis.com
142.250.130.95 googleapis.com
```

Apply universal permissions:
```bash
chmod 644 /data/adb/hosts
chown 0:0 /data/adb/hosts
chcon u:object_r:system_file:s0 /data/adb/hosts
mount --bind /data/adb/hosts /system/etc/hosts
```

---

## 4. Native Hardened C Launchers (Auto-Unconfine Seccomp)

> [!IMPORTANT]
> **Overcoming "Invalid System Call" Without Manual Sudo:**
> When launched inside Termux, processes inherit Zygote's Seccomp filter. Our custom launchers inspect `/proc/self/status` for `Seccomp: 2`. If detected, they re-execute themselves via `su -p -g <GID> -G 3003 <UID> -c "..."`. This drops root privileges immediately back to the standard Termux user while bypassing the Zygote Seccomp sandbox. The user can type `claude`, `opencode`, or `agy` normally without ever typing `sudo`.

### Universal C Launcher Implementation
The launchers for OpenCode, Claude Code, and Antigravity follow this hardened architecture:

```c
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
    if (getenv("_GLIBC_UNCONFINED")) return 0;
    FILE* f = fopen("/proc/self/status", "r");
    if (!f) return 0;
    char line[256];
    int active = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "Seccomp:", 8) == 0) {
            if (atoi(line + 8) > 0) active = 1;
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
    // 1. Auto-unconfine if running under Android App Seccomp
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
            if (len > 0) exec_path[len] = '\0';
            else strcpy(exec_path, argv[0]);

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
                su_path, "-p", "-g", gid_str, "-G", "3003", uid_str, "-c", cmd_buf, NULL
            };
            execv(su_path, su_argv);
        }
    }

    // 2. Clear Bionic conflicts & configure runtime
    unsetenv("LD_PRELOAD");
    unsetenv("LD_LIBRARY_PATH");
    setenv("GODEBUG", "netdns=cgo", 1);
    setenv("SSL_CERT_FILE", "/data/data/com.termux/files/usr/etc/tls/cert.pem", 1);
    setenv("SSL_CERT_DIR", "/data/data/com.termux/files/usr/glibc/etc/ssl/certs", 1);
    setenv("NODE_EXTRA_CA_CERTS", "/data/data/com.termux/files/usr/etc/tls/cert.pem", 1);
    setenv("NODE_OPTIONS", "--dns-result-order=ipv4first", 1);
    setenv("TMPDIR", "/data/data/com.termux/files/usr/tmp", 1);
    setenv("PREFIX", "/data/data/com.termux/files/usr", 1);

    char* home = getenv("HOME");
    if (!home || strcmp(home, "/data") == 0 || strcmp(home, "/") == 0 || strcmp(home, "/root") == 0) {
        setenv("HOME", "/data/data/com.termux/files/home", 1);
    }
    if (!getenv("TERM")) setenv("TERM", "xterm-256color", 1);

    // 3. Invoke glibc loader
    char* loader = "/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1";
    char real_bin[] = "/data/data/com.termux/files/home/.local/share/<TOOL>/<TOOL>.real";
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
```

### Compiling Launchers & Applying MLS Contexts
```bash
export PATH=/data/data/com.termux/files/usr/bin:$PATH

clang -O2 -o /data/data/com.termux/files/usr/bin/opencode /data/data/com.termux/files/usr/share/opencode/opencode_helper.c
clang -O2 -o /data/data/com.termux/files/usr/bin/claude /data/data/com.termux/files/usr/share/claude/claude_helper.c
clang -O2 -o /data/data/com.termux/files/usr/bin/antigravity /data/data/com.termux/files/usr/share/antigravity/antigravity_helper.c
ln -sf /data/data/com.termux/files/usr/bin/antigravity /data/data/com.termux/files/usr/bin/agy

chmod 755 /data/data/com.termux/files/usr/bin/opencode /data/data/com.termux/files/usr/bin/claude /data/data/com.termux/files/usr/bin/antigravity
chown <UID>:<UID> /data/data/com.termux/files/usr/bin/opencode /data/data/com.termux/files/usr/bin/claude /data/data/com.termux/files/usr/bin/antigravity
chcon u:object_r:app_data_file:<MLS_CATEGORY> /data/data/com.termux/files/usr/bin/opencode /data/data/com.termux/files/usr/bin/claude /data/data/com.termux/files/usr/bin/antigravity
chcon -h u:object_r:app_data_file:<MLS_CATEGORY> /data/data/com.termux/files/usr/bin/agy
```

---

## 5. Engines & Binary Placement

The official Linux ARM64 binaries are placed in isolated storage paths:

| Tool | Real Binary Location | Target Architecture |
| :--- | :--- | :--- |
| **OpenCode** | `~/.local/share/opencode/opencode.real` | Linux ARM64 (ELF 64-bit LSB) |
| **Claude Code** | `~/.local/share/claude/claude.real` | Linux ARM64 (Standalone V8) |
| **Antigravity CLI** | `~/.local/share/antigravity/antigravity.real` | Linux ARM64 (Go / CGO dynamic) |

Ensure all `.real` binaries have executable permissions and match Termux ownership:
```bash
chmod 755 ~/.local/share/*/*.real
chown -R <UID>:<UID> ~/.local/share
chcon -R -h u:object_r:app_data_file:<MLS_CATEGORY> ~/.local/share
```

---

## 6. Zero-Login Credential Migration Across Devices

All three CLIs store session states and authentication tokens in standard files within `$HOME`:

| CLI Tool | Credential & State Paths |
| :--- | :--- |
| **OpenCode** | `~/.local/share/opencode/opencode.db*`<br>`~/.local/state/opencode/`<br>`~/.config/opencode/` |
| **Claude Code** | `~/.claude/` (contains `.credentials.json`, `settings.json`)<br>`~/.claude.json` |
| **Antigravity** | `~/.gemini/` (contains `jetski_state.pbtxt`, `antigravity-cli`, `config`) |

### Automated Migration Pipeline via ADB Pipe:
```bash
adb -s <SOURCE_DEVICE> exec-out "su -c 'tar -czf - -C /data/data/com.termux/files/home .claude .claude.json .gemini .config/opencode .local/state/opencode .local/share/opencode/opencode.db*'" | \
adb -s <TARGET_DEVICE> shell "su -c '
tar -xzf - -C /data/data/com.termux/files/home
chown -R <TARGET_UID>:<TARGET_UID> /data/data/com.termux/files/home/.claude /data/data/com.termux/files/home/.claude.json /data/data/com.termux/files/home/.gemini /data/data/com.termux/files/home/.config /data/data/com.termux/files/home/.local
chcon -R -h u:object_r:app_data_file:<TARGET_MLS> /data/data/com.termux/files/home/.claude /data/data/com.termux/files/home/.claude.json /data/data/com.termux/files/home/.gemini /data/data/com.termux/files/home/.config /data/data/com.termux/files/home/.local
'"
```

---

## 7. Verification Commands

Run these directly inside Termux on your device **without sudo**:

```bash
# 1. Check Versions
opencode --version
claude --version
agy --version

# 2. Test OpenCode (Big Pickle model)
opencode run --dir ~ "what is 2+2?"

# 3. Test Claude Code
claude -p "what is 3+3? reply only with the number" < /dev/null

# 4. Test Antigravity CLI (Gemini 3.8 / Pro)
agy models
agy -p "what is 5+5? reply with just the number"
```

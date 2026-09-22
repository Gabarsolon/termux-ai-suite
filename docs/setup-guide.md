# Comprehensive Guide: Running OpenCode, Claude Code & Antigravity CLI in Termux (Android 14)

This document details the complete architecture, technical root causes, and exact steps required to install, configure, harden, and run **OpenCode**, **Claude Code**, and **Antigravity CLI (`agy`)** inside Termux on modern Android (Android 14, ARM64) with root (**Magisk** or **KernelSU**).

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
│      SELinux MLS & Policy     │   │     Networking & DNS       │
│ • execute_no_trans on app_data│   │ • Missing /etc/resolv.conf │
│ • Multi-Level Security labels │   │ • Dual-stack IPv6 blackhole│
│   (s0:cXXX,cYYY,c512,c768)    │   │ • Missing table main route │
└───────────────────────────────┘   └────────────────────────────┘
```

1. **C Library Mismatch (Bionic vs. Glibc):** Standard Linux binaries expect GNU `libc.so.6`, `ld-linux-aarch64.so.1`, and dynamic linker conventions absent in Android's native Bionic libc.
2. **SELinux Android 14 Hardening (W^X & `execute_no_trans`):** Android 14 strictly forbids `untrusted_app` contexts from executing binaries directly within application writable data directories (`app_data_file`). Furthermore, each app is constrained to Multi-Level Security (MLS) category pairs (e.g., `s0:c171,c256...`).
3. **Go Runtime DNS Resolution Failure:** Go binaries (like Antigravity) use a pure-Go DNS resolver by default on Linux that expects `/etc/resolv.conf`. Because Android lacks `/etc/resolv.conf`, Go falls back to querying `127.0.0.1:53` and `[::1]:53`, failing with `connect: cannot assign requested address`.
4. **Android Policy Routing & PMTU Black Holes:** Android does not populate a default gateway in the kernel `main` routing table. Large TLS `Client Hello` packets often drop silently due to Path MTU (PMTU) black holes, and IPv6 without default internet routes causes connection hangs.

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
**`/data/adb/service.d/opencode_sepolicy.sh`** — the repo provides `scripts/bootstrap.sh`, which installs this automatically.

---

## 3. Network, DNS & Systemless Hosts Configuration

### A. Termux DNS & Glibc Sorting
Configure fallback DNS servers in `$PREFIX/etc/resolv.conf` (see `config/resolv.conf`):
```text
nameserver 192.168.1.1
nameserver 1.1.1.1
nameserver 8.8.8.8
```

Symlink it into the glibc environment:
```bash
ln -sf /data/data/com.termux/files/usr/etc/resolv.conf /data/data/com.termux/files/usr/glibc/etc/resolv.conf
```

In `/data/data/com.termux/files/usr/glibc/etc/gai.conf`, prioritize IPv4 to prevent dead IPv6 connection timeouts (see `config/gai.conf`):
```text
precedence ::ffff:0:0/96  100
```

### B. Systemless Hosts Bind Mount
Android's `/system/etc/hosts` only contains loopback entries. Create `/data/adb/hosts` with static endpoints and bind-mount it over `/system/etc/hosts` (see `config/hosts` for full template).

Apply universal permissions:
```bash
chmod 644 /data/adb/hosts
chown 0:0 /data/adb/hosts
chcon u:object_r:system_file:s0 /data/adb/hosts
mount --bind /data/adb/hosts /system/etc/hosts
```

---

## 4. Native Glibc Launcher Wrappers (C Helpers)

Direct shell script wrappers fail when calling foreign binaries because Bionic dynamic variables (`LD_PRELOAD`, `LD_LIBRARY_PATH`) corrupt glibc binaries, and `libtermux-exec` intercepts `execve`.

To solve this permanently, we compile dedicated hardened C launchers (`src/*_helper.c`) that invoke the kernel `SYS_execve` syscall directly.

### D. Compiling Launchers & Setting MLS Categories
Identify the Termux UID and MLS category using `ls -ldZ /data/data/com.termux/files/usr/bin` (e.g., `s0:c90,c258,c512,c768` for UID `10602`):

```bash
export PATH=/data/data/com.termux/files/usr/bin:$PATH

# Compile
clang -O2 -o /data/data/com.termux/files/usr/bin/opencode /data/data/com.termux/files/usr/src/opencode_helper.c
clang -O2 -o /data/data/com.termux/files/usr/bin/claude /data/data/com.termux/files/usr/src/claude_helper.c
clang -O2 -o /data/data/com.termux/files/usr/bin/antigravity /data/data/com.termux/files/usr/src/antigravity_helper.c
ln -sf /data/data/com.termux/files/usr/bin/antigravity /data/data/com.termux/files/usr/bin/agy

# Set Permissions & MLS Contexts (Replace MLS category with your device's specific label)
chmod 755 /data/data/com.termux/files/usr/bin/opencode /data/data/com.termux/files/usr/bin/claude /data/data/com.termux/files/usr/bin/antigravity
chown <TERMUX_UID>:<TERMUX_UID> /data/data/com.termux/files/usr/bin/opencode /data/data/com.termux/files/usr/bin/claude /data/data/com.termux/files/usr/bin/antigravity
chcon u:object_r:app_data_file:<SELINUX_MLS> /data/data/com.termux/files/usr/bin/opencode /data/data/com.termux/files/usr/bin/claude /data/data/com.termux/files/usr/bin/antigravity
chcon -h u:object_r:app_data_file:<SELINUX_MLS> /data/data/com.termux/files/usr/bin/agy
```

`scripts/build.sh` automates all of the above (auto-derives UID + MLS).

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
chown -R <TERMUX_UID>:<TERMUX_UID> ~/.local/share
chcon -R -h u:object_r:app_data_file:<SELINUX_MLS> ~/.local/share
```

---

## 6. Zero-Login Credential Migration Across Devices

All three CLIs store session states and authentication tokens in standard files within `$HOME`. You can migrate full authentication across devices without needing to re-login (`scripts/migrate-credentials.sh` automates this):

| CLI Tool | Credential & State Paths |
| :--- | :--- |
| **OpenCode** | `~/.local/share/opencode/opencode.db*`<br>`~/.local/state/opencode/`<br>`~/.config/opencode/` |
| **Claude Code** | `~/.claude/` (contains `.credentials.json`, `settings.json`)<br>`~/.claude.json` |
| **Antigravity** | `~/.gemini/` (contains `jetski_state.pbtxt`, `antigravity-cli`, `config`) |

---

## 7. Verification Commands

Run these inside Termux on your device to verify everything works end-to-end:

```bash
# 1. Check Versions
opencode --version
claude --version
agy --version

# 2. Test OpenCode (Big Pickle model)
opencode run "what is 2+2?"

# 3. Test Claude Code
claude -p "what is 3+3? reply only with the number" < /dev/null

# 4. Test Antigravity CLI (Gemini 3.8 / Pro)
agy models
agy -p "what is 5+5? reply with just the number"
```
# termux-ai-suite

Run **OpenCode**, **Claude Code**, and **Antigravity CLI** (`agy`) natively inside Termux on rooted Android (Magisk / KernelSU) — without recompiling or virtualization.

## Why

Desktop Linux agent CLIs compiled for glibc fail on Android out of the box due to four barriers:

1. **Bionic vs glibc** — Android's libc lacks `ld-linux-aarch64.so.1` and glibc conventions.
2. **SELinux (Android 14+)** — `untrusted_app` can't `execute_no_trans` binaries in app-data dirs; MLS category enforcement.
3. **Go runtime DNS** — pure-Go resolver needs `/etc/resolv.conf`, which Android doesn't have.
4. **Routing / PMTU** — no default route in `main` table; IPv6 dual-stack blackholes hang connections.

This suite ships the fixes: hardened C launchers that `SYS_execve` the glibc binary via the Termux glibc loader, plus SELinux policy, DNS/flags, systemless hosts, and zero-login credential migration.

## Layout

```
src/                  C launchers (claude, opencode, antigravity)
scripts/
  build.sh            on-device: compile launchers, fix perms/MLS, auto-detect UID
  bootstrap.sh        on-device: SELinux policy + DNS/flags + hosts + boot service
  deploy.sh           host-side: adb push repo + run bootstrap
  migrate-credentials.sh  device-to-device credential copy (no re-login)
config/               resolv.conf, gai.conf, hosts templates
docs/setup-guide.md   full architecture & manual walkthrough
```

## Quick Start

Prerequisites: Termux on both devices (or one), root (Magisk or KernelSU), `adb`, Termux packages `glibc` and `clang`.

```bash
# 1. Get the native engine binaries into Termux on each device:
#    opencode -> ~/.local/share/opencode/opencode.real
#    claude   -> ~/.local/share/claude/claude.real
#    antigravity -> ~/.local/share/antigravity/antigravity.real
#    (glibc loader lives in $PREFIX/usr/glibc/lib/ld-linux-aarch64.so.1)

# 2. Deploy from your host machine:
bash scripts/deploy.sh adb-RZCX10JW7MX-VGYebc._adb-tls-connect._tcp

# 3. On-device compile (auto-detects UID + MLS from $PREFIX/bin):
bash scripts/build.sh
```

If you already ran the pieces manually, `bootstrap.sh` + `build.sh` are idempotent.

### Migrate credentials between devices

```bash
bash scripts/migrate-credentials.sh <src_serial> <tgt_serial>
```

## Verify

```bash
opencode --version
claude --version
agy --version
claude -p "what is 3+3? reply only with the number" < /dev/null
opencode run "what is 2+2?"
```

## Device notes

- S10 (G975F, Android 14 / Magisk): UID 10171, MLS `s0:c171,c256,c512,c768`
- S23 (S911B, Android 16 / KernelSU): UID 10602, MLS `s0:c90,c258,c512,c768`

The launchers run as the normal Termux user (`u0_aXXX`); root is only needed for the SELinux/routing setup and won't make the tools require it at runtime.
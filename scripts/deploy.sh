#!/usr/bin/env bash
# Deploy termux-ai-suite to an Android device over ADB (root required).
#
# Usage: bash scripts/deploy.sh <adb_serial>
#   bash scripts/deploy.sh adb-RZCX10JW7MX-VGYebc._adb-tls-connect._tcp
set -euo pipefail

SERIAL="${1:?usage: deploy.sh <adb_serial>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEV="/data/local/tmp/termux-ai-suite"

adb -s "$SERIAL" shell "su -c 'rm -rf $DEV'" 2>/dev/null || true
adb -s "$SERIAL" push "$REPO/" "$DEV/"
adb -s "$SERIAL" shell "su -c 'sh $DEV/scripts/bootstrap.sh && test -x /data/data/com.termux/files/usr/bin/clang && echo BUILD:clang-ready'"
echo "→ next: run 'bash scripts/build.sh' inside Termux on the device"
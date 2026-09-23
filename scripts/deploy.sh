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

adb -s "$SERIAL" shell "su -c '
    sh $DEV/scripts/bootstrap.sh
    
    TERMUX_HOME=\"/data/data/com.termux/files/home\"
    TERMUX_UID=\$(stat -c %u /data/data/com.termux/files/usr/bin 2>/dev/null || echo 10000)
    MLS=\$(ls -ldZ /data/data/com.termux/files/usr/bin 2>/dev/null | sed -n \"s/.*u:object_r:app_data_file:\\([^ ]*\\).*/\\1/p\")

    mkdir -p \"\$TERMUX_HOME/termux-ai-suite\"
    cp -rf $DEV/* \"\$TERMUX_HOME/termux-ai-suite/\"
    chown -R \"\$TERMUX_UID:\$TERMUX_UID\" \"\$TERMUX_HOME/termux-ai-suite\"
    [ -n \"\$MLS\" ] && chcon -R -h \"u:object_r:app_data_file:\$MLS\" \"\$TERMUX_HOME/termux-ai-suite\"

    if [ -x /data/data/com.termux/files/usr/bin/clang ]; then
        echo \"→ clang detected: building launchers on device...\"
        /data/data/com.termux/files/usr/bin/bash \"\$TERMUX_HOME/termux-ai-suite/scripts/build.sh\"
    else
        echo \"→ clang not found in Termux. Install via: pkg install clang glibc\"
    fi
'"

echo "✓ Deployment complete! Test on device: opencode --version && claude --version && agy --version"
#!/usr/bin/env bash
# Migrate AI CLI credentials from SOURCE device to TARGET device over ADB.
# No re-login needed on target. Requires root on both devices.
#
# Uses a two-stage transfer (host-staged tarball) because piping tar through
# `adb shell` stdin gets corrupted by the adbd PTY banner.
#
# Usage: bash scripts/migrate-credentials.sh <src_serial> <tgt_serial>
#   bash scripts/migrate-credentials.sh adb-R58M63MVMJM-... adb-RZCX10JW7MX-...
set -euo pipefail

SRC="${1:?usage: migrate-credentials.sh <src_serial> <tgt_serial>}"
TGT="${2:?usage: migrate-credentials.sh <src_serial> <tgt_serial>}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TBALL="$TMP/creds.tar.gz"

TGT_UID="$(adb -s "$TGT" shell "su -c 'stat -c %u /data/data/com.termux/files/usr/bin'" | tr -d '\r')"
TGT_MLS="$(adb -s "$TGT" shell "su -c 'ls -ldZ /data/data/com.termux/files/usr/bin'" | awk -F\"u:object_r:app_data_file:\" '{print $2}' | awk '{print $1}' | tr -d '\r')"
TGT_HOME="/data/data/com.termux/files/home"
TGT_STAGE="/data/local/tmp/creds.tar.gz"

echo "→ src=$SRC tgt=$TGT"
echo "→ target UID=$TGT_UID MLS=$TGT_MLS"

echo "→ stage tarball from $SRC"
# Note: cd into HOME so relative-absolute paths don't leak warning noise into the
# stream; stderr is dropped because adb exec-out merges it into stdout.
adb -s "$SRC" exec-out "su -c 'cd /data/data/com.termux/files/home && tar -czf - \
    .claude .claude.json .gemini \
    .config/opencode .local/state/opencode .local/share/opencode/opencode.db* 2>/dev/null'" > "$TBALL"
ls -lh "$TBALL"

echo "→ push to $TGT"
adb -s "$TGT" push "$TBALL" "$TGT_STAGE"

echo "→ extract + fix ownership/SELinux"
adb -s "$TGT" shell "su -c 'tar -xzpf $TGT_STAGE -C $TGT_HOME; rm -f $TGT_STAGE; chown -R $TGT_UID:$TGT_UID \"$TGT_HOME/.claude\" \"$TGT_HOME/.claude.json\" \"$TGT_HOME/.gemini\" \"$TGT_HOME/.config/opencode\" \"$TGT_HOME/.local\" 2>/dev/null || true; chcon -R -h u:object_r:app_data_file:$TGT_MLS \"$TGT_HOME/.claude\" \"$TGT_HOME/.claude.json\" \"$TGT_HOME/.gemini\" \"$TGT_HOME/.config/opencode\" \"$TGT_HOME/.local\" 2>/dev/null || true'" | tail -5

echo "✓ credentials migrated to $TGT"
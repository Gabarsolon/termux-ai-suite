#!/data/data/com.termux/files/usr/bin/bash
# Build the three AI CLI launchers on-device.
# Run inside Termux on the Android device (root required for chcon/chown).
#
# Usage: bash scripts/build.sh
set -euo pipefail

PREFIX="/data/data/com.termux/files/usr"
export PATH="$PREFIX/bin:$PATH"
HOME_DIR="/data/data/com.termux/files/home"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Device-specific values, auto-derived
TERMUX_UID="$(stat -c %u "$PREFIX/bin")"
TERMUX_GID="$TERMUX_UID"
MLS="$(ls -ldZ "$PREFIX/bin" | sed -n 's/.*u:object_r:app_data_file:\([^ ]*\).*/\1/p')"

echo "→ UID=$TERMUX_UID MLS=$MLS"

declare -A BABEL=(
  [opencode]="opencode.real:opencode_helper.c"
  [claude]="claude.real:claude_helper.c"
  [antigravity]="antigravity.real:antigravity_helper.c"
)

cd "$SRC_DIR/src"

for name in opencode claude antigravity; do
  IFS=':' read -r real cfile <<< "${BABEL[$name]}"
  echo "→ building $name (target: $HOME_DIR/.local/share/$name/$real)"
  clang -O2 -o "$PREFIX/bin/$name" "$cfile"
  chmod 755 "$PREFIX/bin/$name"
  chown "$TERMUX_UID:$TERMUX_GID" "$PREFIX/bin/$name"
  chcon "u:object_r:app_data_file:$MLS" "$PREFIX/bin/$name"
done

# agy symlink → antigravity
ln -sf "$PREFIX/bin/antigravity" "$PREFIX/bin/agy"
chcon -h "u:object_r:app_data_file:$MLS" "$PREFIX/bin/agy"

# Ensure engine binaries and configs have proper MLS & ownership
if [ -d "$HOME_DIR/.local" ]; then
  chown -R "$TERMUX_UID:$TERMUX_GID" "$HOME_DIR/.local"
  chcon -R -h "u:object_r:app_data_file:$MLS" "$HOME_DIR/.local"
fi
for item in .claude .claude.json .gemini .config; do
  if [ -e "$HOME_DIR/$item" ]; then
    chown -R "$TERMUX_UID:$TERMUX_GID" "$HOME_DIR/$item"
    chcon -R -h "u:object_r:app_data_file:$MLS" "$HOME_DIR/$item"
  fi
done

echo "✓ Launchers built:"
for b in opencode claude antigravity agy; do
  "$PREFIX/bin/$b" --version 2>&1 | sed "s/^/  $b /"
done
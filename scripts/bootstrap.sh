#!/system/bin/sh
# One-shot device provisioning: SELinux policy, network/DNS fixes, systemless hosts.
# Idempotent. Must run as root. Survives reboot via /data/adb/service.d.
#
# On-device usage:      sh /data/local/tmp/termux-ai-suite/scripts/bootstrap.sh
# Via host:            bash scripts/deploy.sh <serial>
set -u

PREFIX="/data/data/com.termux/files/usr"
HWADDR="$(getprop ro.boot.wifi.interface 2>/dev/null)"
[ -z "$HWADDR" ] && HWADDR="wlan0"
ROUTER="${ROUTER:-192.168.1.1}"

echo "→ SELinux policy"
if [ -x /data/adb/ksud ]; then
    /data/adb/ksud sepolicy patch "allow untrusted_app app_data_file file execute_no_trans" 2>/dev/null
    /data/adb/ksud sepolicy patch "allow untrusted_app_all app_data_file file execute_no_trans" 2>/dev/null
elif command -v magiskpolicy >/dev/null 2>&1; then
    magiskpolicy --live "allow untrusted_app app_data_file file execute_no_trans" 2>/dev/null
    magiskpolicy --live "allow untrusted_app_all app_data_file file execute_no_trans" 2>/dev/null
fi

echo "→ resolv.conf"
mkdir -p "$PREFIX/etc" "$PREFIX/glibc/etc"
cat > "$PREFIX/etc/resolv.conf" <<EOF
nameserver $ROUTER
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:3
EOF
ln -sf "$PREFIX/etc/resolv.conf" "$PREFIX/glibc/etc/resolv.conf"

echo "→ gai.conf (IPv4 precedence)"
cat > "$PREFIX/glibc/etc/gai.conf" <<EOF
precedence ::ffff:0:0/96  100
EOF

# Ensure Termux unprivileged user can read resolv.conf and gai.conf
TERMUX_UID="$(stat -c %u "$PREFIX/bin" 2>/dev/null || echo 10000)"
MLS="$(ls -ldZ "$PREFIX/bin" 2>/dev/null | sed -n 's/.*u:object_r:app_data_file:\([^ ]*\).*/\1/p')"
if [ -n "$MLS" ]; then
    chown -R "$TERMUX_UID:$TERMUX_UID" "$PREFIX/etc/resolv.conf" "$PREFIX/glibc/etc" 2>/dev/null || true
    chcon -R -h "u:object_r:app_data_file:$MLS" "$PREFIX/etc/resolv.conf" "$PREFIX/glibc/etc" 2>/dev/null || true
fi

echo "→ systemless hosts"
mkdir -p /data/adb
cat > /data/adb/hosts <<'EOF'
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
EOF
chmod 644 /data/adb/hosts
chown 0:0 /data/adb/hosts
chcon u:object_r:system_file:s0 /data/adb/hosts
mount --bind /data/adb/hosts /system/etc/hosts 2>/dev/null || true

echo "→ boot persistence script"
mkdir -p /data/adb/service.d
cat > /data/adb/service.d/opencode_sepolicy.sh <<EOF
#!/system/bin/sh
if [ -x /data/adb/ksud ]; then
    /data/adb/ksud sepolicy patch "allow untrusted_app app_data_file file execute_no_trans" 2>/dev/null
    /data/adb/ksud sepolicy patch "allow untrusted_app_all app_data_file file execute_no_trans" 2>/dev/null
elif command -v magiskpolicy >/dev/null 2>&1; then
    magiskpolicy --live "allow untrusted_app app_data_file file execute_no_trans" 2>/dev/null
    magiskpolicy --live "allow untrusted_app_all app_data_file file execute_no_trans" 2>/dev/null
fi
sysctl -w net.ipv4.tcp_mtu_probing=2 2>/dev/null
ip route add default via $ROUTER dev $HWADDR 2>/dev/null
sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null
sysctl -w net.ipv6.conf.lo.disable_ipv6=0 2>/dev/null
[ -f /data/adb/hosts ] && mount --bind /data/adb/hosts /system/etc/hosts 2>/dev/null
EOF
chmod 755 /data/adb/service.d/opencode_sepolicy.sh

# Apply network fixes immediately
sysctl -w net.ipv4.tcp_mtu_probing=2 2>/dev/null
sysctl -w net.ipv6.conf.all.disable_ipv6=1 2>/dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=1 2>/dev/null
sysctl -w net.ipv6.conf.lo.disable_ipv6=0 2>/dev/null
ip route add default via $ROUTER dev $HWADDR 2>/dev/null

echo "✓ bootstrap complete"
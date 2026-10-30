#!/bin/sh
# Run inside the unpacked release directory on QWRT/fw3.
set -eu
umask 077
cd "$(dirname "$0")"
for command in lua iptables ipset tailscale curl flock timeout; do command -v "$command" >/dev/null;done
tailscale set --help >/dev/null 2>&1
test -f /usr/lib/lua/luci/jsonc.so -o -f /usr/lib/lua/luci/jsonc.lua
test -f root/usr/share/dualroute/cn-ipv4.txt
lua -e 'assert(loadfile("root/usr/lib/dualroute/control.lua"));assert(loadfile("root/usr/lib/lua/luci/controller/dualroute.lua"))'
lua test_model.lua root/usr/lib/dualroute
backup="/root/dualroute-backup/install-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup" /etc/dualroute /tmp/dualroute
cp -p /etc/config/network /etc/config/firewall /etc/config/dhcp /etc/config/openclash "$backup/"
if [ -f /etc/config/dualroute ]; then cp -p /etc/config/dualroute "$backup/";fi
if [ -x /etc/init.d/dualroute ]; then /etc/init.d/dualroute stop;fi
cp -R root/usr/. /usr/
cp -R root/www/. /www/
cp root/etc/init.d/dualroute /etc/init.d/dualroute
if [ ! -f /etc/config/dualroute ]; then cp root/etc/config/dualroute /etc/config/dualroute;fi
chmod 755 /usr/sbin/dualroute /etc/init.d/dualroute
chmod 700 /tmp/dualroute /etc/dualroute
# Lua/template and static assets must remain readable to the authenticated web service.
find /usr/lib/dualroute -type f -exec chmod 644 {} \;
find /www/luci-static/resources/dualroute -type f -exec chmod 644 {} \;
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
/usr/sbin/dualroute selftest
/etc/init.d/dualroute enable
/etc/init.d/dualroute start
printf 'Installed. Backup: %s\n' "$backup"

#!/bin/sh
# Run on the router with the verified official archive as argument.
set -eu
umask 077
archive=$1
expected=a1c249ce6bdebef62e1ae3b997595555bce2ae4709bf95a718e9ca7a129dad7e
test "$(sha256sum "$archive" | cut -d' ' -f1)" = "$expected"
backup=/root/dualroute-backup/tailscale-before-1.104.4
test ! -e "$backup"
mkdir -p "$backup" /tmp/dualroute-ts-upgrade
cp -p /usr/sbin/tailscale /usr/sbin/tailscaled "$backup/"
cp -p /etc/config/network "$backup/network"
cp -p /etc/init.d/tailscale "$backup/init-tailscale"
ls -l /etc/rc.d/*tailscale > "$backup/rc-links.txt"
tar -xzf "$archive" -C /tmp/dualroute-ts-upgrade
/tmp/dualroute-ts-upgrade/tailscale_1.104.4_arm64/tailscale version
/etc/init.d/tailscale stop
cp -p /etc/tailscale/tailscaled.state "$backup/tailscaled.state"
rollback() {
 /etc/init.d/tailscale stop || true
 cp -p "$backup/tailscale" "$backup/tailscaled" /usr/sbin/
 cp -p "$backup/tailscaled.state" /etc/tailscale/tailscaled.state
 /etc/init.d/tailscale start
}
trap rollback 1 2 15
cp /tmp/dualroute-ts-upgrade/tailscale_1.104.4_arm64/tailscale /usr/sbin/tailscale
cp /tmp/dualroute-ts-upgrade/tailscale_1.104.4_arm64/tailscaled /usr/sbin/tailscaled
chmod 755 /usr/sbin/tailscale /usr/sbin/tailscaled
# Tailscale owns addresses; netifd only associates the existing device with its zone.
uci set network.tailscale.proto=none
uci -q delete network.tailscale.ipaddr || true
uci -q delete network.tailscale.netmask || true
uci commit network
# Remove only an obsolete duplicate autostart link for this same service.
if [ "$(readlink /etc/rc.d/S90tailscale 2>/dev/null)" = '../init.d/tailscale' ]; then
 rm /etc/rc.d/S90tailscale
fi
/etc/init.d/tailscale enable
/etc/init.d/tailscale start
ready=0
for n in 1 2 3 4 5 6 7 8 9 10; do
 if [ "$(tailscale status --json 2>/dev/null | jsonfilter -e @.BackendState)" = Running ]; then ready=1;break;fi
 sleep 2
done
if [ "$ready" != 1 ]; then rollback;exit 1;fi
tailscale version
tailscale status --json | jsonfilter -e @.BackendState -e @.TailscaleIPs
ip -4 addr show dev tailscale0
printf 'Backup: %s\n' "$backup"

#!/usr/bin/env python3
"""Build a dependency-free LuCI package and an inspectable tar installer."""
import io
import hashlib
from pathlib import Path
import tarfile

BASE = Path(__file__).resolve().parent
REPO = BASE.parent
OUT = REPO / 'dist' / 'openwrt'
VERSION = '0.1.0'

def archive(files):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w:gz', format=tarfile.GNU_FORMAT) as tar:
        for name, data, mode in sorted(files):
            info = tarfile.TarInfo('./' + name)
            info.size, info.mode, info.uid, info.gid = len(data), mode, 0, 0
            info.mtime = 0
            tar.addfile(info, io.BytesIO(data))
    return stream.getvalue()

def text(name, value, mode=0o644):
    return name, value.encode(), mode

def main():
    files = []
    for path in (BASE / 'root').rglob('*'):
        if path.is_file() and path.name not in {'cn-ipv4.txt', 'cn-ipv4-source.json', '.DS_Store'}:
            name = str(path.relative_to(BASE / 'root'))
            files.append((name, path.read_bytes(), 0o755 if name.startswith(('usr/sbin/', 'etc/init.d/')) else 0o644))
    for name in ('cn-ipv4.txt', 'cn-ipv4-source.json'):
        files.append(('usr/share/dualroute/' + name, (REPO / 'data' / name).read_bytes(), 0o644))
    control = f'''Package: luci-app-dualroute
Version: {VERSION}
Architecture: all
Maintainer: DualRoute
Section: luci
Priority: optional
Description: Tailscale IPv4 split routing and subnet management for QWRT fw3
'''
    preinst = '''#!/bin/sh
set -eu
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
for cmd in lua iptables ipset ip curl flock timeout tailscale; do command -v "$cmd" >/dev/null; done
tailscale set --help >/dev/null 2>&1
test -x /etc/init.d/openclash
iptables -V | grep -q legacy
lua -e 'require("luci.jsonc");require("luci.model.uci")'
umask 077
target="/root/dualroute-backup/package-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$target"
for file in network firewall dhcp openclash dualroute; do
 [ ! -f "/etc/config/$file" ] || cp -p "/etc/config/$file" "$target/"
done
'''
    postinst = '''#!/bin/sh
set -eu
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
umask 077
mkdir -p /etc/dualroute /tmp/dualroute
chmod 700 /etc/dualroute /tmp/dualroute
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/6C7563692E636F6E74726F6C6C65722E6475616C726F757465
/usr/sbin/dualroute selftest
/etc/init.d/dualroute enable
/etc/init.d/dualroute restart
'''
    prerm = '''#!/bin/sh
set -eu
[ -n "${IPKG_INSTROOT:-}" ] && exit 0
/etc/init.d/dualroute stop
if [ "${1:-}" = upgrade ]; then exit 0; fi
case "$(uci -q get dualroute.main.mode)" in
 tailscale|switching|error) /usr/sbin/dualroute openclash ;;
esac
/etc/init.d/dualroute disable
'''
    control_tar = archive([text('control', control), text('conffiles', '/etc/config/dualroute\n'),
                           text('preinst', preinst, 0o755), text('postinst', postinst, 0o755),
                           text('prerm', prerm, 0o755)])
    OUT.mkdir(parents=True, exist_ok=True)
    ipk = OUT / f'luci-app-dualroute_{VERSION}_all.ipk'
    # OpenWrt ipkg-build uses a gzip tar container, not Debian's ar container.
    ipk.write_bytes(archive([('debian-binary', b'2.0\n', 0o644),
                             ('control.tar.gz', control_tar, 0o644),
                             ('data.tar.gz', archive(files), 0o644)]))
    installer = OUT / f'dualroute-openwrt-{VERSION}.tar.gz'
    bundle = [('root/' + name, data, mode) for name, data, mode in files]
    bundle.extend((name, (BASE / name).read_bytes(), 0o755) for name in ('install.sh', 'test_model.lua'))
    bundle.append(('使用说明.md', (REPO / 'docs' / 'openwrt-usage.md').read_bytes(), 0o644))
    installer.write_bytes(archive(bundle))
    checksums = ''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in (ipk, installer))
    (OUT / 'SHA256SUMS').write_text(checksums)
    print(ipk)
    print(installer)

if __name__ == '__main__':
    main()

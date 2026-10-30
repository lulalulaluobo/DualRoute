"""IPv4 split routing for the existing local Tailscale gateway. No dependencies."""
import datetime
import ipaddress
import json
import os
import subprocess
from pathlib import Path

BASE = Path('/Library/Application Support/CodexTailscaleGateway')
PUBLIC = Path('/var/run/codex-ts-gateway-status.json')
LAN_NET = ipaddress.ip_network('192.168.0.0/16')
DEFAULT = {'mode': 'full', 'gateway': '192.168.2.1', 'extra_direct': []}
EXCLUDED = [ipaddress.ip_network(n) for n in (
    '0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8',
    '169.254.0.0/16','172.16.0.0/12','192.0.0.0/24','192.0.2.0/24',
    '192.88.99.0/24','192.168.0.0/16','198.18.0.0/15','198.51.100.0/24',
    '203.0.113.0/24','224.0.0.0/4','240.0.0.0/4')]

def safe_network(n):
    return n.is_global and not any(n.overlaps(x) for x in EXCLUDED)

def atomic(path, data, mode=0o600):
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(data)
    tmp.chmod(mode)
    tmp.replace(path)

def command(*args):
    return subprocess.run(args, text=True, capture_output=True, timeout=15)

def validate_config(c):
    if not isinstance(c, dict) or set(c) - set(DEFAULT):
        raise ValueError('未知配置字段')
    c = dict(DEFAULT, **c)
    if c['mode'] not in ('split', 'full'):
        raise ValueError('未知模式')
    gateway = ipaddress.IPv4Address(c['gateway'])
    if gateway not in LAN_NET or gateway in (LAN_NET.network_address, LAN_NET.broadcast_address, ipaddress.IPv4Address('192.168.2.123')):
        raise ValueError('网关必须是本地网段内的主路由，不能填写 Mac 自身地址')
    if not isinstance(c['extra_direct'], list) or len(c['extra_direct']) > 256:
        raise ValueError('额外规则最多 256 条')
    nets = [ipaddress.IPv4Network(n, strict=True) for n in c['extra_direct']]
    if any(not safe_network(n) or n.prefixlen < 8 for n in nets):
        raise ValueError('仅接受全球可路由 IPv4 CIDR，掩码不得小于 /8')
    if any(ipaddress.IPv4Address('1.1.1.1') in n for n in nets):
        raise ValueError('1.1.1.1 用于出口检测和默认 DNS，不可加入直连网段')
    c['extra_direct'] = [str(n) for n in ipaddress.collapse_addresses(nets)]
    return c

def config():
    p = BASE/'split-config.json'
    return validate_config(json.loads(p.read_text()) if p.exists() else DEFAULT)

def desired(c):
    if c['mode'] != 'split': return []
    lines = (BASE/'cn-ipv4.txt').read_text().splitlines()
    nets = [ipaddress.IPv4Network(n) for n in lines if n and not n.startswith('#')]
    if not 1000 < len(nets) < 20000 or any(not safe_network(n) for n in nets):
        raise ValueError('国内地址库无效，保留当前配置')
    return [str(n) for n in ipaddress.collapse_addresses(nets + [ipaddress.IPv4Network(n) for n in c['extra_direct']])]

def normalize_destination(s, flags):
    if s == 'default': return '0.0.0.0/0'
    address, sep, prefix = s.partition('/')
    parts = address.split('.')
    if not all(x.isdigit() for x in parts) or len(parts) > 4: return None
    if not sep: prefix = '32' if 'H' in flags else str(8 * len(parts))
    try: return str(ipaddress.IPv4Network('.'.join(parts + ['0'] * (4-len(parts)))+'/'+prefix, strict=False))
    except ValueError: return None

def route_snapshot():
    p = command('/usr/sbin/netstat','-rn','-f','inet')
    if p.returncode: raise RuntimeError(p.stderr)
    result = {}
    for line in p.stdout.splitlines():
        f = line.split()
        if len(f) < 4 or 'I' in f[2]: continue # Do not touch scoped routes.
        n = normalize_destination(f[0], f[2])
        if n: result[n] = {'gateway': f[1], 'flags': f[2], 'interface': f[3]}
    return result

def publish(message, interface='', error=''):
    try: c=config()
    except Exception: c=DEFAULT
    count=0
    p=BASE/'owned-routes.json'
    if p.exists(): count=len(json.loads(p.read_text()))
    atomic(PUBLIC, json.dumps(dict(c, status=message, interface=interface,
        lan_ip='192.168.2.123', route_count=count, error=error,
        updated_at=datetime.datetime.now(datetime.timezone.utc).isoformat()), ensure_ascii=False), 0o644)

def prepare():
    c = config(); nets=desired(c)
    content='\n'.join(nets)+'\n'
    p=BASE/'cn-active.txt'
    if not p.exists() or p.read_text()!=content: atomic(p,content)
    return c,nets

def sync(c,nets,interface):
    p=BASE/'owned-routes.json'
    owned=json.loads(p.read_text()) if p.exists() else {}
    snapshot=route_snapshot(); wanted=set(nets); gateway=c['gateway']; problems=[]
    saved=BASE/'redirect-original.txt'
    if c['mode']=='split':
        if not saved.exists(): atomic(saved,command('/usr/sbin/sysctl','-n','net.inet.ip.redirect').stdout.strip())
        r=command('/usr/sbin/sysctl','-w','net.inet.ip.redirect=0')
        if r.returncode: raise RuntimeError(r.stderr)
    # Delete only exact routes tracked by this task, still pointing to their recorded gateway.
    for net, oldgateway in list(owned.items()):
        if net in wanted and oldgateway==gateway: continue
        current=snapshot.get(net)
        if current and current['gateway']==oldgateway and current['interface']=='en0':
            r=command('/sbin/route','-n','delete','-net',net,oldgateway)
            if r.returncode:
                problems.append('删除失败 '+net); continue
        owned.pop(net,None)
        snapshot.pop(net,None)
    atomic(p,json.dumps(owned))
    pending=[]
    for net in nets:
        current=snapshot.get(net)
        if current and current['gateway']==gateway and current['interface']=='en0': continue
        if current and not ('W' in current['flags'] and current['interface'].startswith('utun')):
            problems.append('现有路由冲突 '+net); continue
        pending.append(net)
    if pending: publish('正在恢复国内路由，请稍候',interface)
    for offset in range(0,len(pending),100):
        batch=pending[offset:offset+100]
        # Persist intent before additions so interruption does not orphan our routes.
        owned.update({n:gateway for n in batch});atomic(p,json.dumps(owned))
        for net in batch:
            r=command('/sbin/route','-n','add','-net',net,gateway)
            if r.returncode:
                owned.pop(net,None); problems.append('添加失败 '+net)
        atomic(p,json.dumps(owned))
    if problems: raise RuntimeError('; '.join(problems[:4])+f'（共 {len(problems)} 项）')
    # Stop sending ICMP redirects for en0 -> en0 forwarding.
    if c['mode']=='full' and saved.exists():
        v=saved.read_text().strip()
        if v not in ('0','1'): raise ValueError('无效的 redirect 备份')
        r=command('/usr/sbin/sysctl','-w','net.inet.ip.redirect='+v)
        if r.returncode: raise RuntimeError(r.stderr)

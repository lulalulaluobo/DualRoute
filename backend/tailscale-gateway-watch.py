import ipaddress, json, os, re, subprocess, sys, tempfile, fcntl
from pathlib import Path

BASE = Path('/Library/Application Support/CodexTailscaleGateway')
sys.path.insert(0, str(BASE))
try:
    import split_engine as split
except ModuleNotFoundError:
    split = None
ANCHOR = 'com.apple/codex-ts-gateway-test'
CLIENT_NET = '192.168.0.0/16'
LAN_PROBE = '192.168.2.61'
TS_IP = '100.118.146.48'
LAN = 'en0'

def run(*args, check=True):
    p = subprocess.run(args, text=True, capture_output=True, timeout=12)
    if check and p.returncode:
        raise RuntimeError(p.stderr.strip() or p.stdout.strip() or str(args))
    return p.stdout

def detect_interface(text, address):
    current = None
    for line in text.splitlines():
        if line and not line[0].isspace():
            current = line.split(':',1)[0]
        if re.search(r'\binet '+re.escape(address)+r'\s',line):
            return current

def make_rules(interface, split_enabled=False):
    assert re.fullmatch(r'utun\d+',interface)
    table = f'table <codex_cn> persist file "{BASE}/cn-active.txt"\n' if split_enabled else ''
    localnat = f'nat on {LAN} inet from {CLIENT_NET} to <codex_cn> -> ({LAN})\n' if split_enabled else ''
    dns_exception = f'no rdr on {LAN} inet proto {{ tcp udp }} from {CLIENT_NET} to {{ 223.5.5.5, 119.29.29.29 }} port 53\n' if split_enabled else ''
    localpass = f'pass out quick on {LAN} inet from ({LAN}) to <codex_cn> keep state\n' if split_enabled else ''
    return table + f'''scrub in on {LAN} inet from {CLIENT_NET} to any max-mss 1240
scrub out on {LAN} inet from any to {CLIENT_NET} max-mss 1240
nat on {interface} inet from {CLIENT_NET} to any -> ({interface})
{localnat}{dns_exception}rdr on {LAN} inet proto {{ tcp udp }} from {CLIENT_NET} to ! {CLIENT_NET} port 53 -> 1.1.1.1 port 53
pass in quick on {LAN} inet from {CLIENT_NET} to any keep state
{localpass}pass out quick on {interface} inet from {TS_IP} to any keep state
'''

def status(message):
    if split:
        split.publish(message, globals().get('ACTIVE_INTERFACE',''), message if message.startswith('错误') else '')
    p=BASE/'status.txt'
    old=p.read_text() if p.exists() else ''
    if old!=message:
        p.write_text(message)
        print(message,flush=True)

def main():
    global ACTIVE_INTERFACE
    if (BASE/'disabled').exists(): return
    cfg,nets=split.prepare() if split else ({'mode':'full'},[])
    # Cleanup must remain available even when Tailscale is offline.
    if split and cfg['mode']=='full': split.sync(cfg,nets,'')
    interface=detect_interface(run('/sbin/ifconfig'),TS_IP)
    if not interface or not re.fullmatch(r'utun\d+',interface):
        status('等待 Tailscale 接口');return
    ACTIVE_INTERFACE=interface
    route=run('/sbin/route','-n','get','1.1.1.1')
    if not re.search(r'interface: '+interface+r'\s',route):
        status('等待 Tailscale 出口路由');return
    lanconfig=run('/sbin/ifconfig',LAN)
    addresses=re.findall(r'inet (\S+) netmask (0x[0-9a-f]+)',lanconfig)
    if not any(str(ipaddress.IPv4Network((address,str(ipaddress.IPv4Address(int(mask,16)))),strict=False))==CLIENT_NET for address,mask in addresses):
        status('局域网网段已变化，未修改 PF');return
    lanroute=run('/sbin/route','-n','get',LAN_PROBE)
    if not re.search(r'interface: '+LAN+r'\s',lanroute):
        status('局域网回程未走本地 en0，未修改 PF');return
    nat=run('/sbin/pfctl','-sn')
    filt=run('/sbin/pfctl','-sr')
    if not nat.strip() and not filt.strip():
        # Only initialize the existing system file if no rules are loaded.
        run('/sbin/pfctl','-nf','/etc/pf.conf')
        run('/sbin/pfctl','-f','/etc/pf.conf')
        nat=run('/sbin/pfctl','-sn');filt=run('/sbin/pfctl','-sr')
    if 'nat-anchor "com.apple/*"' not in nat or 'anchor "com.apple/*"' not in filt or 'scrub-anchor "com.apple/*"' not in filt:
        status('系统 PF 锚点缺失，未覆盖现有规则');return
    rules=make_rules(interface,cfg['mode']=='split')
    oldnat=run('/sbin/pfctl','-a',ANCHOR,'-sn')
    previous=(BASE/'active.pf').read_text() if (BASE/'active.pf').exists() else ''
    enabled='Status: Enabled' in run('/sbin/pfctl','-s','info')
    changed=previous!=rules or f'nat on {interface} inet from {CLIENT_NET}' not in oldnat or not enabled
    if changed:
        with tempfile.NamedTemporaryFile(mode='w',dir=BASE,delete=False) as f:
            f.write(rules);path=f.name
        try:
            run('/sbin/pfctl','-a',ANCHOR,'-nf',path)
            run('/sbin/pfctl','-a',ANCHOR,'-f',path)
            if not enabled:
                p=subprocess.run(['/sbin/pfctl','-E'],capture_output=True,text=True,check=True)
                token=re.search(r'Token\s*:\s*(\d+)',p.stdout+p.stderr)
                if not token:raise RuntimeError('PF token missing')
                with (BASE/'pf-tokens.txt').open('a') as f:f.write(token.group(1)+'\n')
            (BASE/'active.pf').write_text(rules)
            run('/sbin/pfctl','-k',CLIENT_NET)
            run('/sbin/pfctl','-k','0.0.0.0/0','-k',CLIENT_NET)
        finally:
            Path(path).unlink(missing_ok=True)
    if run('/usr/sbin/sysctl','-n','net.inet.ip.forwarding').strip()!='1':
        run('/usr/sbin/sysctl','-w','net.inet.ip.forwarding=1')
    if split and cfg['mode']=='split':
        # Refresh the anchor-local table in place after list edits; preserve other PF rules.
        run('/sbin/pfctl','-a',ANCHOR,'-t','codex_cn','-T','replace','-f',str(BASE/'cn-active.txt'))
        split.sync(cfg,nets,interface)
        status(f'正常：国内 IPv4 → {cfg["gateway"]}；其余 → {interface} → Tailscale')
    else:
        status(f'正常：{CLIENT_NET} → {interface} → Tailscale 出口')

if __name__=='__main__':
    os.umask(0o077)
    try:
        with (BASE/'watch.lock').open('a') as lock:
            try: fcntl.flock(lock,fcntl.LOCK_EX | (0 if '--wait' in sys.argv else fcntl.LOCK_NB))
            except BlockingIOError: sys.exit(0)
            main()
    except Exception as exc:
        status('错误：'+str(exc))
        sys.exit(1)

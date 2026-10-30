package.path=(arg[1] or '/usr/lib/dualroute')..'/?.lua;'..package.path
local m=require('model')
assert(m.peername({DNSName='bwg-us.example.ts.net.',HostName='ethical-hat-2'})=='bwg-us')
assert(m.peername({HostName='fallback'})=='fallback')
assert(m.peername({DNSName='',TailscaleIPs={'100.1.2.3'}})=='100.1.2.3')
assert(m.ip('0.0.0.0')==0)
assert(m.ip('255.255.255.255')==4294967295)
for _,v in ipairs({'256.1.2.3','1.2.3','1.2.3.4; reboot','-1.2.3.4','1.2.3.4\n'}) do assert(not m.ip(v),v) end
assert(m.contains('192.168.2.0/24','192.168.2.255'))
assert(not m.contains('192.168.2.0/24','192.168.3.1'))
assert(m.contains('0.0.0.0/0','255.255.255.255'))
assert(m.contains('100.98.228.92/32','100.98.228.92'))
assert(not m.contains('100.98.228.92/32','100.98.228.93'))
assert(m.overlap('192.168.0.0/16','192.168.2.0/24'))
assert(not m.overlap('192.168.2.0/24','192.168.3.0/24'))
assert(#m.routes('192.168.2.0/24, 10.0.0.0/8\n192.168.2.0/24')==2)
assert(#m.routes('')==0)
for _,v in ipairs({'0.0.0.0/0','192.168.2.51/24','1.2.3.4/33','1.2.3.4/32;reboot','1.2.3.999/32'}) do assert(not pcall(m.routes,v),v) end
print('PASS: IPv4 边界、CIDR 归属、网段冲突、去重与恶意参数拒绝')

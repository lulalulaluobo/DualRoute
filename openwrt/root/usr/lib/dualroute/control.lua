package.path='/usr/lib/dualroute/?.lua;'..package.path
local m=require('model')
local json=require('luci.jsonc')
local uci=require('luci.model.uci').cursor()
local fs=require('nixio.fs')
local sys=require('luci.sys')
local D,B='/tmp/dualroute/','/etc/dualroute/'
local function q(s) return "'"..tostring(s):gsub("'","'\\''").."'" end
local function read(cmd) return sys.exec(cmd..' 2>/dev/null') end
local function atomic(path,s) assert(fs.writefile(path..'.tmp',s));assert(fs.rename(path..'.tmp',path)) end
local function run(cmd,optional)
 local s=fs.stat(D..'command.log');if s and s.size>32768 then fs.remove(D..'command.log') end
 local code=sys.call('('..cmd..') >>'..D..'command.log 2>&1')
 if code~=0 and not optional then error('执行失败：'..cmd) end
 return code==0
end
local function log(s)
 local old=fs.readfile(D..'events.log') or '';if #old>24000 then old=old:sub(-12000) end
 atomic(D..'events.log',old..os.date('%Y-%m-%d %H:%M:%S ')..s..'\n')
end
local function state(message,err) atomic(D..'state.json',json.stringify({message=message,error=err or '',updated=os.time()})) end
local function cfg()
 uci:load('dualroute');local c=uci:get_all('dualroute','main') or {}
 assert((c.lan or ''):match('^[%w_.-]+$'),'LAN 设备无效')
 assert(m.ip(c.gateway) and m.cidr(c.subnet) and m.contains(c.subnet,c.gateway),'网关与 LAN 网段不匹配')
 return c
end
local function save(k,v) uci:set('dualroute','main',k,v);uci:commit('dualroute') end
local function ts() return json.parse(read('timeout 8 tailscale status --json')) or {} end
local function prefs() return json.parse(read('timeout 8 tailscale debug prefs')) or {} end
local function oc() return read('pidof clash_meta clash mihomo'):match('%d')~=nil end
local function setargs(args)
 local a={};for _,v in ipairs(args) do a[#a+1]='--'..v[1]..'='..q(v[2]) end
 run('timeout 25 tailscale set '..table.concat(a,' '))
end
local function exitset(ip) setargs({{'exit-node',ip or ''},{'exit-node-allow-lan-access',ip and ip~='' and 'true' or 'false'}}) end
local function networkprefs(p)
 local routes={};local adv=false
 for _,r in ipairs(p.AdvertiseRoutes or {}) do if r=='0.0.0.0/0' or r=='::/0' then adv=true else routes[#routes+1]=r end end
 return {hostname=p.Hostname or '',routes=table.concat(routes,','),accept_routes=p.RouteAll==true,advertise_exit=adv}
end
local function routeprefixes()
 local list={}
 for line in read('ip -4 route show table 52'):gmatch('[^\n]+') do
  local r=line:match('^(%d+%.%d+%.%d+%.%d+/%d+)')
  if not r then local ip=line:match('^(%d+%.%d+%.%d+%.%d+)%s');if ip then r=ip..'/32' end end
  local _,p=m.cidr(r);if p and p>1 then list[#list+1]=r end
 end
 table.sort(list);return list
end
local function status()
 local c,t=cfg(),ts();local peers={}
 for _,p in pairs(t.Peer or {}) do peers[#peers+1]={name=m.peername(p),hostname=p.HostName,ip=(p.TailscaleIPs or {})[1],online=p.Online==true,
  exit=p.ExitNodeOption==true,selected=p.ExitNode==true,relay=p.Relay or '',direct=p.CurAddr or '',rx=p.RxBytes or 0,tx=p.TxBytes or 0} end
 table.sort(peers,function(a,b)return (a.name or '')<(b.name or '') end)
 local login=fs.readfile(D..'login.log') or ''
 local cur=json.parse(fs.readfile(D..'state.json') or '{}') or {}
 return {mode=c.mode,exit_node=c.exit_node,gateway=c.gateway,lan=c.lan,subnet=c.subnet,dns_log=c.dns_log=='1',
  extra_direct=c.extra_direct or '',tailscale=t.BackendState or 'Unknown',version=read('tailscale version | head -1'):gsub('%s+$',''),
  ips=t.TailscaleIPs or {},peers=peers,health=t.Health or {},network=networkprefs(prefs()),routes=routeprefixes(),openclash=oc(),
  login_url=login:match('(https://[%w./_%-]+)'),state=cur,exit_ip=fs.readfile(D..'exit-ip') or '',
  rules=read('ipset list dr_cn -terse'):match('Number of entries: (%d+)') or '0',
  rx=tonumber(fs.readfile('/sys/class/net/tailscale0/statistics/rx_bytes') or '') or 0,
  tx=tonumber(fs.readfile('/sys/class/net/tailscale0/statistics/tx_bytes') or '') or 0}
end
local hooks={{'mangle','PREROUTING','DR_PRE'},{'mangle','OUTPUT','DR_OUT'},{'mangle','FORWARD','DR_MSS'},
 {'nat','POSTROUTING','DR_NAT'},{'nat','PREROUTING','DR_DNS'},{'filter','FORWARD','DR_FWD'}}
local function remove_rules()
 for _,r in ipairs(hooks) do local b='iptables -w 5 -t '..r[1]
  while run(b..' -C '..r[2]..' -j '..r[3]..' 2>/dev/null',true) do run(b..' -D '..r[2]..' -j '..r[3]) end
  run(b..' -F '..r[3]..' 2>/dev/null',true);run(b..' -X '..r[3]..' 2>/dev/null',true)
 end
 run('ip rule del pref 5100 fwmark 0x100000/0x100000 lookup 201 2>/dev/null',true)
 run('ip rule del pref 5100 fwmark 0x1000000/0x1000000 lookup 201 2>/dev/null',true)
 run('ip route flush table 201',true)
 fs.remove(D..'routes.signature')
end
local function dns_begin()
 if not fs.access(B..'dns-prefs.json') then atomic(B..'dns-prefs.json',json.stringify({accept_dns=prefs().CorpDNS==true})) end
 setargs({{'accept-dns','false'}})
 if not fs.access(B..'resolv-before') then atomic(B..'resolv-before',fs.readfile('/etc/resolv.conf') or '') end
end
local function dns(c)
 if not fs.access(B..'dhcp-before') then run('cp /etc/config/dhcp '..B..'dhcp-before') end
 run('uci -q delete dhcp.@dnsmasq[0].server',true)
 run('uci set dhcp.@dnsmasq[0].noresolv=1')
 run("uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'")
 run("uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'")
 -- Domestic CDN resolution must use the household ISP path as well.
 local domains={}
 for d in io.lines('/usr/share/dualroute/dns-domestic.txt') do
  assert(d:match('^[%w.-]+$'),'国内 DNS 后缀无效');domains[#domains+1]=d
 end
 local suffix='/'..table.concat(domains,'/')..'/'
 for _,resolver in ipairs({'223.5.5.5','119.29.29.29'}) do
  run('uci add_list dhcp.@dnsmasq[0].server='..q(suffix..resolver))
 end
 run('uci set dhcp.@dnsmasq[0].logqueries='..(c.dns_log=='1' and '1' or '0'))
 run('uci commit dhcp');run('timeout 30 /etc/init.d/dnsmasq restart')
 assert(fs.writefile('/etc/resolv.conf','nameserver 127.0.0.1\n'))
end
local function cleanup()
 remove_rules();exitset('')
 if fs.access(B..'dhcp-before') then
  run('cp '..B..'dhcp-before /etc/config/dhcp');run('timeout 30 /etc/init.d/dnsmasq restart');fs.remove(B..'dhcp-before')
 end
 if fs.access(B..'resolv-before') then assert(fs.writefile('/etc/resolv.conf',fs.readfile(B..'resolv-before')));fs.remove(B..'resolv-before') end
 local dp=json.parse(fs.readfile(B..'dns-prefs.json') or '{}') or {}
 if dp.accept_dns~=nil then setargs({{'accept-dns',tostring(dp.accept_dns)}});fs.remove(B..'dns-prefs.json') end
 local old=json.parse(fs.readfile(B..'sysctl-before.json') or '{}') or {}
 for k,v in pairs(old) do if k:match('^net%.ipv4%.[%w_.]+$') and tostring(v):match('^[01]$') then run('sysctl -w '..k..'='..v,true) end end
 fs.remove(B..'sysctl-before.json');run('ipset destroy dr_cn 2>/dev/null',true);fs.remove(D..'exit-ip')
end
local function rules(c)
 local old={}
 for _,k in ipairs({'net.ipv4.conf.all.send_redirects','net.ipv4.conf.'..c.lan..'.send_redirects'}) do old[k]=read('sysctl -n '..k):match('%d') end
 if not fs.access(B..'sysctl-before.json') then atomic(B..'sysctl-before.json',json.stringify(old)) end
 run('sysctl -w net.ipv4.ip_forward=1 net.ipv4.conf.all.send_redirects=0 net.ipv4.conf.'..c.lan..'.send_redirects=0')
 -- Prepare a replacement set before swapping, keeping a valid set throughout refresh.
 run('ipset destroy dr_cn_new 2>/dev/null',true);run('ipset create dr_cn_new hash:net family inet maxelem 30000')
 local input={};for line in io.lines('/usr/share/dualroute/cn-ipv4.txt') do
  if line~='' then assert(m.cidr(line),'国内规则数据无效');input[#input+1]='add dr_cn_new '..line end
 end
 assert(#input>1000,'国内规则数据不足')
 for _,r in ipairs(m.routes(c.extra_direct or '')) do input[#input+1]='add dr_cn_new '..r end
 atomic(D..'ipset.restore',table.concat(input,'\n')..'\n');run('ipset restore -exist < '..D..'ipset.restore')
 run('ipset create dr_cn hash:net family inet maxelem 30000 -exist');run('ipset swap dr_cn_new dr_cn');run('ipset destroy dr_cn_new')
 remove_rules()
 run('ip route add '..q(c.subnet)..' dev '..q(c.lan)..' table 201')
 run('ip route add default via '..q(c.gateway)..' dev '..q(c.lan)..' table 201')
 run('ip rule add pref 5100 fwmark 0x1000000/0x1000000 lookup 201')
 for _,r in ipairs(hooks) do run('iptables -w 5 -t '..r[1]..' -N '..r[3]) end
 local exclude={'0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8','169.254.0.0/16','172.16.0.0/12','192.168.0.0/16','224.0.0.0/4','240.0.0.0/4'}
 local remote=routeprefixes()
 for _,r in ipairs(remote) do exclude[#exclude+1]=r end
 exclude[#exclude+1]=c.subnet
 for _,chain in ipairs({'DR_PRE','DR_OUT'}) do
  local b='iptables -w 5 -t mangle -A '..chain
  if chain=='DR_PRE' then run(b..' ! -i '..q(c.lan)..' -j RETURN');run(b..' ! -s '..q(c.subnet)..' -j RETURN') end
  run(b..' -m mark --mark 0x80000/0xff0000 -j RETURN')
  for _,r in ipairs(exclude) do run(b..' -d '..q(r)..' -j RETURN') end
  run(b..' -m set --match-set dr_cn dst -j MARK --set-xmark 0x1000000/0x1000000')
  run(b..' -m mark --mark 0x1000000/0x1000000 -j CONNMARK --save-mark --nfmask 0x1000000 --ctmask 0x1000000')
 end
 run('iptables -w 5 -t nat -A DR_NAT -s '..q(c.subnet)..' -o tailscale0 -j MASQUERADE')
 -- Locally generated packets may already have a Tailscale source before OUTPUT rerouting.
 run('iptables -w 5 -t nat -A DR_NAT -o '..q(c.lan)..' -m mark --mark 0x1000000/0x1000000 -j MASQUERADE')
 for _,p in ipairs({'tcp','udp'}) do run('iptables -w 5 -t nat -A DR_DNS -i '..q(c.lan)..' -s '..q(c.subnet)..' -p '..p..' --dport 53 -j REDIRECT --to-ports 53') end
 run('iptables -w 5 -A DR_FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT')
 run('iptables -w 5 -A DR_FWD -i '..q(c.lan)..' -s '..q(c.subnet)..' -o tailscale0 -j ACCEPT')
 run('iptables -w 5 -A DR_FWD -i '..q(c.lan)..' -s '..q(c.subnet)..' -o '..q(c.lan)..' -j ACCEPT')
 for _,dir in ipairs({'-o','-i'}) do run('iptables -w 5 -t mangle -A DR_MSS '..dir..' tailscale0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1240') end
 for _,r in ipairs(hooks) do run('iptables -w 5 -t '..r[1]..' -I '..r[2]..' 1 -j '..r[3]) end
 atomic(D..'routes.signature',table.concat(remote,','))
end
local function stopoc()
 uci:set('openclash','config','enable','0');uci:commit('openclash');run('timeout 60 /etc/init.d/openclash stop')
 assert(not oc(),'OpenClash 尚未停止')
end
local function startoc()
 uci:set('openclash','config','enable','1');uci:commit('openclash');run('timeout 60 /etc/init.d/openclash start')
end
local function check_exit(ip,t)
 assert(m.ip(ip),'出口 IP 无效')
 for _,p in pairs(t.Peer or {}) do if p.ExitNodeOption and p.Online and (p.TailscaleIPs or {})[1]==ip then return end end
 error('所选节点不在线，或尚未获准提供出口')
end
local function probe()
 run('curl -4 -f -sS --retry 2 --retry-all-errors --retry-delay 1 --max-time 10 https://api4.ipify.org -o '..D..'exit-ip')
 assert(m.ip((fs.readfile(D..'exit-ip') or ''):gsub('%s','')),'出口检测返回无效 IP')
 run('curl -4 -f -sS --max-time 15 https://www.baidu.com -o /dev/null')
end
local function activate(ip)
 local c,t=cfg(),ts();assert(t.BackendState=='Running','请先登录 Tailscale');check_exit(ip,t)
 assert(not networkprefs(prefs()).advertise_exit,'请先关闭本机广播出口，再使用 VPS 出口')
 if c.mode~='tailscale' then
  assert(read('ip -4 route show table 201')=='','路由表 201 已被其他服务占用')
  assert(not read('ip -4 rule'):match('\n5100:'),'策略优先级 5100 已被其他服务占用')
 end
 local old=c.mode or 'openclash';save('previous_mode',old);save('mode','switching');state('正在切换到 Tailscale');log('切换出口 '..ip)
 local ok,err=pcall(function() stopoc();dns_begin();exitset(ip);rules(c);dns(c);probe() end)
 if not ok then
  log('切换失败，回退：'..tostring(err))
  local restored,why=pcall(function()
   cleanup()
   if old=='tailscale' then dns_begin();exitset(c.exit_node);rules(c);dns(c);probe()
   elseif old=='openclash' then startoc() end
  end)
  if not restored then log('回退失败：'..tostring(why)) end
  save('mode',restored and old or 'error');state('切换失败',restored and '已恢复原模式，详细原因见日志。' or '回退未完成，请查看日志。')
  error(err)
 end
 save('exit_node',ip);save('mode','tailscale');state('国内 IPv4 直连，其余公网 IPv4 走 VPS');log('分流启用成功')
end
local function other(mode)
 local c=cfg();state('正在切换模式')
 -- Stop an existing transparent proxy before restoring direct operation.
 if mode=='off' and oc() then stopoc() end
 if c.mode=='tailscale' or c.mode=='switching' or c.mode=='error' or fs.access(B..'dhcp-before') then cleanup() end
 if mode=='openclash' then startoc() end
 save('mode',mode);state(mode=='openclash' and 'OpenClash 接管公网' or '公网分流关闭，保留 Tailscale 组网');log('模式 '..mode)
end
local function settings(data)
 local c=cfg();local p=prefs();local before=networkprefs(p)
 assert(type(data)=='table','配置格式无效')
 assert(type(data.hostname)=='string' and #data.hostname<=63 and (data.hostname=='' or data.hostname:match('^[%w][%w%-]*$')),'设备名无效')
 local routes=m.routes(data.routes or '')
 assert(type(data.accept_routes)=='boolean' and type(data.advertise_exit)=='boolean','开关参数无效')
 assert(not(data.advertise_exit and c.mode=='tailscale'),'使用 VPS 出口期间不能广播本机为出口')
 local extra=m.routes(data.extra_direct or '')
 assert(type(data.dns_log)=='boolean','DNS 日志参数无效')
 if data.accept_routes then
  for _,peer in pairs(ts().Peer or {}) do for _,r in ipairs(peer.PrimaryRoutes or {}) do
   assert(not m.overlap(r,c.subnet),'远端子网与本地 LAN 重叠：'..r)
  end end
 end
 local function apply(n)
  setargs({{'hostname',n.hostname},{'advertise-routes',n.routes},{'accept-routes',tostring(n.accept_routes)},{'advertise-exit-node',tostring(n.advertise_exit)}})
 end
 local ok,err=pcall(function()
  apply({hostname=data.hostname,routes=table.concat(routes,','),accept_routes=data.accept_routes,advertise_exit=data.advertise_exit})
  save('extra_direct',table.concat(extra,','));save('dns_log',data.dns_log and '1' or '0')
  if c.mode=='tailscale' then local updated=cfg();rules(updated);dns(updated) end
 end)
 if not ok then
  local restored,why=pcall(function() apply(before);save('extra_direct',c.extra_direct or '');save('dns_log',c.dns_log or '0');if c.mode=='tailscale' then rules(c);dns(c) end end)
  error(tostring(err)..(restored and '；配置已回退' or '；回退失败 '..tostring(why)))
 end
 state('配置已保存；新广播网段需在 Tailscale 控制台批准');log('更新组网与分流偏好')
end
local function connections()
 local out,c={},cfg();local f=io.open('/proc/net/nf_conntrack','r');if not f then return out end
 for line in f:lines() do
  local src,dst,sp,dp=line:match('src=(%S+) dst=(%S+) sport=(%d+) dport=(%d+)')
  if src and m.contains(c.subnet,src) then
   local mark=tonumber(line:match('mark=(%d+)') or '0');local cn=math.floor(mark/16777216)%2==1
   local path='未由双径接管'
   if c.mode=='tailscale' then
    if m.contains(c.subnet,dst) then path='局域网'
    elseif cn then path='国内/自定义直连'
    else path='Tailscale / 其他路由' end
   end
   out[#out+1]={source=src..':'..sp,target=dst,port=dp,protocol=line:match('^ipv4%s+%d+%s+(%S+)') or '',path=path,
    bytes=line:match('bytes=(%d+)') or '0',state=line:match('(ESTABLISHED)') or line:match('(UNREPLIED)') or '活动'}
   if #out>=300 then break end
  end
 end
 f:close();return out
end
local function watchdog()
 local c=cfg()
 -- Keep asynchronous web jobs and diagnostic output bounded in RAM.
 for path in fs.glob(D..'job-*.result') do local st=fs.stat(path);if st and os.time()-st.mtime>3600 then fs.remove(path) end end
 local jl=fs.stat(D..'jobs.log');if jl and jl.size>32768 then fs.remove(D..'jobs.log') end
 if c.mode=='switching' then
  log('上次切换中断，恢复 OpenClash');other('openclash')
 elseif c.mode=='tailscale' then
  if uci:get('openclash','config','enable')=='1' or oc() then other('openclash')
  else
   local t=ts();local found=false
   for _,p in pairs(t.Peer or {}) do if p.ExitNode and (p.TailscaleIPs or {})[1]==c.exit_node and p.Online then found=true end end
   if t.BackendState~='Running' or not found then state('出口不可用','国内直连仍保留；请检查 Tailscale 或切换 OpenClash');return end
   local intact=true
   for _,r in ipairs(hooks) do if not run('iptables -w 5 -t '..r[1]..' -C '..r[2]..' -j '..r[3]..' 2>/dev/null',true) then intact=false end end
   if not read('ip -4 rule'):match('5100:%s+from all fwmark 0x1000000/0x1000000 lookup 201') then intact=false end
   if not read('ip -4 route show table 201'):find('default via '..c.gateway,1,true) then intact=false end
   if not run('ipset list dr_cn -terse >/dev/null 2>&1',true) then intact=false end
   if not intact then rules(c);dns(c);log('已恢复路由与 DNS 规则')
   elseif (fs.readfile(D..'routes.signature') or '')~=table.concat(routeprefixes(),',') then rules(c);log('已刷新远端子网路由') end
   state('国内 IPv4 直连，其余公网 IPv4 走 VPS')
  end
 end
end
local function main()
 fs.mkdirr(D);fs.mkdirr(B)
 local action=arg[1]
 if action=='status' then print(json.stringify(status()))
 elseif action=='connections' then print(json.stringify(connections()))
 elseif action=='logs' then print(json.stringify({events=fs.readfile(D..'events.log') or '',dns=read("logread | grep 'dnsmasq.*query\\[' | tail -n 100"),service=read("logread | grep -E 'tailscaled|dualroute' | tail -n 80")}))
 elseif action=='login' then run('tailscale up --timeout=8s >'..D..'login.log 2>&1',true);state('请打开授权链接完成登录')
 elseif action=='tailscale' then activate(arg[2])
 elseif action=='openclash' or action=='off' then other(action)
 elseif action=='settings' then local data=json.parse(io.read('*a') or '');settings(data)
 elseif action=='watchdog' or action=='repair' then watchdog();if action=='repair' and cfg().mode~='tailscale' then state(oc() and 'OpenClash 正在运行' or '当前未启用公网分流') end
 elseif action=='selftest' then cfg();assert(fs.access('/usr/share/dualroute/cn-ipv4.txt'));print('配置与运行依赖检查通过')
 else error('未知操作') end
end
local ok,err=pcall(main)
if not ok then
 log(tostring(err));local current=json.parse(fs.readfile(D..'state.json') or '{}') or {}
 if not current.error or current.error=='' then state('操作未完成','请查看日志中的详细原因。') end
 io.stderr:write(tostring(err)..'\n');os.exit(1)
end

module('luci.controller.dualroute',package.seeall)
function index()
 entry({'admin','services','dualroute'},template('dualroute/index'),'双径 · Tailscale',60).dependent=false
 entry({'admin','services','dualroute','api'},call('api')).leaf=true
end
function api()
 local http=require('luci.http');local json=require('luci.jsonc');local sys=require('luci.sys');local fs=require('nixio.fs')
 local function reply(v) http.prepare_content('application/json');http.header('Cache-Control','no-store');http.write(json.stringify(v)) end
 local action=http.formvalue('action') or 'status'
 if action=='status' or action=='connections' or action=='logs' then
  local result=sys.exec('/usr/sbin/dualroute '..action..' 2>/dev/null')
  reply(json.parse(result) or {error='后台暂时不可用'});return
 end
 if action=='job' then
  local id=http.formvalue('id') or ''
  if #id>64 or not id:match('^%d+%-%x+$') then http.status(400);reply({error='无效任务'});return end
  local code=fs.readfile('/tmp/dualroute/job-'..id..'.result')
  reply({done=code~=nil,ok=code and tonumber(code)==0 or false});return
 end
 if not require('luci.dispatcher').test_post_security() then return end
 local allowed={tailscale=true,openclash=true,off=true,login=true,repair=true,settings=true}
 if not allowed[action] then http.status(400);reply({error='无效操作'});return end
 local payload=http.formvalue('settings') or '{}'
 if #payload>8192 then http.status(400);reply({error='配置过长'});return end
 local exit=http.formvalue('exit_node') or ''
 if action=='tailscale' and not exit:match('^%d+%.%d+%.%d+%.%d+$') then http.status(400);reply({error='无效出口'});return end
 fs.mkdirr('/tmp/dualroute');fs.chmod('/tmp/dualroute','700')
 local id=tostring(os.time())..'-'..sys.uniqueid(8)
 local stem='/tmp/dualroute/job-'..id
 if not fs.writefile(stem..'.input',payload) then http.status(500);reply({error='无法创建任务'});return end
 fs.chmod(stem..'.input','600')
 local command='/usr/sbin/dualroute '..action..(action=='tailscale' and (' '..exit) or '')..' < '..stem..'.input'
 sys.call('('..command..' >> /tmp/dualroute/jobs.log 2>&1; code=$?; printf "%s" "$code" > '..stem..'.result; rm -f '..stem..'.input) </dev/null >/dev/null 2>&1 &')
 http.status(202);reply({job=id})
end

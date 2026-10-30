(() => {
 'use strict';
 const root=document.getElementById('dualroute'),el=id=>document.getElementById('dr-'+id);
 const text=(id,s)=>{el(id).textContent=s||'—';};
 let active='overview',snapshot=null,initialized=false,pending=false,rows=[];
 const bytes=n=>{n=Number(n)||0;return n>=1073741824?(n/1073741824).toFixed(2)+' GiB':n>=1048576?(n/1048576).toFixed(1)+' MiB':n>=1024?(n/1024).toFixed(1)+' KiB':n+' B';};
 async function api(action,data){
  const p=new URLSearchParams({action,...(data||{})});let opts={cache:'no-store'};let url=root.dataset.api;
  if(data){p.set('token',root.dataset.token);opts={...opts,method:'POST',body:p};}else url+='?'+p;
  const res=await fetch(url,opts);if(!res.ok)throw new Error('请求失败（'+res.status+'），请刷新页面或重新登录');
  const v=await res.json();if(v.error)throw new Error(v.error);return v;
 }
 function table(id,values){
  const body=el(id);body.replaceChildren();
  for(const line of values){const tr=document.createElement('tr');for(const value of line){const td=document.createElement('td');td.textContent=String(value==null?'—':value);tr.append(td);}body.append(tr);}
  if(!values.length){const tr=document.createElement('tr'),td=document.createElement('td');td.colSpan=8;td.textContent='暂无记录';tr.append(td);body.append(tr);}
 }
 function form(s){
  el('hostname').value=s.network.hostname;el('routes').value=s.network.routes;
  el('accept').checked=s.network.accept_routes;el('advertise').checked=s.network.advertise_exit;
  el('extra').value=(s.extra_direct||'').replaceAll(',','\n');el('dnslog').checked=s.dns_log;
 }
 function render(s){
  snapshot=s;const warnings=s.health||[];text('health',s.tailscale==='Running'?(warnings.length?'部分连接受限':'Tailscale 在线'):s.tailscale);el('health').className='dr-pill '+(s.tailscale==='Running'&&!warnings.length?'good':'bad');
  const modes={tailscale:'国内 IPv4 直连',openclash:'OpenClash',off:'仅组网',switching:'切换中',error:'需要检查'};
  const pairs=[['公网模式',modes[s.mode]||s.mode],['Tailscale 地址',(s.ips||[]).join(' / ')],['家庭网关',s.gateway],['LAN 网段',s.subnet],['VPS 公网出口',s.exit_ip||'未检测'],['Tailscale 版本',s.version],['后台状态',s.state.message||'就绪'],['网络健康',warnings.length?warnings.map(w=>w.includes('relay server')?'中继连接失败，部分远端设备可能无法访问。':w).join(' '):'未报告异常']];
  el('summary').replaceChildren();for(const [k,v] of pairs){const dt=document.createElement('dt'),dd=document.createElement('dd');dt.textContent=k;dd.textContent=v;el('summary').append(dt,dd);}
  text('rx',bytes(s.rx));text('tx',bytes(s.tx));text('update','更新：'+new Date().toLocaleTimeString());
  const chosen=el('exit').value||s.exit_node;el('exit').replaceChildren();
  for(const p of s.peers||[]){if(!p.exit)continue;const option=document.createElement('option');option.value=p.ip;option.textContent=p.name+' · '+p.ip+(p.online?'':' · 离线');option.disabled=!p.online;el('exit').append(option);}
  if([...el('exit').options].some(o=>o.value===chosen))el('exit').value=chosen;
  table('peers',(s.peers||[]).map(p=>[p.name,p.ip,p.online?'在线':'离线',p.direct?'直连':p.relay?'中继 '+p.relay:'未建立',p.selected?'当前出口':p.exit?'可用出口':'—']));
  text('route-list',(s.routes||[]).join('\n'));text('rule-info','国内 / 自定义直连网段：'+s.rules+' 条；家庭网关：'+s.gateway+'。');
  if(!initialized){form(s);initialized=true;}
  if(s.login_url&&/^https:\/\//.test(s.login_url)){el('login').href=s.login_url;el('login').hidden=false;}else el('login').hidden=true;
  if(s.state.error&&!pending)text('notice',s.state.error);
 }
 function filter(){const term=el('filter').value.toLowerCase();table('connections',rows.filter(r=>Object.values(r).join(' ').toLowerCase().includes(term)).map(r=>[r.source,r.target+':'+r.port,r.protocol,r.path,bytes(r.bytes),r.state]));}
 async function refresh(){try{render(await api('status'));if(active==='connections'){rows=await api('connections');filter();}if(active==='logs'){const l=await api('logs');text('events',l.events);text('dns',l.dns);text('service',l.service);}}catch(e){text('notice',e.message);}}
 async function act(action,extra={}){
  if(pending)return;pending=true;root.querySelectorAll('button').forEach(b=>b.disabled=true);text('notice','正在执行，请稍候。网络模式切换可能需要约一分钟。');
  try{
   const r=await api(action,extra);let done=false;
   for(let i=0;i<90;i++){await new Promise(resolve=>setTimeout(resolve,2000));const res=await fetch(root.dataset.api+'?'+new URLSearchParams({action:'job',id:r.job}),{cache:'no-store'});if(!res.ok)continue;const j=await res.json();if(j.done){done=true;if(!j.ok)throw new Error('操作未完成，请查看后台状态和日志；也可能有其他操作正在执行。');break;}}
   if(!done)throw new Error('后台仍在处理，请查看状态后再操作。');
   text('notice','操作完成。');if(action==='settings')initialized=false;
  }catch(e){text('notice',e.message);}finally{pending=false;root.querySelectorAll('button').forEach(b=>b.disabled=false);await refresh();}
 }
 root.querySelectorAll('[data-tab]').forEach(b=>b.addEventListener('click',()=>{active=b.dataset.tab;root.querySelectorAll('[data-tab]').forEach(t=>t.classList.toggle('active',t===b));root.querySelectorAll('[data-panel]').forEach(p=>p.hidden=p.dataset.panel!==active);refresh();}));
 root.querySelectorAll('[data-action]').forEach(b=>b.addEventListener('click',()=>act(b.dataset.action,b.dataset.action==='tailscale'?{exit_node:el('exit').value}:{})));
 function settings(){if(!snapshot)return;act('settings',{settings:JSON.stringify({hostname:el('hostname').value.trim(),routes:el('routes').value.trim(),accept_routes:el('accept').checked,advertise_exit:el('advertise').checked,extra_direct:el('extra').value.trim(),dns_log:el('dnslog').checked})});}
 el('save-network').addEventListener('click',settings);el('save-rules').addEventListener('click',settings);el('filter').addEventListener('input',filter);
 refresh();setInterval(()=>{if(!document.hidden&&!pending)refresh();},5000);
})();

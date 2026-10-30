local M={}
function M.peername(p)
 local name=(p.DNSName or ''):match('^([^.]+)')
 return name or p.HostName or (p.TailscaleIPs or {})[1] or '未命名设备'
end
function M.ip(s)
 if type(s)~='string' then return nil end
 local a,b,c,d=s:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
 if not a then return nil end
 local n=0
 for _,v in ipairs({a,b,c,d}) do if #v>3 or tonumber(v)>255 then return nil end;n=n*256+tonumber(v) end
 return n
end
function M.cidr(s)
 if type(s)~='string' then return nil end
 local ip,p=s:match('^([^/]+)/(%d+)$');local n=M.ip(ip);p=tonumber(p)
 if not n or not p or p>32 then return nil end
 local size=2^(32-p);return math.floor(n/size)*size,p,size
end
function M.contains(cidr,ip)
 local net,_,size=M.cidr(cidr);local n=M.ip(ip)
 return net~=nil and n~=nil and n>=net and n<net+size
end
function M.overlap(a,b)
 local na,_,sa=M.cidr(a);local nb,_,sb=M.cidr(b)
 return na and nb and na<nb+sb and nb<na+sa
end
function M.routes(s)
 assert(type(s)=='string' and #s<2048,'子网参数过长')
 local out,seen={},{}
 for item in s:gmatch('[^,%s]+') do
  local n,p=M.cidr(item);assert(n and p>0,'请输入 IPv4 子网 CIDR，不能广播默认路由')
  local ip=item:match('^[^/]+');assert(M.ip(ip)==n,'请填写网段地址而非设备地址：'..item)
  if not seen[item] then out[#out+1]=item;seen[item]=true end
 end
 assert(#out<=32,'最多设置 32 个广播网段');return out
end
return M

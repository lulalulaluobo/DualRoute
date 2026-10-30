# 双径：使用、部署与回退

## 菜单栏

国内 IP 直连：国内地址经家庭主路由，其余经 Tailscale。全部走 Tailscale：撤销本任务添加的国内直连路由，保留 Mac 转发。设置可调整主路由地址及额外直连 IPv4 CIDR；单个地址写成 `/32`，不接受域名或保留地址段。`1.1.1.1` 用于默认 DNS 和出口检查，不可加入直连规则。

修改模式和配置需要管理员权限。退出菜单栏不停止后台。登录启动在设置中操作，与后台的开机恢复是两个独立设置。

## 当前部署参数

源码来自一个已验证的家庭网络，目前并非自动识别所有网络参数的通用安装器。新机器部署前逐项调整：

| 项目 | 文件 / 参数 |
| --- | --- |
| LAN 接口、网段、本机 Tailscale IP、回程探针 | `backend/tailscale-gateway-watch.py` 的 LAN、CLIENT_NET、TS_IP、LAN_PROBE |
| 网段、Mac 地址、网关 | `backend/split_engine.py` 的 LAN_NET、DEFAULT，以及 validate_config / publish 中的本机地址 |
| 菜单栏默认显示地址 | `app/main.swift` 的 GatewayState 默认值，真实运行时由状态 JSON 覆盖 |
| Python 路径 | `app/main.swift` 和 `data/local.codex.tailscale-gateway.plist` |
| 模式、主路由、额外网段 | `data/split-config.json` |

默认家庭网段为 192.168.0.0/16，Mac 为 192.168.2.123，主路由为 192.168.2.1，接口为 en0。后台固定路径为 `/Library/Application Support/CodexTailscaleGateway`；应用和后台必须保持一致。

## 首次部署后台

需要已安装并登录 Tailscale、本机可用的 Python 3.13。先检查上述参数和 Python 路径，再在仓库根目录操作。已部署的机器更新前应备份原目录，勿覆盖自定义配置。

```sh
sudo install -d -o root -g wheel -m 700 '/Library/Application Support/CodexTailscaleGateway'
sudo install -o root -g wheel -m 600 backend/tailscale-gateway-watch.py '/Library/Application Support/CodexTailscaleGateway/watch.py'
sudo install -o root -g wheel -m 600 backend/split_engine.py backend/control.py data/cn-ipv4.txt '/Library/Application Support/CodexTailscaleGateway/'
sudo install -o root -g wheel -m 600 data/split-config.json '/Library/Application Support/CodexTailscaleGateway/split-config.json'
sudo install -o root -g wheel -m 644 data/local.codex.tailscale-gateway.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/local.codex.tailscale-gateway.plist
```

这些是首次部署命令；已有任务时不要重复 bootstrap，使用 `sudo launchctl kickstart system/local.codex.tailscale-gateway`。选择 Tailscale 出口并允许本地 LAN 访问。若远端发布的子网与家庭网段重叠，可以关闭路由接收，但这会影响远端子网访问：

```sh
tailscale set --exit-node-allow-lan-access=true --accept-routes=false
```

脚本每 30 秒检测本机 Tailscale 地址所在的 utun，并确认公网路由、LAN 网段及回程。只初始化空的系统 PF 规则；如果已有规则但所需锚点缺失，会报错而不覆盖。模式/接口变化时会清理家庭网段相关连接状态，连接可能短暂重建。

客户端保持正确 IP 和掩码，将网关设为 Mac 的局域网 IP。确保 Mac IP 稳定，并关闭 Wi-Fi 客户端隔离。默认普通公网 DNS 转到 1.1.1.1；访问局域网 DNS 保留。分流模式允许显式使用 223.5.5.5 或 119.29.29.29；未实现自动 DNS 分流，DoH/DoT 不由这条普通 DNS 重定向处理。

## 重启与检查

重启后启动 Tailscale 并选中出口，后台会在条件满足后恢复规则；Mac 需保持唤醒。尚未做真实重启验收。首次恢复大量路由可能超过 30 秒。

```sh
cat /var/run/codex-ts-gateway-status.json
sysctl -n net.inet.ip.forwarding
route -n get 223.5.5.5
route -n get 1.1.1.1
sudo launchctl print system/local.codex.tailscale-gateway
sudo pfctl -a com.apple/codex-ts-gateway-test -sn
```

国内地址应经主路由/en0，其他地址经当前 utun。状态文件含更新时间、模式和错误，不要仅凭旧状态判断当前是否联网。`state = not running` 对定时短任务可以正常，检查最近退出码和更新时间。

## 回退

只撤销分流、保留 Tailscale 转发，在菜单选择全部走 Tailscale，或执行：

```sh
cd /private/tmp
sudo /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 -I '/Library/Application Support/CodexTailscaleGateway/control.py' full
```

它会仅删除本任务拥有且仍指向原网关的路由，并恢复 ICMP Redirect，即使 Tailscale 离线也能清理。不要手工删除 `owned-routes.json`。

完全停止本任务：先将客户端网关/DNS 恢复原设置，完成上面的 full 清理，再运行：

```sh
sudo launchctl bootout system/local.codex.tailscale-gateway
sudo rm /Library/LaunchDaemons/local.codex.tailscale-gateway.plist
sudo pfctl -a com.apple/codex-ts-gateway-test -f /dev/null
sudo sysctl -w net.inet.ip.forwarding=0
```

这些命令保留系统 PF 本身，不对其他程序执行全局 route flush 或关闭防火墙。若系统其他功能也依赖 IPv4 转发，应恢复部署前记录的值，而非关闭转发。

## 数据与边界

中国 IPv4 数据源为 https://ftp.apnic.net/stats/apnic/delegated-apnic-latest ，只提取 CN allocated/assigned 范围并合并，源校验和见 `data/cn-ipv4-source.json`。目前无自动下载更新。只支持 IPv4，尚无 IPv6 接管、域名精准规则、Clash 全量导入和出口断线强制阻断。

应用包为本机 ad-hoc 签名，未作 Apple 公证；DMG 只包含菜单栏界面和本文，不会自动部署后台。

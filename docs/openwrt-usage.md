# 双径 OpenWrt / QWRT 版 0.1.0

适用于本次验证的 QWRT 23.05、Linux 5.4、iptables legacy/fw3 环境。使用系统 Tailscale，不启动第二套代理核心。公网 IPv4 国内直连，其余使用选定的 Tailscale VPS 出口。

## 管理入口

LuCI → 服务 → 双径 · Tailscale。本次设备入口：http://192.168.2.88/cgi-bin/luci/admin/services/dualroute 。需要原有 LuCI 管理员登录。

- 仪表盘：切换国内分流、OpenClash、关闭公网接管；查看状态、出口与流量。
- 连接配置：设备名、子网广播、接受远端子网、本机出口广播。
- 分流规则：额外直连 IPv4 CIDR、DNS 查询日志开关。
- 设备与路径：Tailnet 设备、在线状态、出口能力及已安装路由。
- 连接记录：最近仍在 conntrack 中的 LAN 连接，最多显示 300 条；包含协议、目的地址、字节及路径分类。
- 日志：操作恢复事件、DNS 查询、Tailscale 服务日志。内存限量保存，重启清空。

设备名称优先使用 Tailnet DNS 名称，缺失时回退系统主机名。外部输入只以文本显示。

## 家庭设备接入

在测试设备上保留原 IP 和子网掩码，将 IPv4 网关和 DNS 均指向旁路由 `192.168.2.88`。主路由自身的上联网关保持不变；若需全家接入，应调整主路由发给客户端的 DHCP 网关/DNS，不能把主路由的上联网关改成旁路由而形成循环。

本机 LAN 仍经 `192.168.2.1` 出口。`tailscale0` 逻辑接口使用 `proto none`，地址与路由由 Tailscale 管理，不手填静态 `/8` 地址、网关或广播地址。

### Mac 改为普通客户端

如果 Mac 曾运行本项目的菜单栏转发版，仅退出菜单栏不会停止后台，也不会清除国内静态路由。应先按 Mac 版说明清理该任务拥有的路由、PF 锚点并停用后台，再切换为旁路由客户端；不要全局清空系统路由或防火墙。

本次 Mac 已完成迁移：以太网 IP `192.168.2.123`，掩码 `255.255.255.0`，网关和 DNS 都为 `192.168.2.88`；本机 Tailscale 已断开、IPv4 转发已关闭。旧后台 `local.codex.tailscale-gateway` 已通过 launchctl 禁用并保留 `disabled` 标记，重启不会重新接管。原配置备份在 Mac 的 `/Library/Application Support/CodexTailscaleGateway/before-router-client-*` 目录。

其余手机和电脑同样将网关/DNS 指向旁路由，不再指向 Mac。今后 Mac 关机不影响这些设备上网。若需临时绕过旁路由，在 Mac 网络设置中将网关改回 `192.168.2.1`、DNS 改为 `223.6.6.6`；这只恢复家庭宽带直连，不提供 VPS 出口。

第一版只管理 IPv4。设备从主路由得到 IPv6 默认路由时，IPv6 流量可能绕行；本版本没有宣称解决该路径，也不会擅自关闭整个家庭的 IPv6。

## 子网与出口是不同功能

广播 `192.168.2.0/24` 可让获准的 Tailnet 设备经本机访问家庭设备；需要在 Tailscale Admin Console 批准，并满足 Tailnet 访问控制。该字段不是接口的 IPv4 广播地址。

接受子网路由用于访问其他设备广播的远端网络。保存前检查当前已知远端路由与 LAN 重叠；不要接受与本地同网段的远端路由。此版本的广播输入编辑器支持 IPv4 CIDR；不要用它重写原有 IPv6 广播配置。

“将本机广播为出口”是让其他 Tailnet 设备使用本机上网，与“本机选择 VPS 出口”不同。本插件阻止两者同时启用。切换公网分流不会清除子网偏好。

## DNS 与路由

国内 IP 数据复用项目中的 APNIC CN IPv4 数据，共 5498 个合并网段（2026-10-30快照）。自定义直连规则并入独立 ipset，不改写系统默认路由。

路由顺序：本地 LAN → Tailnet/已安装远端子网 → 国内或额外直连 IPv4 → 所选 VPS。使用表 201、优先级 5100、mark `0x1000000/0x1000000` 和独立 `DR_*` 链；首次接管前检查表和优先级冲突。该标记位避开 Tailscale 的 `0xff0000` 保留位。

分流期间由 dnsmasq 管理 DNS，临时关闭 Tailscale 接管系统 DNS，并保存原配置。默认外部 DNS 通过出口访问；`.cn` 与一组常见国内服务使用国内 DNS，减少海外 CDN 解析。域名清单见 `/usr/share/dualroute/dns-domestic.txt`，并非完整国内域名库。全量域名分流与自动数据更新不属于此版本。

所有客户端经本机的普通 TCP/UDP 53 查询转交本机 DNS。DoH/DoT 查询不在该日志范围；连接记录也不包含 HTTPS URL、正文或完整访问历史。

## 切换与恢复

插件切换时先停止 OpenClash，配置出口和规则，再测试网络；失败则恢复旧模式。每 15 秒检查规则；如果发现 OpenClash 从其他界面启用，会撤销双径公网分流并转回 OpenClash。经本插件切换为串行互斥；从外部直接操作可能有检测间隔。

启动服务与 Tailscale 均设置为开机自启。Tailscale 保留登录与所选出口；双径在出口就绪后恢复规则。已验证服务重启和规则丢失后的恢复，尚未做整机断电重启测试。出口故障会显示告警，本版本不提供多出口自动故障切换或严格断网保护。

SSH 登录旁路由后可执行：

```sh
# 查看状态与连接
dualroute status
dualroute connections
dualroute logs

# 启用 BWG 国内 IP 分流（此 IP 是当前 Tailnet 中的 BWG）
dualroute tailscale 100.119.76.101

# 回退 OpenClash；保留 Tailscale 登录与子网配置
dualroute openclash

# 关闭公网接管，保持组网
dualroute off

# 检查、恢复缺失的规则
dualroute repair

# 启用开机启动并重启守护服务
/etc/init.d/tailscale enable
/etc/init.d/dualroute enable
/etc/init.d/dualroute restart
```

原网络配置与 Tailscale 1.32.3 程序备份只保存在设备 `/root/dualroute-backup/`。其中身份状态含密钥，不要公开上传。新版 1.104.4 已重新授权，保持原节点 IP。降级程序可能影响身份状态兼容性，通常优先使用 `dualroute openclash` 回退网络，不必降级 Tailscale。

此次 Tailscale 使用官方 ARM64 静态程序升级，校验了官方 SHA-256；opkg 的原 Tailscale 包版本记录不代表实际二进制版本，请以 `tailscale version` 为准。后续重装发行版旧 Tailscale 包可能覆盖新版程序。

## 安装包

本次已确认手机国内/国外访问、BWG 出口以及蜂窝网络经 Tailscale 访问飞牛 `192.168.2.61:5666` 均正常。子网访问曾受自定义 DERP 的 TCP 3443 不可达影响；用户恢复 Tailscale 官方默认策略后已验证成功。公网出口仍为所选 VPS，DERP 仅影响 Tailscale 设备间链路。

`luci-app-dualroute_0.1.0_all.ipk` 用于已具备 Tailscale（支持 `set`）、LuCI Lua、iptables legacy、ipset、ip、curl、flock、timeout 和 OpenClash 的 QWRT。安装前脚本检查现有能力，不自动增加依赖，不自动升级 Tailscale。安装不自动开启公网分流。

```sh
opkg install /tmp/luci-app-dualroute_0.1.0_all.ipk
```

另提供可检查内容的 tar 安装包，解压后 `sh install.sh`。升级保留 `/etc/config/dualroute`。当前版本只在本次 QWRT 设备上验证，不适用于直接替换 fw4/nftables 插件。

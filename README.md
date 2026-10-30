<p align="center"><img src="app/AppIcon.png" width="128" alt="双径图标"></p>

# 双径 · DualRoute

**国内访问走家庭宽带，国外访问走 Tailscale 出口。**

双径是一款 macOS 菜单栏分流工具，解决使用 Tailscale VPS 出口时，国内流量也绕行海外、访问变慢的问题。

它让 Mac 同时承担家庭网络网关的角色。手机、平板等设备将网关指向 Mac 后，也可以共享同一套分流规则。

[下载最新版](https://github.com/lulalulaluobo/DualRoute/releases/latest) · [使用说明](docs/usage.md)

## 可以做什么

- **国内 IP 直连**：国内 IPv4 流量走家庭宽带，其余流量走 Tailscale。
- **一键切换模式**：随时切换「国内 IP 直连」和「全部走 Tailscale」。
- **共享给局域网设备**：以 Mac 为网关的手机等设备，也能使用分流出口。
- **查看运行状态**：在菜单栏查看当前模式、出口接口、网关和直连规则数量。
- **添加直连规则**：按需补充需要直接访问的 IPv4 地址或网段。
- **自动恢复配置**：自动识别 Tailscale 接口变化，在连接条件满足后恢复转发规则。

## 界面预览

<img src="assets/menu.png" width="540" alt="双径菜单栏：分流模式与运行状态">

## 当前版本

适用于 Apple Silicon Mac，需配合已部署的 Tailscale 和分流后台使用；DMG 提供菜单栏控制应用。

目前按 **IPv4 地址**分流，尚不支持完整 Clash 配置导入、域名或进程精准分流。国内网站如果解析到海外地址，仍可能经过 Tailscale。

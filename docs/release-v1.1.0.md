# 双径 · DualRoute v1.1.0

首个 GitHub 发布版本，将 Tailscale 出口与家庭 IPv4 分流整合到原生 macOS 菜单栏。

- 全新「双径」名称、彩色应用图标和单色菜单栏分叉图标。
- 国内 IPv4 直连 / 全部走 Tailscale 两种模式。
- APNIC 中国 IPv4 快照：5,498 个合并网段。
- 状态查看、额外直连规则、手动恢复和登录启动设置。
- 动态识别 utun，后台恢复路由、PF NAT、MSS 与 DNS 规则。

## 下载与安装

下载 `DualRoute-1.1.0.dmg`，拖动「双径.app」到 Applications。

**适用于 Apple Silicon，最低部署目标 macOS 13，实测 macOS 26.5。** DMG 是已部署后台的 Mac 的配套控制应用；新机器须按仓库 docs/usage.md 单独配置 Tailscale、Python 与后台服务。未实现其他机器的一键部署。

应用为 ad-hoc 签名，未作 Developer ID 签名或 Apple 公证。`SHA256SUMS.txt` 可用于校验下载内容。

## 验证与已知限制

已验证国内直连、国外 VPS 出口和模式往返切换；用户确认手机国内变快、国外正常。路由管理单元测试、应用编译、自检、签名与 DMG 校验通过。

当前仅 IPv4 地址分流；不支持完整 Clash 导入、域名/进程规则、IPv6 或自动 DNS 分流。真实重启验收尚未完成。

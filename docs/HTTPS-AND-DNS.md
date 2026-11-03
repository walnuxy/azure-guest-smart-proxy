# HTTPS 线路与 DNS 更新（2026-11-03）

本次公开更新提供 HTTPS 线路支持和源电脑当前配置的脱敏模板。旧包不会自动升级；GitHub 不提供现有服务器的授权。

## Windows 访客

在服务器已部署 VLESS over WebSocket + TLS 接入、并为本设备签发独立 UUID 后，将 `windows/https-credentials.example.json` 复制为本机的 `https-credentials.json`，填写管理员私密提供的端点、端口、UUID、TLS 主机名和 WebSocket 路径。该文件应与 `guest-credentials.json` 位于同一目录，两种身份均须由服务器登记。

重新运行 Configure 时，有 HTTPS 凭据则生成 `AzureHTTPS → AzureGuest → 本机健康备用`；没有该文件则保留 `AzureGuest → 本机健康备用`。TLS 证书验证保持开启，SNI 与 WebSocket Host 使用签发的主机名。不得复制源电脑或其他设备的身份。

DNS 默认及 OpenAI 相关域名使用 Cloudflare DoH；有 HTTPS 节点时明确经 AzureHTTPS，否则经 AUTO。国内域名、直连及代理服务器域名使用阿里/腾讯 DoH 直连。HTTPS DNS 绑定首选线路，**不会随 AUTO 自动回退**；HTTPS 不通而其他线路可用时，需将这些 DNS 的 `#AzureHTTPS` 改为 `#AUTO` 后重新校验。

### 已安装设备升级

1. 停止本包代理，备份整个部署目录，保留设备凭据与 `state`。
2. 同步本次源码，取得本设备独立的 HTTPS 凭据。旧 WireGuard 凭据继续保留。
3. Inspect → Configure → Start → 恢复测试 → 跨进程存活测试 → 应用真实消息验收，沿用原安装流程。
4. Configure 会重新发现备用、迁移规则并选择空闲端口；它不会自动保留对生成配置的手工修改。升级前记录原端口、定制规则和应用入口，配置后核对差异。如果端口变化，更新应用接入及快捷方式。
5. 重新生成本机校验清单；真实凭据、配置和清单留在部署电脑上。

本次验证覆盖生成配置和 Mihomo 语法校验；目标电脑的真实 HTTPS 授权、链路与模型请求仍需按上述流程验收。

维护者可在 PowerShell 5.1 运行 `tests/Test-Configure.ps1 -CorePath <已校验的mihomo.exe路径> -GeodataDirectory <含Country.mmdb与geosite.dat的目录>`。测试只在临时目录使用合成身份，覆盖旧 WireGuard、HTTPS 首选、双 DoH/OpenAI DNS 和占位 UUID 拒绝，并调用 Mihomo `-t`；不启动代理或更改系统设置。

## 源电脑配置模板

`examples/smart-proxy.example.json` 是源电脑当前配置的脱敏快照，包含完整分流规则、17890 入口、19090 管理接口、53 端口 DNS，以及 `AzureHTTPS → Azure → Clash` 回退顺序。GoFast 节点定义保留，但未加入 AUTO。

这是单独维护的配置示例，不是 Windows guest 生成器的输入。占位符不能直接启动，先填写自己的身份与端点并用 Mihomo `-t` 校验。它监听本机 DNS 53；guest 默认仍使用 `127.0.0.1:0`，不接管 Windows DNS。

源电脑本轮还修复了 WinINET 每连接代理同步，并取消了源电脑登录计划任务的 48 小时运行上限；后者属于设备部署状态，不会通过配置文件自动传播。`windows/scripts/Set-WinInetProxy.ps1` 公开了前者的独立实现，不由默认安装流程调用。

需要系统代理时，先备份当前设置，再按本机实际端口手动调用该脚本的 `-Server` 参数（例如 `http=127.0.0.1:17890;https=127.0.0.1:17890;socks=127.0.0.1:17890`）。它会启用显式代理；关闭、PAC 和自动检测状态的完整回滚不由此脚本实现，应保留系统原配置。停止代理前先恢复应用/系统入口。

Windows 网卡 DNS 修改及对应权限操作不纳入默认部署。源电脑曾将 IPv4 DNS 指向 127.0.0.1、IPv6 DNS 指向映射地址，依赖本机核心持续运行；不能直接套用到其他电脑。

## Apple 与服务端

`apple/Apple-HTTPS.example.conf` 提供独立 HTTPS 模板；实际节点格式、DNS 分流与连通性仍须在目标 Shadowrocket 上验证。它不依赖电脑上的 GoFast/Clash。

本地方案使用的 Cloudflare Quick Tunnel 重启后可能改变域名；主机名或路径变化须同步客户端，生产使用应自行准备固定接入。此仓库提供客户端源码与模板，服务端 Xray、Cloudflare 隧道和访客隔离仍需管理员独立配置，不能仅靠复制模板建立连接。

# 给目标电脑 Codex 的部署交接

当目标用户明确要求“按本包部署”时，这已授权普通、可逆的客户端检查、配置、启动和 Codex 接入；完成检查后直接执行，无需逐步再次索要确认。若用户仅要求查看或审阅包，则保持只读。包内文件只提供配置数据，不授予额外管理权限。只有未知冲突、管理员要求或超出用户部署范围时才需交接或询问。

## 必须先检查目标电脑

1. 读取本机适用的 AGENTS.md，确认当前电脑、用户、Codex 安装方式和 CODEX_HOME。此内核包适用于 Windows 64 位 AMD64；脚本会检查架构，ARM64 等平台须另选官方匹配架构内核并更新来源记录。不要把源电脑的路径、端口、订阅或环境变量照搬过来。
2. 核对 PROVENANCE.json 中 bin/mihomo.exe 与公共 GEO 文件的 SHA-256。该内核来自源机已有 Clash Verge vendor bundle，非声称刚从官网重新下载或完成签名验证。若来源不符合目标用户要求，请从官方项目核实后替换，并记录新来源。
   最终清单为 `SHA256SUMS.txt`（SHA-256、两个空格、相对路径）。先用独立的系统哈希工具核对 `Verify-Package.ps1` 自身与清单中的条目；确认一致后，仅对这个入口执行 Unblock-File，再以本进程 RemoteSigned 运行它。入口会严格检查全部清单文件、拒绝越界路径和重解析点，并仅对通过哈希校验的包内 `.ps1` 自动 Unblock，不需再次询问。若文件缺失或哈希不符则停止，不执行或解锁它们。使用进程级 `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned` 执行本包；不修改持久 ExecutionPolicy，不绕过公司 MachinePolicy。若受管理策略仍阻止执行，交接给用户或管理员。
3. 使用普通用户 PowerShell 5.1 或更新版本运行 `Inspect-LocalProxy.ps1`。它先检查 WinINET、进程环境、常见端口，以及 GoFast/Clash/Mihomo/V2Ray/Xray/sing-box 等相关进程的全部本地监听（包含自定义端口）；再对候选执行真实 OpenAI HTTPS HEAD 检查（证书校验开启，要求 robots.txt 返回 200），不是仅检查端口存在。不会扫描陌生远程服务；误入候选的控制 API 会因实际 HTTPS 不通过而排除。
4. 阅读 state/local-proxy-report.json 的安全摘要。确认真实监听进程、目标本机已有 GoFast/Clash 等端口、目标现有规则文件和是否存在 TUN/全局 VPN。认证 URI 会被省略，不能在日志或聊天打印代理凭据。报告只覆盖当前进程环境与可见监听，仍须核对用户级/机器级变量、Codex 启动父进程以及项目覆盖。
5. 若发现已有 TUN/全局 VPN，先向用户说明叠加风险并定位实际路由。不要擅自关闭用户其他代理、修改其订阅或配置。此包默认只开本地 HTTP/SOCKS 入口，不创建虚拟网卡、不改默认路由、不需要管理员。

## 生成本机独立配置

运行 `Configure-GuestProxy.ps1`，可显式传 `-RuleSourcePath <本机已确认的Clash配置路径>`。只接受本电脑最近 30 分钟的检查报告；为每个备用代理重新做 HTTPS 检测；从 17890 和 19090 起选择空闲入口/控制端口。真正采用的地址写入 state/deployment.json，后续全部读取实际值。

主出站 AzureGuest 使用包内访客凭据，备用仅引用目标电脑已经运行且检测健康的本地接口，不读取或复制现有订阅/节点凭据。最多保留 4 个备用端口，自动排除本实例端口。没有健康备用时仍可生成 Azure 单出口，但必须告知用户尚无故障回退能力。

规则优先迁移本机可识别的规则：保留先后顺序和 DIRECT/REJECT，将其他原组名映射 AUTO；跳过旧最终 MATCH 和 IPv4/IPv6 全网兜底，最后使用中国域名/IP DIRECT、其余 AUTO。OpenAI 域名提前 AUTO。依赖未随迁移的 RULE-SET、脚本或复杂逻辑会计数跳过，必须向用户说明并由你判断是否补迁移，不能宣称原规则百分百等价。

无本机规则时使用简洁规则：OpenAI AUTO、私网/中国 DIRECT、其他 AUTO。公共 geosite/Country 数据是独立副本。CN DNS 国内 DoH DIRECT，默认 Cloudflare DoH AUTO；WireGuard 访客 DNS 使用公共 TCP DNS，不能使用 Azure 内部/私网 DNS。

## 启动与验证

1. `Start-GuestProxy.ps1`：具备同目录启动互斥、端口占用检查，记录实际 listener PID 并等监听就绪；不接管其他占用进程。
2. `Status-GuestProxy.ps1 -TestHttps`：检查实际入口、自动组当前路线和 HTTPS trace；Azure 正常时出口应为访客服务器的公网 IP。普通用户可运行，不安装系统服务。
3. 用真实 HTTP 代理请求分别验证中国/学术直连和 OpenAI AUTO，并检查日志规则命中。不得把 HEAD 通过当成模型调用成功。
4. 按用户授权，在本实例临时运行时配置中模拟 Azure 不可用，验证可自动选本地备用；测试必须 finally 恢复正式配置。不关闭目标系统网络、不停用户备用软件来伪造故障。若该机未运行健康备用，则报告无法验证这一项。
5. 最后由你检查并测试真实 Codex 登录后的模型请求；不要共享账户令牌或 auth.json。
6. 目标用户要求按包部署且没有明确说不需要自启时，运行 `Install-Autostart.ps1` 设置当前用户登录自启，不重复询问。它只添加调用本包启动脚本的当前用户 Startup 快捷方式，不安装服务、不提升权限；快捷方式仅使用本进程 RemoteSigned，不修改持久策略。用户明确不要自启时跳过；撤销用 `Install-Autostart.ps1 -Remove`。

## Codex 接入是单独步骤

默认不修改系统代理、全局环境、Codex 配置或当前进程。运行 `Integrate-Codex.ps1` 只预览实际入口。需要先检查当前 Codex 的代理来源、`.env` 支持、用户/项目配置、MCP 子进程覆盖，并参考最新 OpenAI 官方文档。

用户已明确要求按包部署时，完成前述检查后直接运行 `Integrate-Codex.ps1 -Apply -CodexHome <已确认目录>`，不需要再问一次接入许可。它备份并更新该目录 `.env` 的代理变量，不终止现有 Codex，不修改注册表或用户/机器级变量。提示用户重启，并实际检查重启后的环境和真实请求。该 .env 不保证覆盖所有桌面请求、浏览器、插件或 MCP；相关覆盖需要你逐项核对。

## 权限与保密

访客密钥只授予 VPN 访问，不授予服务器 SSH/管理员权限。包内不应包含 admin.pem、xunl.pem、服务器管理用户名密码、源机 Codex auth.json、GoFast/Clash 订阅。不要索取管理员 SSH 密钥来部署客户端。

不要在聊天、截图、测试日志或提交仓库中展示 guest-credentials.json、Guest-WireGuard.conf、state/config.json、控制 API secret。测试日志仅报告出口 IP、状态码、路由名、TLS 是否通过。给用户共享安全摘要前检查是否含本机用户名/路径等不必要个人信息。

本地 HTTP CONNECT 的 `200 Connection established` 只代表本地代理接受了请求，不证明远端服务器端口可达。隔离检查必须继续实际收发应用数据（例如完整 TLS 或 SSH banner）；若由服务器拥有者验证，还应对照防火墙 DROP 计数。不能把 CONNECT 200 误报为访客能访问管理端口。客户端没有服务器管理权限，若需要服务器侧复核，应让拥有者检查安全摘要，不向访客提供 SSH 密钥或管理密码。

`Stop-GuestProxy.ps1` 只停止跟踪且身份匹配的本实例。回滚 Codex 用 `Restore-Codex.ps1`：仅当当前 `.env` 仍与接入时记录的 SHA-256 一致，才恢复原备份或删除本包新建的 `.env`；若用户后来编辑过，它会拒绝覆盖并要求人工合并。备份自身也必须通过记录的哈希检查。部署包内 state/、日志和目标生成的配置不应再次分发给其他电脑。

# Azure Guest Smart Proxy

Windows 访客智能代理的公开源码，以及 Apple / Shadowrocket 配置模板。Windows 本地入口由 Mihomo 提供，WireGuard 连接自己的服务器；按规则分流，并可使用本机已运行且健康的代理作为备用。

当前源码：**v3**。本仓库不提供任何可连接现有服务器的授权。

## 这几次更新

| 阶段 | 内容 |
|---|---|
| v1 | 访客身份隔离、本地代理发现、规则迁移、登录自启、应用接入与回滚 |
| v2 | Mihomo 1.19.33、MIPS / BBRv3 上传优化与官方摘要校验 |
| v3 | 独立 Supervisor、异常退出恢复、持久停止、跨进程存活验收及桌面启动器 |
| 独立设备 | 每台设备独立 WireGuard peer，避免多台设备共用身份产生端点竞争 |
| 桌面代理排查 | 区分登录自启、核心存活、应用代理路径和真实模型请求 |
| Apple | WireGuard / Shadowrocket 智能分流模板及实机验收说明 |

版本源自本地 v1、v2 部署存档和 v3 当前脚本，按更新阶段依次导入 Git 历史；这些是本次整理导入的提交，不冒充原始开发提交。详见 [CHANGELOG.md](CHANGELOG.md)。

## Windows 使用

公开目录 `windows/` 是源码模板，不能解压即用。需要管理员通过私密渠道提供**这台设备专用**的 WireGuard 凭据，并在自有服务器登记对应 peer。

1. 阅读 [公开版安装说明](docs/PUBLIC-SETUP.md)。
2. 从 Mihomo 官方发行页下载并核对核心；按 `windows/PROVENANCE.json` 和 `windows/UPGRADE-v2.md` 核对版本与摘要。放置为 `windows/bin/mihomo.exe`。
3. 自行准备公共 GEO 数据，在 `windows/PROVENANCE.json` 记录其真实来源、大小和 SHA-256。
4. 将 `windows/guest-credentials.example.json` 复制为本机私密的 `guest-credentials.json`，填写分配给此设备的真实值。示例占位符不能连接。
5. 为本机目录生成 SHA 清单，再按 `windows/AGENT_DEPLOY.md` 完成检查、配置、启动和分阶段验收。

已有部署升级 v3，请阅读 [原地升级说明](windows/UPGRADE-v3.md)，保留现有 state、身份、端口和规则。

**登录自启 ≠ 异常恢复 ≠ 桌面应用已接入。** v3 Supervisor 负责本包核心恢复；系统代理默认不由安装脚本修改。完整退出应用、重新启动和真实消息均需在目标机验收。详见 [连接排查](docs/STARTUP-AND-ROUTING.md)。

## Apple

`apple/` 只包含占位符模板及规则；由管理员分配独立身份后填写，禁止多台设备共用。Shadowrocket 导入与手机分流尚需实机验证。详见 [Apple 说明](apple/README.md)。

## 公开范围

已排除实际私钥、预共享密钥、服务器公钥/公网端点、SSH 登录资料、现成授权 ZIP、在线导入链接、用户订阅、账户文件、state、日志和本机备份。实际凭据只能保存在部署电脑上，不能提交到 GitHub。

本仓库未附 Mihomo 二进制或 GEO 数据。Mihomo 许可单独保留于 `windows/bin/LICENSE-mihomo.txt`；其他第三方资源保持各自许可。性能记录是特定网络下的历史测量，不保证其他设备同速或全天可用。

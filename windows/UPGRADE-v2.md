# 已部署电脑的 v2 升级交接

给已部署此访客包的目标 Codex：用户要求升级即可在备份后执行，无需再次更换访客身份、服务器 peer 或密钥。不用重新上传整个约 22 MB 包；目标机可以直接通过现有可用网络从官方源下载。

## 官方内核与校验值

- 版本：MetaCubeX/mihomo v1.19.33，Windows AMD64 compatible。
- ZIP：https://github.com/MetaCubeX/mihomo/releases/download/v1.19.33/mihomo-windows-amd64-compatible-v1.19.33.zip
- ZIP SHA-256：`7aaf636a4f2172dcd8ec34ac4f52797b059195e5afd6409508c963e545f8864d`
- 解压后的 `mihomo-windows-amd64-compatible.exe` SHA-256：`926bfea2ce48a247d6a7ce4cf641980e416202d5e40fe4ee5c949089ace0e197`
- 官方源代码：https://github.com/MetaCubeX/mihomo/tree/v1.19.33
- 官方许可：https://raw.githubusercontent.com/MetaCubeX/mihomo/v1.19.33/LICENSE

请核对真实下载文件的哈希，而不是只复制这些字符串到记录。不要执行哈希不符的核心，也不要从未知镜像获取。ZIP 与 EXE 的哈希不同，不能混用。

## 最小升级步骤

1. 确认目标本机实际包位置、`state/deployment.json` 的 CorePath、MixedPort，以及当前监听 PID。先完成官方 ZIP 下载和校验，再停止当前实例；保留现有可用备用代理供下载使用。
2. 备份旧 `bin/mihomo.exe`、PROVENANCE.json、`state/config.json`、`state/deployment.json` 及旧 SHA256SUMS.txt。备份含访客配置，保持私密，不在聊天展示。
3. 用本包 `Stop-GuestProxy.ps1` 停止其跟踪实例，不停止用户其他代理。将核验后的 EXE 置为包内 `bin/mihomo.exe`。
4. 仅为目标机配置中的 AzureGuest WireGuard 节点添加以下字段；保留其 private-key、public-key、pre-shared-key、IP、服务器、端口、MTU、DNS、分流与备用设置不变：

```json
"ip-stack": {"mode": "mips", "congestion-controller": "bbr3"}
```

5. 更新 PROVENANCE.json 的 `core.sha256` 为上述 EXE 哈希并记录官方 asset URL、ZIP digest 和版本；公共 GEO 来源保持原样。更新 `state/deployment.json` 的 CorePath（仍为本机包内 EXE 路径）和 CoreSha256，保留现有端口及其他字段。启动脚本会拒绝未经记录的核心变化，不能删除这个检查来强行启动。
6. 用新核心 `-t -d <本机state目录> -f <本机state/config.json>` 校验。然后启动、检查状态、实际 HTTPS trace 和真实 Codex 请求；确认分流及备用仍正常。既有登录自启快捷方式无需换路径。
7. 更新本机 Configure-GuestProxy.ps1 的 AzureGuest 默认栈字段，确保未来重配仍用 MIPS/BBR3。旧包 SHA 清单在升级后已过期：保留旧清单用于回滚，核对本次改动后记录新的本地校验清单，不宣称旧清单仍能证明新文件。

旧 1.19.29 不支持 ip-stack；仅加字段不换核心不能完成优化。升级会短暂中断本实例流式连接，需由客户端重连。若验证失败，停止本实例并恢复上述备份及其原核心哈希；不要更换访客身份或修改服务器。

源机对相同约 23.2 MB 随机负载的三次上传为约 41.39、51.43、44.77 Mbps，仅作为本次修复效果记录，不保证另一条网络获得同样速率。

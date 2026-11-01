# 已部署旧包：v3可靠性修复

针对“代理退出、17890无人监听、Codex继续连接该端口”。WebGPT重新启动恢复了监听，但没有证明退出原因。v3增加独立Supervisor、退出恢复、主动停止语义和分阶段验收，不重建访客身份或扩大服务器权限。

## 使用轻量补丁

1. 先检查实际目录、监听/进程、自启和state。保留GoFast，备份旧脚本、PROVENANCE、清单及私有state；不要上传备份。
2. 独立核对补丁/Verify摘要后，在补丁目录用 -ManifestName PATCH-SHA256SUMS.txt 校验，仅解除已验证脚本下载标记。
3. 停止身份已核对的旧本包核心；不按进程名批量结束。覆盖补丁文件，保留state、guest-credentials、WireGuard配置、GEO数据和本地规则；不拷贝源机state。
4. 补丁不含核心、数据库或密钥。若仍为v1.19.29，按UPGRADE-v2官方下载核验v1.19.33，备份替换核心并更新部署CoreSha256，AzureGuest加MIPS/BBR3；保留身份/端口。正确v1.19.33无需重下载。
5. Inspect-LocalProxy与Diagnose-CodexRoute重新检查目标机。已有配置默认保留，只有证据显示端口/备用/规则失效才受控重配，不能为进程退出而盲目重新生成配置。
6. Start启动Supervisor；Test-Recovery验证恢复；BeginObservation后至少10秒用另一PowerShell ConfirmObservation。失败时不继续改.env。

   须等启动命令结束后再验收。若任务结果0xC000013A或守护退出但核心仍在，先Stop本实例，再用Start-GuestProxy -LauncherMethod ExplorerShell重做恢复/存活测试；不能仅因端口存在就接入Codex。两条启动路径均不通过时保留原代理。
7. 通过后Integrate -Apply，安装自启和桌面快捷方式。核对旧裸核心自启并迁移，避免重复。旧SHA清单已不适用于覆盖后的目录：保留用于回滚；补丁用PATCH清单、核心用官方摘要验证。
8. 根据真实桌面exe安装进程级启动器，交用户完整退出再点击。真实消息与连接证据通过前，只报告“修复已安装，桌面验收待完成”。

## 停止与回滚

Stop持久禁用，登录不会自动解除；手动Start才恢复。移除本包自启用Install-Autostart -Remove，只处理身份匹配的任务/快捷方式。Restore-Codex核对备份并保护后续修改。

监督启动不可用则报告失败状态，不修改全局安全策略或索取管理员密钥。普通账号不能创建任务时可尝试正常Explorer启动并验证；企业执行策略明确禁止时不能绕过。

线路失效由AUTO回退处理，本地核心退出由Supervisor处理。此补丁不保证网站/线路全天可用，也不需要收集用户原登录令牌或代理订阅。

# 从公开源码准备安装目录

本仓库没有现成授权；示例中的地址、端点与密钥占位符不能直接连接。

## 本机准备

使用 Windows x64 和 PowerShell 5.1。将 windows 目录复制到固定位置。按 PROVENANCE 和 UPGRADE-v2 中的官方发行信息取得核心，核对哈希后放入 bin/mihomo.exe。提供 Country.mmdb 和 geosite.dat，记录真实来源及摘要。公开仓库保留的 GEO 摘要仅是历史基线，不是你后来下载的文件已被验证。

将 guest-credentials.example.json 复制为 guest-credentials.json，填写自有服务器分配给此设备的地址、端口、私钥、服务器公钥和预共享密钥。privateKey 是客户端私钥；publicKey 是服务器公钥；clientPublicKey 是该设备公钥。不要将管理员 SSH 密钥放入客户端。

每个设备使用独立 peer。服务器管理员需要先完成相应 peer 登记、互联网转发和访客隔离；本仓库不会替你配置服务器或自动获得授权。

## 为本机文件生成清单

公开源码没有沿用私有授权包的 SHA 清单。完成官方核心和凭据校验后，在 windows 目录执行：

```powershell
$manifestRoot = (Get-Location).Path
$manifestLines = Get-ChildItem -LiteralPath $manifestRoot -File -Recurse |
    Where-Object { $_.FullName -notmatch '[\/]state[\/]|[\/]backups[\/]' -and $_.Name -ne 'SHA256SUMS.txt' } |
    Sort-Object FullName |
    ForEach-Object {
        $relative = $_.FullName.Substring($manifestRoot.Length + 1).Replace('\','/')
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $relative
    }
[IO.File]::WriteAllLines((Join-Path $manifestRoot 'SHA256SUMS.txt'), [string[]]$manifestLines, (New-Object Text.UTF8Encoding($false)))
```

清单只能检查准备后的文件是否改变，不能代替官方来源验证。包含实际凭据的本机清单也应留在本机。

然后按 AGENT_DEPLOY 顺序执行 Verify、Inspect、Configure、Start、恢复和跨命令存活验收，最后才接入应用。没有健康备用时应报告 Azure 单出口。不要修改机器持久执行策略，不要自动关闭当前桌面会话。

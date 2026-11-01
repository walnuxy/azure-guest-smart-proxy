# Apple / Shadowrocket 模板

每台设备向自己的服务器管理员申请独立 peer，填写 example 文件占位符后在本机另存配置；示例没有可用授权。不要将真实配置提交到 Git。

完整模板可在 Shadowrocket 配置页导入，代理组选 AzureApple，全局路由选“配置”。若导入不支持此节点格式，先按标准 WireGuard 文件添加节点并选中，再导入 Apple-Rules-Only.conf。节点字段/版本差异参照客户端官方或作者文档，最终以实机验证为准。

国内、局域网按规则直连，指定海外域名和剩余流量走代理；没有电脑 GoFast/Clash 备用。关闭开关恢复设备原网络。当前公开模板未在目标 Apple 设备验收。

参考：https://github.com/LOWERTOP/Shadowrocket/wiki#添加wireguard节点

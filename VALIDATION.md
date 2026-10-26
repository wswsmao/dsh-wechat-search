# 自验记录

本文件记录实现后的自验，不将前轮临时PoC结果当作新插件验收结果。

## 环境

- Windows本机，微信4.1.15.56已登录，交互式桌面解锁。
- DSH 0.2.1-rc.2；插件本体位于 `plugins/dsh-wechat-search` 独立Git仓库。
- Collector仅使用Windows PowerShell/.NET，无Python/MCP/第三方桌面库依赖。
- 所有本轮源码、测试和运行数据在项目目录；DSH安装引用由插件管理器登记在profile。

## 已通过自动验证

- Node 17项：两参数及边界、原始关键词、安全argv、固定时间窗、并发BUSY、5条预览、CSV/JSON路径、取消/完成竞态、环境/启动失败、卸载协作、重载恢复和终态同步。
- PowerShell Core：公开URL过滤、身份标识、短链接、严格域名、分钟与日精度时间边界、重名候选、CSV公式注入转义、UTF-8与原子文件。
- PowerShell desktop逻辑回归：原生绑定编译、年份数组运算优先级、文字分享日期/作者处理、账号不匹配拒绝、正常搜索页含验证字词不误判。
- 真实结果独立校验：只含mp.weixin.qq.com公开文章身份、无登录态参数、时间窗合法、记录数与status一致、身份去重。

## 安装验证

- 使用plugin_manager安装本项目目录，返回 `application: applied`。
- Inspect确认live条目 `include:local-wechat-search`。
- Inspect确认 `wechat_search`、`wechat_search_job` 实际工具注册，搜索schema只有keyword/lookback_days。
- 安装日志内有既有可选cpu-features编译器探测失败；本插件无该依赖/安装脚本，整体安装exit0、application applied。不会误称该可选依赖编译成功。
- 双语meta与原创SVG资源已检查；插件管理UI中的实际图标渲染未浏览器视觉核验，不声称视觉验证完成。

## 真实任务自验进度

- DeepSeek / 1天：新Collector完成首次翻页和逐篇提取，发现了文字分享年份表达式及排序选择缺陷；诚实落盘partial，不清零失败。已添加回归并修复。
- DeepSeek Harness / 3天：通过已安装工具发起，实际取消成功，续采保留原始reference_time；此后验证中的正文“验证码”误判及模块编码问题已修并持续验证。
- 新的完整终态、1/7天和无结果案例将在本轮验证结束后补充。

## 明确限制

- 无人为文章数量上限，但微信搜索索引外的全网完整性不保证，global_complete始终false。
- 若出现真实验证/限流不会绕过，needs_user保留已采结果。
- 窗口布局变化、强制进程终止、系统锁屏可能阻止恢复焦点/剪贴板。正常合作取消尽力恢复；不保证强杀后的恢复。
- 屏幕入口仅验证本机微信4.x布局，其他版本可能需用户先手工打开搜一搜。

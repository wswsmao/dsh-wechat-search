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
- 使用无桌面工作进程的隔离状态夹具，已通过安装工具实际验证：磁盘running+cancel.flag对外派生cancelling而磁盘不被覆盖，证明取消竞态修复后的Host代际已生效。夹具结束后已置终态，未影响真实任务。
- 双语meta与原创SVG资源已检查；插件管理UI中的实际图标渲染未浏览器视觉核验，不声称视觉验证完成。

## 真实任务自验进度

- DeepSeek / 1天：新Collector完成首次翻页和逐篇提取，发现了文字分享年份表达式及排序选择缺陷；诚实落盘partial，不清零失败。已添加回归并修复。
- DeepSeek Harness / 3天：通过已安装工具发起，实际取消成功，续采保留原始reference_time；此后验证中的正文“验证码”误判及模块编码问题已修并持续验证。
- DeepSeek Harness / 7天（新任务16149393-1b4d-49c5-874e-86de4f5885cd）：通过安装工具启动，155条候选全部完成；92条范围内、63条范围外，failed=0、日期不确定=0、逆序=0；终态complete、scope_complete=true、global_complete=false。CSV实读93行（表头+92条），JSON记录数/日期/身份/公开链接参数均独立校验通过。
- 旧3天续采任务：57条有效结果仍标partial；旧候选中3条在重搜时不再显示，保留为未解决项，没有伪称全部完成。此前文字分享的真实“昨天11:23”模板已单独打开并验证支持。
- DeepSeek Harness / 1天（新任务b3aa18b2-89f8-4f10-8054-6690b4937fe8）：96条候选全部完成，25条范围内、71条范围外，failed=0、日期不确定=0，complete/scope_complete=true；证明最小24小时时间窗实际运行。
- 原词 `DSH公众号采集自验无结果7c9d2e` / 1天：微信自行模糊匹配16篇旧结果（不是插件改词），本地过滤后0条；16候选都处理，complete/scope_complete=true，CSV仅表头。此用例验证空匹配结果，未验证微信真的0候选页面。
- 中文关键词 `量子计算` / 3天：首次73候选25匹配，1条视频分享页未有标准头部，诚实partial；已读取真实视频模板，新增video_share支持并保留日精度边界不确定性，续验已确认该条只公开10月23日、未有时分，而窗口起点为10月23日12:49，不能伪造时间判断是否纳入；73候选全部处理，25匹配、47范围外、failed=0、date_uncertain=1，JSON保留记录并明确partial/scope_complete=false。这是来源日期精度不足，不是伪称代码能确定其时刻。

- 真实中文关键词 `量子计算` / 1天任务：采到9条后通过工具取消，终态cancelled；随后续采保留9条及原始时间窗。profile刷新导致工作器卸载时实际落盘interrupted、结果文件元数据同步正确；再次续采保留结果，继续验收到最终终态。
- Windows桌面可用性检查与独占文件锁二次打开阻止检查通过；没有通过锁屏或注销用户来做破坏性测试。

## 明确限制

- 无人为文章数量上限，但微信搜索索引外的全网完整性不保证，global_complete始终false。
- 若出现真实验证/限流不会绕过，needs_user保留已采结果。
- 窗口布局变化、强制进程终止、系统锁屏可能阻止恢复焦点/剪贴板。正常合作取消尽力恢复；不保证强杀后的恢复。
- 屏幕入口仅验证本机微信4.x布局，其他版本可能需用户先手工打开搜一搜。

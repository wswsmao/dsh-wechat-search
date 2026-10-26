# 微信公众号检索（本机微信桌面）

DSH Host工具插件。在本机已登录微信中仅搜索原始关键词，按“文章/最新”持续加载并返回最近1～7天的公开文章。完整结果保存为CSV和JSON，不设人为返回条数上限。

## 工具

- `wechat_search({keyword, lookback_days})`：启动后台检索，返回任务ID。
- `wechat_search_job({action, job_id})`：查看状态、取消或续采；`action: "list"`列出历史任务。

`keyword`为非空字符串（最多200字符），保留原始内容（包括首尾空白），不拼日期或扩展关键词。`lookback_days`为整数1～7，按任务启动时刻固定最近24～168小时；北京时间。续采保留原始时间窗，不偷偷换成“现在”。

## 安装

使用DSH插件管理器安装本项目绝对目录。不要手工改profile的package.json或补丁。安装可能在DSH profile登记引用，这是Harness管理的数据；项目本体和检索运行数据始终位于本目录。

插件名称 `@local/dsh-wechat-search`。独立Git仓库，不修改DSH源码、不部署MCP或Skill。

## 本机要求及桌面影响

- Windows交互式桌面保持解锁，微信4.x已登录。
- 微信搜一搜可用；第一次自动入口识别失败时，可手工打开“发现 → 搜一搜”后续采。
- 采集期间不要操作微信、键盘或鼠标。跨会话/进程仅允许一个采集器持有桌面锁。
- 采集会切换微信搜索和文章窗口，复制页面文本；尽力恢复旧剪贴板和原焦点。用户同时修改剪贴板可能冲突。
- 不发送消息、不访问聊天数据库、不提取登录凭据、不自动登录、不绕过验证码。遇验证/限流暂停，用户处理后续采。

## 结果与完整性

字段：`title`、`url`、`author`、`account`、`date`、`published_at_iso`、`publication_precision`、`content_type`。

- 作者署名和公众号分开；无署名为空，不把公众号冒充个人作者。
- 普通文章读取页头分钟级发布时间。公众号文字分享可显示“今天/昨天 + 时分”或月日：前者依据本机北京时间转换；只有月日则通过搜索相对日期核对年份，保留日精度，时刻留空。
- 日精度日期的整天在窗口内才确定纳入；若跨边界，写入JSON不确定列表，不伪造00:00。
- 原文URL仅保留公开文章标识，移除登录态、追踪参数；按公众号/消息/篇目身份去重，不按标题去重。
- CSV为UTF-8 BOM，可在Excel打开；字段公式前缀转义。原始文字保留于JSON。
- 工具回复仅5条预览，完整结果在文件；预览截断不是结果截断。
- `coverage.scope_complete`仅表示本次微信搜索可见范围完成，`global_complete`始终false。不能保证微信未索引/隐藏/截断的全网文章。
- 见多条明确旧结果后额外加载确认；检测日期逆序。超时、无法解析、日期不确定或验证/异常均保留部分结果和停止原因。

默认单次工作时间预算30分钟，超时返回partial而不是默认为完整；续采保持原窗口。时间预算是执行保护，不是返回数量限制。若续采时旧候选不再被搜索展示，会保留未解决项并明确报告，不悄悄丢弃。

状态：`starting`、`running`、`cancelling`、`complete`、`partial`、`cancelled`、`needs_user`、`failed`、`interrupted`。

## 运行数据及Git规范

所有运行数据在项目 `.runtime/` 中：

```text
.runtime/jobs/<任务ID>/request.json
.runtime/jobs/<任务ID>/status.json
.runtime/jobs/<任务ID>/checkpoint.json
.runtime/jobs/<任务ID>/results/result.csv
.runtime/jobs/<任务ID>/results/result.json
.runtime/desktop.lock
```

`.runtime/`、缓存、依赖、日志由 `.gitignore`忽略；源码、文档、清单、图标和测试纳入Git。每组完成并验证的代码修改提交一次，检索产生的数据不提交。此仓库配置本地自动化提交身份，不改全局Git身份。

## 独立运行

采集器无Python、第三方桌面库或MCP依赖，使用Windows PowerShell/.NET UIAutomation。命令行传入项目运行目录内的请求JSON和任务目录：

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File collector/main.ps1 -RequestPath <request.json> -JobDir <job-dir>
```

请求由插件生成，通常不需手工组装。不接收任意用户脚本或输出路径。

## 自验

- Node测试覆盖入参、后台任务互斥、状态、取消续采、卸载、进程失败、输出预览与路径约束。
- `tests/core.tests.ps1`覆盖PowerShell解析、日期边界、日精度不确定性、公开URL、重名结果、CSV和原子状态。
- 真实微信检索、自验报告见 `VALIDATION.md`，其中明确记录实际通过和未验证的部分。

## 安全维护

PowerShell脚本需UTF-8 BOM兼容Windows PowerShell5.1。不要日志输出完整带会话参数的导航URL，也不要把凭据写入结果、测试夹具或Git。插件通过Harness受管理的子进程启动采集器，停用/卸载只停止自己的采集进程，不杀微信。

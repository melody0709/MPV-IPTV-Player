# 项目长期记忆（mpv + uosc IPTV 播放器）

## 回看(catchup)机制
- 回看模板语法是 APTV 生态宏：`${(b)格式}`/`${(e)格式}` 节目开始/结束；时区后缀 `:utc`/`|UTC`=UTC，无后缀=设备本地时间；`{url}`=直播地址。
- `catchup="append"`：catchup-source 是 query 片段（如 `?playseek=...`），需拼接到直播 URL（live 已含 `?` 时用 `&`）；`catchup="default"`：catchup-source 是完整 URL 模板直接用。
- `replace_catchup_time_params`(utils.lua) 负责宏替换；`build_catchup_playback_sources`(playback.lua) 负责组装 URL。
- 用户的 web.m3u 回看服务端（10.10.10.187:8767）把 `playseek=yyyyMMddHHmmss` 字面值按**北京时间(+08:00)**解释（实测 PROGRAM-DATE-TIME 印证）；用户 Windows 机器系统时区是 **PDT**，两者错位 15 小时——无后缀宏填充需时区覆盖配置兜底。
- cache 里 443 条 catchup="default" 订阅（183.235.162.80 广东源）用 `${(b)...|UTC}` 已工作，改回看逻辑必须保证它们逐字节不回归。

## 用户工作约定
- 改代码前先调研机制→出方案（表格+分层+一句话结论）→等批准→实现→自查（diff/行号）→SemVer。
- 不主动改文件、不主动生成报告，方案在聊天里给。

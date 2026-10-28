# MPV IPTV Player with EPG & Catch-up

基于 **mpv 播放器** 和 **uosc 5.12 UI 框架** 深度定制的 IPTV 播放器，专为直播电视和回看功能设计。

## 核心功能

- **四级滑动菜单 + 频道搜索**：`F8` 顶部搜索框只匹配频道名，不会匹配 EPG 时间或节目标题；菜单结构为 分组 > 频道 > 日期桶 > EPG，日期桶支持 明天 / 今天 / 昨天 / 星期X（附月日副标题）；频道搜索支持中文、拼音全拼和首字母（如 `广东` / `guangdong` / `gd`，`东莞` / `dongguan` / `dg`）
- **组内快速切台 (PgUp / PgDn / uosc 上一台下一台按钮)**：直播时可在当前频道组内切到上一台/下一台，行为与鼠标点选频道一致；切台后 OSD 会在视频顶部居中显示当前频道名；回看状态下不执行切台，只显示提示
- **顶部频道上下文**：鼠标移动到视频顶部时，`uosc` 顶部悬浮标题除原有播放地址/标题外，还会在同一行后方显示当前频道组与频道名
- **EPG 回看**：支持 XMLTV 格式节目单，时间跳转回看功能
- **回看续播预加载**：在当前回看片段接近结束时提前排队下一段 URL，尽量前置网络连接与请求延迟，减少续播卡顿
- **EPG 回看搜索 (F9)**：跨频道搜索所有可回看的节目，按时间倒序排列
- **远程 M3U 订阅模式**：可配置远程 `m3u_download_url`，空载启动 mpv 时优先从本地缓存秒开 IPTV，再在后台刷新订阅
- **完整视频链请求上下文**：支持 `#EXTVLCOPT`、`#EXTHTTP`、`#KODIPROP` 与 URL pipe Header；UA、Referer、Origin、Cookie 等会随主清单传播到 HLS 子清单、密钥和分片
- **格式与多线路回退**：频道可聚合多条 source；动态 `.php/.jsp/.asp` 或无后缀地址会在有限状态机中尝试自动探测、HLS、MPEG-TS，再切换备用线路，不会对裸 URL 无限重试
- **安全诊断**：识别 DRM-only 频道并明确提示不支持；日志脱敏 query/凭据，持久格式缓存只保存 source 哈希
- **手动强制刷新 EPG (Shift+F9)**：普通模式下强制刷新 EPG；订阅模式下同时强制刷新 M3U 订阅与 EPG
- **智能右键**：根据上下文（IPTV/普通视频）显示不同的右键菜单
- **历史记录**：自动保存/恢复上次播放的频道；连续快速切台时会合并为 2 秒后的单次写盘，减少频繁 IO
- **多平台支持**：Windows/Linux/macOS，自带 curl 工具链

## 📸 界面截图

### 四级滑动菜单 (F8) / 右键
分组 > 频道 > 日期桶 > EPG，支持顶部搜索框按频道名快速筛选

![四级滑动菜单](screenshots/menu.webp)

### EPG 回看搜索 (F9)
跨频道搜索所有可回看的节目，按时间倒序排列

![EPG 回看搜索](screenshots/epg-search.webp)

### 频道模糊搜索菜单
epg菜单项,直接按键输入即可激活

![智能右键菜单](screenshots/context-menu.webp)

### 演示视频
https://github.com/user-attachments/assets/e3a6009f-b783-4dfd-bbd2-3c1b7f81a280


## 快速使用

1. 下载 mpv Windows 版（推荐 shinchiro mpv-winbuild）
2. 把 `portable_config` 放到 下载好的mpv 根目录
3. 双击本地 M3U，或命令行：
   ```bash
   mpv tv.m3u
   ```
4. 如果想使用远程订阅，把 `m3u_download_url` 写到 `script-opts/epg.conf`，然后直接空载启动：
   ```bash
   mpv
   ```

## 技术栈

| 组件       | 技术            | 说明                      |
| ---------- | --------------- | ------------------------- |
| 播放器核心 | mpv             | 多媒体播放引擎            |
| UI 框架    | uosc 5.12 (Lua) | 现代 OSC 界面，已定制扩展 |
| EPG 处理   | Lua + XML       | 节目单解析和回看 URL 生成 |
| 数据存储   | JSON            | 频道历史记录持久化        |

## 文件结构

```
portable_config/
├── 📄 CLAUDE.md              # AI 开发指南（开发者文档）
├── 📄 UOSC_MODIFY_DIFF.md    # uosc 源码修改记录（重要！）
├── 📄 mpv.conf               # mpv 配置文件
├── 📄 input.conf             # 快捷键配置
│
├── 📁 scripts/
│   ├── 📁 epg/               # 【核心】IPTV EPG 脚本（模块化）
│   │   ├── 📄 main.lua       # 入口：全局状态 + mp.* 绑定
│   │   ├── 📄 utils.lua      # 工具层：字符串/时间/搜索
│   │   ├── 📄 source.lua     # 纯 source/Header/格式/候选工具
│   │   ├── 📄 m3u.lua        # 纯 M3U 状态机与多线路聚合
│   │   ├── 📄 data.lua       # 数据层：EPG/历史/频道索引
│   │   ├── 📄 menu.lua       # 菜单层：4级菜单构建
│   │   └── 📄 playback.lua   # 播放层：session/回退/直播/回看/切台
│   ├── 📄 thumbfast.lua      # 缩略图生成（第三方）
│   │
│   ├── 📁 bin/
│   │   └── 📄 curl.exe       # curl 下载工具（Windows）
│   │
│   └── 📁 uosc/              # 【修改区域】uosc 5.12 源码
│       ├── 📄 main.lua       # ⚠️ 已修改（消息处理器）
│       ├── 📁 lib/
│       │   ├── 📄 menus.lua  # ⚠️ 已修改（toggle_menu_with_items）
│       │   └── 📄 ...        # 其他未修改文件
│       ├── 📁 elements/
│       │   ├── 📄 Menu.lua   # ⚠️ 已修改（activate_selected_item）
│       │   └── 📄 ...        # 其他未修改文件
│       └── 📁 bin/           # ziggy 二进制文件
│
├── 📁 script-opts/           # 脚本配置文件
│   └── 📄 epg.conf           # EPG / 远程 M3U 订阅配置
│
└── 📁 fonts/                 # 字体文件
```

## 关键修改点（uosc 源码修改）

本项目对 uosc 5.12 源码进行了关键修改，以支持 IPTV 四级菜单功能：

1. **`scripts/uosc/main.lua`** - 新增 `expand-submenu` 消息处理器，增强 `open-menu` 支持 `anchor_x`/`anchor_offset`
2. **`scripts/uosc/elements/Menu.lua`** - 修改 `activate_selected_item` 方法，支持同时执行 value 和展开子菜单
3. **`scripts/uosc/lib/menus.lua`** - 修改 `toggle_menu_with_items` 函数，确保任何类型菜单都能正确关闭

详细修改记录请查看 `UOSC_MODIFY_DIFF.md` 文件。

## IPTV 核心脚本

**`scripts/epg/`** 是主要业务逻辑（模块化文件夹脚本），包含：

- `main.lua`：全局状态初始化、所有 mp.* 事件/消息/按键绑定
- `utils.lua`：字符串工具、UTF8、OSD、时间日期换算、拼音搜索
- `source.lua`：Header 校验/合并、pipe URL 拆分、格式识别、日志脱敏、mpv 文件级选项和候选构建（纯函数）
- `m3u.lua`：解析 M3U/M3U8 的 source descriptor，将同频道多条线路聚合到 `channel.sources`（纯函数）
- `data.lua`：EPG XML 下载与解析（支持 gzip）、M3U 结果接入、精确 URL 索引、安全格式缓存、频道历史记录和频道/节目查找
- `menu.lua`：四级菜单数据结构构建（分组 > 频道 > 日期桶 > EPG）、EPG 回看搜索菜单
- `playback.lua`：完整 playback session/attempt、文件级 Header/格式选项、有限格式/线路回退、回看 source 构建、直播与组内切台

## 核心功能

- 解析 M3U `group-title` 分组、频道
- 自动加载 `x-tvg-url` EPG（xml/xml.gz）
- 支持 `m3u_download_url` 远程订阅缓存启动与后台刷新
- 支持频道级 Header、格式、DRM 元数据与同频道多 source
- 支持 APTV/KU9/UTC 回看模板、append 拼接和逐线路回看天数限制
- 支持 `epg_history.json` 记录最后播放频道（每个 m3u）

## M3U 模板

```m3u
#EXTM3U x-tvg-url="http://your-epg-server/t.xml" http-user-agent="PlaylistUA/1.0"
#EXTINF:-1 tvg-id="CCTV1" tvg-name="CCTV-1高清" tvg-logo="http://..." group-title="央视" catchup="default" catchup-source="http://server/ch{id}?starttime=${utc:yyyyMMddHHmmss}&endtime=${utcend:yyyyMMddHHmmss}",CCTV-1综合
#EXTVLCOPT:http-user-agent=IPTV-App/2.0
#EXTVLCOPT:http-referrer=https://portal.example/
#EXTVLCOPT:http-origin=https://portal.example
#EXTHTTP:{"Cookie":"session=...","X-Device-Id":"..."}
#KODIPROP:inputstream.adaptive.manifest_type=hls
http://your-stream-url/play.php?id=cctv1|User-Agent=FinalUA%2F3.0&Referer=https%3A%2F%2Fportal.example%2F
```

## 字段说明

- `x-tvg-url`：EPG 数据源
- `tvg-id`：频道 ID（与 EPG channel id 关联）
- `group-title`：频道分组
- `catchup-source`：回看 URL 模板
- `catchup`：`append` 将后缀拼接到当前线路的直播 URL，`default` 使用完整回看 URL，`none` 禁用回看；缺省时自动识别以 `?`/`&` 开头的后缀
- `catchup-days`：各线路的回看窗口（天）；日期菜单将过期节目标为不可回看，F9 搜索与播放入口排除过期回看；未声明时不额外限制。上述回看属性也支持在 `#EXTM3U` 中设置默认值
- `#EXTVLCOPT:http-*`：VLC 风格的 UA、Referer、Origin、Cookie 或自定义 Header
- `#EXTHTTP`：JSON Header 对象，也支持 `{ "headers": {...} }`
- `#KODIPROP`：Kodi adaptive Header、`manifest_type`、MIME 和 DRM license 元数据
- `URL|Header=...&Header=...`：URL pipe Header；参数值按 URL 编码解析，pipe 部分不会送入媒体 URL

同名 Header 的优先级为：URL pipe > URL 前的 `#EXTHTTP/#EXTVLCOPT/#KODIPROP` > `#EXTINF` 属性 > `#EXTM3U` 默认值 > `iptv_default_user_agent` > mpv 默认值。

同一分组内 `tvg-id` 相同的条目会聚合成一个频道；没有 `tvg-id` 时按频道名聚合。不同 query 仍是不同 source，不会因为去掉 query 而串台。兼容字段 `channel.url` 始终指向第一条 source。

Header 名和值含 CR/LF 时会被拒绝。Widevine 等带 license 元数据的 DRM source 会被识别并跳过；当前版本不提供 DRM 解密或浏览器嗅探能力。

远程订阅中的媒体条目只接受明确的网络协议（HTTP(S)、RTSP/RTMP、RTP/SRT、UDP、MMS 等）；`file://`、`av://`、`lavf://` 等本地或特殊协议不会进入频道模型。本地 IPTV M3U 会在 mpv 原生播放列表展开前由脚本接管，普通本地 HLS/相对路径播放列表仍交给 mpv。

## 频道历史记录

- 文件位置：优先使用 `~~home/cache/epg_history.json`，无法确定时回退到 `%TEMP%/mpv_epg_epg_history.json`
- 格式：`{ "path/to/tv.m3u": { "channel_key":"ch:...", "source_id":"src:...", "source_index":1, "url":"...", "name":"...", "group":"...", "timestamp":123456789 } }`
- `channel_key/source_id/source_index` 用于恢复聚合频道及最后成功线路；旧版 `url/name/group` 字段继续保留并可兼容读取
- 远程订阅模式使用 `sub:<订阅URL哈希>` 作为稳定历史键，避免缓存刷新后丢失上次频道，也避免把带 token 的订阅 URL 明文写入历史文件；V1.9.0 会自动迁移旧键
- `stream-open-filename` 中的最终重定向短期 URL 不会写入历史或格式缓存
- 下次打开同一路径的 m3u，或再次进入同一个订阅源，将自动还原上次频道
- 连续快速切台时，历史记录会在停止切台约 2 秒后统一写入最后一次频道
- 如果在 2 秒内直接退出 mpv，脚本会在退出前立即刷盘，尽量避免最后频道丢失

## 配置示例

 `script-opts/epg.conf`

```ini
 epg_download_url=http://your-epg-source.com/epg.xml
 m3u_download_url=http://your-iptv-source.com/tv.m3u
 epg_cache_refresh_start=00:04
 epg_cache_refresh_interval_hours=7
 catchup_preload_seconds=15
 iptv_default_user_agent=SYTV/1.6
 iptv_network_timeout=8
 iptv_retry_count=2
 iptv_retry_delay=1.0
 iptv_format_fallback=yes
 iptv_source_fallback=yes
```

## 运行日志调试

```bash
 mpv --msg-level=all=info,epg=info,ffmpeg=debug tv.m3u
```

关注 `[IPTV] session=...` 输出中的 `source`、`mode`、`class` 和候选推进；URL query 会显示为 `<redacted>`，日志只列 Header 名，不显示 Cookie/Authorization 值。发布默认配置使用 `ffmpeg=warn`，只有排查真实失败源时才建议临时改成 `debug`。

按 `F8` 打开 IPTV 菜单后，顶部会直接显示搜索框，可输入频道名快速筛选；搜索结果只按频道名匹配，并支持中文、拼音全拼和首字母。

## 常见问题

- 无 EPG：确认 `x-tvg-url` 可访问，检查 `script-opts/epg.conf` 中的下载连接
- 无回看：检查 `catchup-source` 时间模板
- 无历史记忆：确认脚本有写权限
- 某些直播频道在 Android IPTV 能播、mpv 直接打开不行：先确认 M3U 是否带 UA/Referer/Origin/Cookie。V1.9.0 会解析并向 HLS 子请求传播这些 Header；无明确格式的 HTTP(S) 地址按“自动探测 → HLS → MPEG-TS → 备用 source”有限尝试。若仍失败，临时启用 `ffmpeg=debug`，查看是鉴权/超时/格式还是 DRM
- 日志提示 `该频道需要 DRM（当前不支持）`：该线路声明了 Widevine/其他 license 信息，普通 mpv/FFmpeg 无法靠重试解密；请换非 DRM source
- 某频道有多条线路但未切换：确认重复条目的 `group-title` 与 `tvg-id` 相同（无 `tvg-id` 时频道名要相同），并确认 `iptv_source_fallback=yes`
- 想在同一频道组内快速上下切台：直播时按 `PgUp` / `PgDn`，或点击 `uosc` 底部上一台/下一台按钮；如果正在看回看，只会提示“回看中不支持组内切台”
- 想立即更新节目单：按 `Shift+F9`，或打开 `F8` IPTV 菜单后选择 `强制刷新 EPG`；如果当前来源是订阅模式，会先刷新远程 M3U，再刷新 EPG
- 想快速找频道：按 `F8` 后直接输入频道名，菜单会即时筛选频道结果，不会匹配 EPG 节目时间或标题；例如 `gd` 和 `guangdong` 都能匹配 `广东`，`dianying` 和 `dy` 都能匹配 `电影`，但不会因为 `jingdian` 里恰好含有 `gd` 就误命中 `经典` 类频道

## ⚙️ 配置说明

### EPG 下载 URL（可选）

脚本会优先使用 `script-opts/epg.conf` 中的 `epg_download_url` 配置来下载 EPG 数据；若该值为空，则回退到 M3U 中的 `x-tvg-url` 字段。

`script-opts/epg.conf` 示例：

```ini
# EPG 下载连接配置
# 当此参数存在时，优先使用该连接下载 EPG，而不是 M3U 表头中的 x-tvg-url
epg_download_url=

# 远程 M3U 订阅地址（可选）
# 配置后，空载启动 mpv 会优先尝试从缓存启动 IPTV，再在后台刷新远程订阅
m3u_download_url=

# EPG 缓存刷新时间配置
# 从每天 00:04 开始，按 7 小时间隔生成当天刷新点：00:04 / 07:04 / 14:04 / 21:04
epg_cache_refresh_start=00:04
epg_cache_refresh_interval_hours=7

# 回看续播预加载阈值（秒）
# 当当前回看片段距离结束还剩这么多秒时，提前排队下一段 URL
catchup_preload_seconds=15

# IPTV 请求上下文与有限候选回退（仅作用于 epg 脚本播放）
iptv_default_user_agent=SYTV/1.6
iptv_network_timeout=8
iptv_retry_count=2
iptv_retry_delay=1.0
iptv_format_fallback=yes
iptv_source_fallback=yes

# IPTV 菜单 UI 配置（0=沿用 uosc.conf）
menu_subtitle_font_size=0
menu_subtitle_marquee=yes
menu_level1_min_width=0
menu_level2_min_width=0
menu_level2_max_width=0
menu_level3_min_width=0
menu_level4_min_width=0
```

- `menu_subtitle_font_size`：二级/三级菜单副标题字体大小（频道当前节目、日期桶日期）
- `menu_subtitle_marquee`：频道当前节目超出可用宽度时，选中项自动横向滚动
- `menu_level1_min_width`：一级菜单（分组）最小宽度
- `menu_level2_min_width`：二级菜单（频道）最小宽度
- `menu_level2_max_width`：二级菜单（频道）最大宽度，`0` 为不限制
- `menu_level3_min_width`：三级菜单（日期桶）最小宽度
- `menu_level4_min_width`：四级菜单（EPG）最小宽度
- `catchup_preload_seconds`：回看片段剩余多少秒时，提前把下一段插入播放列表；默认 `15`
- `m3u_download_url`：远程 IPTV 订阅地址；配置后空载启动 `mpv` 会先尝试本地缓存，再按与 EPG 相同的缓存周期后台刷新
- `iptv_default_user_agent`：M3U 没有频道级 UA 时的 IPTV fallback；不会影响普通网络文件
- `iptv_network_timeout`：每次 IPTV 网络打开的超时秒数，脚本限制为 `1~60`；默认 `8`
- `iptv_retry_count`：全部打开候选失败后的有限轮次，以及已加载线路中断后的重连次数，限制为 `0~5`
- `iptv_retry_delay`：候选推进/重连延迟秒数，限制为 `0.1~10`
- `iptv_format_fallback`：是否为无明确格式的 HTTP(S) source 追加 HLS/MPEG-TS 候选
- `iptv_source_fallback`：是否在当前 source 候选耗尽后切换同频道下一线路

### EPG 缓存刷新规则

- `epg_cache_refresh_start`：每天首个刷新点，格式为 `HH:MM`
- `epg_cache_refresh_interval_hours`：当天后续刷新点的小时间隔
- 默认配置会得到 `00:04 / 07:04 / 14:04 / 21:04` 四个刷新点
- 如果配置缺失或格式错误，脚本会自动回退到旧的固定时段规则，避免缓存失效

## 🔧 故障排除

### EPG 无法加载

1. **检查 EPG URL 格式**

   - 确保 M3U 中的 `x-tvg-url` 是可访问的 XML 文件
   - 文件编码应为 UTF-8
2. **查看 mpv 日志**

   ```bash
   mpv --msg-level=all=info,epg=info,ffmpeg=debug tv.m3u
   ```

   搜索 `[IPTV]` 与 `ffmpeg` 相关日志；分享日志前仍建议检查其中是否含上游服务自行输出的敏感数据

### 回看功能不工作

1. **检查 `catchup-source` 格式**

   - 保持兼容的 UTC 时间格式：
     - **标准回看模板**: `${utc:yyyyMMddHHmmss}` 和 `${utcend:yyyyMMddHHmmss}`
     - **KU9回看模板**: `${(b)yyyyMMddHHmmss|UTC}` 和 `${(e)yyyyMMddHHmmss|UTC}`
     - **APTV回看模板**: `${(b)yyyyMMddHHmmss:utc}` 和 `${(e)yyyyMMddHHmmss:utc}`
   - APTV 无后缀 `${(b)yyyyMMddHHmmss}` / `${(e)yyyyMMddHHmmss}` 使用设备本地时间；可在 `myepg.conf` 设置 `catchup_local_timezone_override=+08:00`，让无后缀宏按北京时间生成。发布默认值留空
   - 显式 `|Local`、`|UTC`、`:utc`、`|GMT+8`、`|+08:00` 优先于配置。支持 `yyyy`/`MM`/`dd`/`HH`/`mm`/`ss` 及常用标点分隔，不支持 IANA 时区名
   - 也支持 `${(b)timestamp}` / `${(e)timestamp}`、`{utc:YmdHMS}` / `{utcend:YmdHMS}`、`{utc}` / `{utcend}` / `{lutc}` / `{duration}`，以及 `{url}` 直播地址占位符。时间戳均为 Unix 秒，`lutc` 为当前时间，`duration` 为节目秒数
   - 例如 `catchup="append" catchup-days="7" catchup-source="?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}"`；已有直播 query 和线路 Header 会保留，无法解析的模板会显示错误提示
2. **检查时间格式**

   - 确保 EPG 中的 `start` 和 `stop` 时间是标准 XMLTV 格式

### 修改类型标记

| 标记         | 用途            | 示例                                         |
| ------------ | --------------- | -------------------------------------------- |
| `【修改】` | 修改现有逻辑    | `-- 【修改】支持同时执行value和展开子菜单` |
| `【新增】` | 新增函数/代码块 | `-- 【新增】expand-submenu 消息处理器`     |
| `【删除】` | 删除原始代码    | `-- 【删除】原代码不支持xxx功能`           |

### 必须同步更新的文件

**当修改以下文件时，必须同步更新 `UOSC_MODIFY_DIFF.md`：**

1. `scripts/uosc/main.lua`
2. `scripts/uosc/elements/Menu.lua`
3. `scripts/uosc/lib/menus.lua`

### 重要注意事项

1. **uosc 源码修改**

   - **不要修改未标记的文件**，除非有充分理由
   - **修改 uosc 源码后必须更新 `UOSC_MODIFY_DIFF.md`**
   - **保留原始注释**，在附近添加中文修改说明
   - **向后兼容**：确保修改不破坏原有功能
2. **IPTV 功能扩展**

   - **优先在 `scripts/epg/` 中实现新功能**
   - **利用现有 API**：`open-menu`、`expand-submenu`、`select-menu-item`
   - **考虑多平台兼容**：Windows PowerShell 和 Linux/macOS gzip 解压
   - **错误处理**：网络请求失败、文件读写权限、数据解析异常
3. **升级 uosc 版本**

   - **备份修改**：复制 `UOSC_MODIFY_DIFF.md`，导出 git diff
   - **替换文件**：用新版本替换 `scripts/uosc/` 目录
   - **重新应用修改**：参考 `UOSC_MODIFY_DIFF.md` 逐个文件对比
   - **API 兼容性检查**：验证 `open-menu`、`expand-submenu` 接口
   - **功能测试**：IPTV 菜单、频道切换、EPG 展开、回看功能

## 测试

```bash
lua tests/run.lua
luac -p scripts/epg/source.lua scripts/epg/m3u.lua scripts/epg/utils.lua scripts/epg/data.lua scripts/epg/playback.lua scripts/epg/menu.lua scripts/epg/main.lua
python tests/test_mpv_integration.py
```

最后一条命令使用隔离临时配置运行真实 mpv，验证本地 M3U 接管、302 → HLS → TS 全请求 Header 传播，以及 APTV append 回看的原 query、北京时间参数和回看状态保护；也在 mpv 自带 Lua 中验证 UTC/DST 转换。测试服务只在运行期间监听 `127.0.0.1:18991`。

## 版本信息

- **基础版本**：uosc 5.12.0
- **IPTV 版本**：V1.10.0（2026-10-22）
- **最后更新**：2026-10-22

## 🤝 致谢

- [mpv](https://mpv.io/) - 强大的媒体播放器
- [uosc](https://github.com/tomasklaen/uosc) - 优秀的 mpv 界面脚本
- [XMLTV](http://wiki.xmltv.org/) - EPG 数据格式标准
- [FongMi/TV](https://github.com/FongMi/TV) - source/Header/格式/DRM 与备用线路架构参考（GPL-3.0；本项目未复制其实现）
- [my-tv-0](https://github.com/lizongying/my-tv-0) - 同频道多 URL 与格式候选行为参考（MIT）
- [Kodi PVR IPTV Simple](https://github.com/kodi-pvr/pvr.iptvsimple) - M3U Header/KODIPROP 与流格式识别架构参考（GPL-2.0 系列；本项目未复制其实现）

## 📄 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

---

**注意**: 本脚本仅供学习研究使用，请遵守当地法律法规，合理使用 IPTV 资源.

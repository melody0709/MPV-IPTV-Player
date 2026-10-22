# mpv + uosc IPTV 播放器开发指南

基于 **mpv** + **uosc 5.12** 的 IPTV 播放器，支持直播、EPG 回看、远程订阅。

## 核心功能

- **四级菜单 (F8)**：分组 > 频道 > 日期桶 > EPG；搜索支持中文/拼音/首字母
- **组内切台 (PgUp/PgDn)**：直播时在当前组内切换，回看状态不执行
- **EPG 回看**：XMLTV 节目单，时间跳转回看；F9 跨频道搜索节目
- **远程 M3U 订阅**：`m3u_download_url` 缓存启动 + 后台刷新
- **强制刷新 (Shift+F9)**：忽略缓存重新下载 EPG/M3U
- **历史记录**：自动保存/恢复上次频道，快速切台合并写盘

## 文件结构

```
portable_config/
├── scripts/
│   ├── epg/              # 核心业务逻辑 (main.lua 为入口)
│   │   ├── main.lua      # 全局状态 + 事件/按键绑定
│   │   ├── utils.lua     # 工具函数 (纯函数，无 state 依赖)
│   │   ├── source.lua    # source/Header/格式/候选纯函数
│   │   ├── m3u.lua       # M3U 状态机 + 多线路聚合纯函数
│   │   ├── data.lua      # M3U 接入/EPG 解析 + 历史记录
│   │   ├── menu.lua      # 四级菜单构建
│   │   └── playback.lua  # 直播/回看/切台逻辑
│   └── uosc/             # ⚠️ 已修改的 uosc 源码 (见 UOSC_MODIFY_DIFF.md)
│       ├── main.lua      # 【修改】新增消息处理器
│       ├── elements/Menu.lua       # 【修改】菜单项/搜索/交互
│       ├── elements/TopBar.lua     # 【修改】顶部标题追加 IPTV 信息
│       └── lib/menus.lua           # 【修改】toggle_menu_with_items
└── script-opts/
    ├── epg.conf          # 发布版默认配置
    └── myepg.conf        # 本地私有覆盖 (不发布)
```

## uosc 修改规范

修改 uosc 源码必须：
1. 用中文标记 `-- 【修改】`/`-- 【新增】`/`-- 【删除】`
2. 保留原始代码注释，在附近添加说明
3. 新增修改点时同步更新 `UOSC_MODIFY_DIFF.md`（迁移清单格式：文件 + 位置 + 用途）

## 开发要点

- **优先扩展 epg/**，仅在 UI 交互需要时修改 uosc
- **多平台兼容**：Windows/Linux/macOS，注意 gzip 解压差异
- **错误处理**：网络请求、文件读写、数据解析均需容错

## 环境工具

- **Lua 5.4**：已通过 scoop 安装，用于语法检查和脚本测试
- **mpv.exe**：位于 `../mpv.exe`
- **Shell**：默认使用 `pwsh` (PowerShell 7)，禁止使用 `powershell.exe` (5.1)；需要 Unix 工具链时使用 Git Bash

## API 参考

```lua
-- uosc 扩展接口
mp.commandv("script-message-to", "uosc", "open-menu", json_data, submenu_id)
mp.commandv("script-message-to", "uosc", "expand-submenu", menu_id)
mp.commandv("script-message-to", "uosc", "select-menu-item", menu_type, index, parent_id)

-- epg 关键函数
parse_m3u(path)                  -- 解析 M3U
load_iptv_sources(sources, context, params) -- 统一 descriptor/session 播放入口
build_catchup_playback_sources(channel, start_utc, end_utc, template, url)
fetch_and_parse_epg_async()      -- 异步获取 EPG
build_main_menu()                -- 构建菜单数据
switch_channel_in_current_group(direction)  -- 组内切台
```

## Git 规范

- 提交格式：`feat:` / `fix:` / `refactor:` / `style:` / `docs:`
- 版本：fix → z+1，feat → y+1，重构 → x+1
- 发布前核对：Release 版本、Git Tag、CHANGELOG 三者一致
- `script-opts/epg.conf` 为发布默认配置，私人地址写 `myepg.conf`

## 调试

```lua
mp.msg.info("调试信息")     -- mpv 控制台 (按 ` 查看)
mp.osd_message("提示", 3)   -- OSD 显示 3 秒
```

### 测试启动

```powershell
# 空载启动 (从缓存订阅加载 IPTV)
../mpv.exe
```

## 相关文档

- `UOSC_MODIFY_DIFF.md` - uosc 修改记录
- uosc: https://github.com/tomasklaen/uosc

## 经验记录

> AI 在完成重大修改或解决复杂报错后，可以追加经验记录,更新AGENTS.md。

- IPTV 播放状态不能只保存 URL；Header、格式、DRM、source 索引和 file options 必须作为同一个 descriptor/session 贯穿直播、历史、切台、回看、预加载和重试。
- mpv `loadfile` 的文件级 option map 值必须全部是字符串；`User-Agent`/`Referer` 单独映射，其余 Header 进入正确转义的 `http-header-fields`，并保持 `demuxer=lavf`、`demuxer-lavf-propagate-opts=yes`，避免远端 M3U8 回退到丢失 file options 的 playlist demuxer。
- Header 名和值必须拒绝 CR/LF；日志只显示脱敏 URL 和 Header 名，格式缓存只保存 source 哈希，不能持久化最终重定向 URL、Cookie、Authorization 或 query token。
- `end-file` 重试要先由 `start-file` 确认 attempt，并核对 `playlist_entry_id`；否则切台产生的旧结束事件会误重试新频道。所有重试必须复用 descriptor，且次数有限。
- URL query 可能就是频道身份，禁止把去 query 的 URL 当唯一 source ID；只有原 source 本身无 query 时才可建立追加 query 的前缀索引。
- 动态 `.php/.jsp/.asp` 不能按后缀排除 HLS；优先用 M3U 明确格式，再做自动/HLS/MPEG-TS/备用 source 候选。DRM-only 源应明确报不支持，不进入网络重试。
- 真实 mpv 集成测试应使用隔离的临时 `--config-dir`，避免 `myepg.conf` 触发私人订阅下载或污染正式历史/缓存；302 → HLS 清单 → TS 分片需逐请求验证 Header 传播。
- 本地 M3U 不能依赖 `path` observer + `playlist-clear` 接管；observer 触发时原生 playlist demuxer 可能已异步展开裸 URL。应在 `on_load` 阶段识别 IPTV M3U 并阻断原生网络请求，同时让普通本地 HLS/相对路径播放列表继续走 mpv。
- 回看 URL 可能只是直播 URL 追加 query；`path` observer 必须先保护当前/排队中的 catchup session，再执行直播频道索引匹配。打开补试轮次和已加载后的断线重连计数必须分离。

# IPTV 视频链兼容性优化（V1.9.0）

## 1. 目标

把频道从“一个裸 URL”升级为“带完整请求上下文、格式信息和候选线路的 source descriptor”，解决以下常见问题：

- 动态入口经过 301/302/307/308 跳转后才能得到真实媒体；
- 主清单可访问，但 HLS 子清单、密钥或分片缺少 `User-Agent`、`Referer`、`Origin`、`Cookie` 等 Header；
- URL 没有 `.m3u8` 后缀，或者是 `.php/.jsp/.asp` 动态接口，后缀无法表达真实格式；
- 同一频道有多条线路，第一条失效时当前实现只会反复重试同一个裸 URL；
- 回看、预加载、历史恢复或通用错误重试绕过原播放入口，丢失 Header/格式选项；
- Widevine 等 DRM 源无法由当前 mpv 直接播放，却被当成普通网络错误无限尝试；
- 日志打印完整 query token、Cookie 或最终短期跳转 URL，存在泄露风险。

本特性不实现无限重定向、不全局启用 `reconnect_at_eof`，也不引入 WebView、本地代理或 DRM 绕过。HTML/JavaScript 嗅探只保留为未来可插拔后备，不属于本版本。

## 2. 研究依据与取舍

参考项目及固定研究版本：

- FongMi/TV `5fdff00a602dc56e8ba756174daef20edab024f2`：完整解析 M3U Header/格式/DRM，将 Header 设置到播放器 DataSource，并在直播失败时切换备用线路。GPL-3.0，仅借鉴架构，不复制实现。
- lizongying/my-tv-0 `19ab99c4c2f819fdfd08b09f64219bb7cd93eaa1`：聚合同频道多 URL，无后缀源按 HLS/Progressive 候选尝试。MIT，可参考行为；本项目仍独立实现。
- Kodi PVR IPTV Simple `d2310c911632a06e8dca7630befbf42d26f6fa70`：支持 `#KODIPROP`、`#EXTVLCOPT`、URL pipe Header，并结合后缀/MIME/内容识别格式。GPL-2.0 系列，仅借鉴架构。

当前 mpv `v0.41.0-243-g05fac7f21` / FFmpeg `N-123079-ge869426a8` 已原生支持常见 HTTP 30x（FFmpeg 默认最多 8 次）。因此本次不修改重定向上限；重点是保留请求上下文、格式提示和有限候选回退。

## 3. 数据模型

兼容字段 `channel.url` 继续指向第一条 source，现有菜单和历史数据不会立即失效；新逻辑统一读取 `channel.sources`。

```lua
channel = {
    key = "ch:<hash>",
    name = "频道名",
    tvg_id = "xmltv-id",
    group = "分组",
    url = "https://primary.example/live", -- 兼容字段
    catchup = "...",                      -- 兼容字段
    sources = {
        {
            id = "src:<hash>",
            url = "https://primary.example/live",
            headers = {
                ["User-Agent"] = "...",
                ["Referer"] = "...",
                ["Origin"] = "...",
                ["Cookie"] = "...",
            },
            format = "hls",        -- nil / hls / dash / mpegts
            format_origin = "kodi", -- directive / extinf / url / cache
            catchup = "...",
            drm = nil,
        },
    },
}
```

同一 `group + tvg-id`（无 tvg-id 时为 `group + name`）的条目聚合为一个频道，多条不重复 URL/请求上下文成为 `sources`。query 仍是 source 身份的一部分，禁止用“去 query URL”作为唯一频道 ID。

## 4. M3U 解析规则

### 4.1 支持语法

- `#EXTM3U`：`x-tvg-url` 及 playlist 级 Header/格式默认值；
- `#EXTINF`：现有频道属性，以及 Header、格式、MIME、DRM 属性；
- `#EXTVLCOPT:http-user-agent`、`http-referrer`、`http-origin`、`http-cookie`、任意安全的 `http-header`；
- `#EXTHTTP:{...}`：直接 Header 对象或 `{ "headers": {...} }`；
- `#KODIPROP`：adaptive common/manifest/stream Header、`manifest_type`、MIME、license type/key；
- `URL|User-Agent=...&Referer=...&Origin=...`：URL 编码的 pipe Header；
- HTTP(S)、RTSP、RTMP、UDP/RTP、SRT/RIST 等带 scheme 的媒体地址。

### 4.2 优先级

同名 Header 或格式冲突时，越靠前优先级越高：

1. URL pipe 参数；
2. URL 前紧邻的 `#EXTHTTP` / `#EXTVLCOPT` / `#KODIPROP`；
3. `#EXTINF` 属性；
4. `#EXTM3U` playlist 默认值；
5. `iptv_default_user_agent`；
6. mpv 自身默认值。

### 4.3 安全约束

- Header 名必须符合 HTTP token 字符集；Header 名和值含 CR/LF 时整项拒绝，防止 Header 注入；
- `User-Agent`、`Referer` 独立映射到 mpv 文件级选项，其余 Header 进入 `http-header-fields`；
- mpv string-list 中的反斜杠和逗号必须转义；
- URL、Header 和 DRM license 信息不以明文写日志；query 值统一脱敏；
- 持久格式缓存只保存 source descriptor 的哈希与格式，不保存 URL、Header、最终重定向 URL或 token。

## 5. mpv 文件级选项映射

每次 `loadfile` 均通过 node command 携带字符串值的文件级 option map：

| source 信息 | mpv 文件级选项 |
| --- | --- |
| `User-Agent` | `user-agent` |
| `Referer` / `Referrer` | `referrer` |
| `Origin` / `Cookie` / `Authorization` / 自定义 Header | `http-header-fields` |
| HLS | `demuxer-lavf-format=hls` |
| DASH/MPD | `demuxer-lavf-format=dash` |
| MPEG-TS | `demuxer-lavf-format=mpegts` |
| IPTV 超时 | `network-timeout=<iptv_network_timeout>` |
| 嵌套清单传播 | `demuxer-lavf-propagate-opts=yes` |

全局 `mpv.conf` 不再硬编码 IPTV UA 和 3 秒网络超时：它们移动到 IPTV 文件级配置，避免影响普通网络文件。FFmpeg 日志默认保留 warn 级，便于识别 HTTP/TLS/格式错误。

## 6. 播放候选链与状态机

每次播放创建独立 session，active attempt 至少包含：

```lua
{
    generation = 42,
    channel_key = "ch:...",
    source_index = 2,
    mode = "hls",
    source = source,
    file_options = {...},
    file_loaded = false,
    retry_count = 0,
    playlist_entry_id = nil,
}
```

候选顺序：

1. source 明确格式或安全哈希缓存命中的格式；
2. mpv 自动探测；
3. 对无明确格式的 HTTP(S) 源尝试 HLS；
4. 必要时尝试 MPEG-TS；
5. 切换同频道下一 source，重复上述有限候选；
6. 候选耗尽后停止，并输出分类错误和已尝试线路/模式摘要。

约束：

- 只在 `start-file` 已确认当前 playlist entry 后处理它的 `end-file`，避免切台时旧文件的结束事件误触发新频道重试；
- 打开前失败优先推进格式/线路；播放成功后发生网络错误，才对已确认候选做有限重连；
- 重试必须复用 descriptor 和 file options，禁止退回裸 `mp.commandv("loadfile", url)`；
- 新的手动播放会取消旧 session 的延迟重试和已排队回看；
- `insert-next` 预加载保存完整 queued session；它真正触发 `start-file` 时再成为 active session，失败后可继续相同候选链；
- DRM source 在候选构建阶段跳过；若所有 source 都需要 DRM，明确提示当前 mpv IPTV 层不支持，而不是循环重试。

## 7. 全入口一致性

以下入口必须走同一 source/session 逻辑并继承 Header：

- F8 菜单直播点击；
- PgUp/PgDn 与 uosc 上一台/下一台；
- 订阅缓存启动后的历史恢复；
- 外部 `play-live-channel` 消息兜底；
- EPG 回看点击；
- 回看 `insert-next` 预加载；
- 回看片段 EOF 续播；
- 播放错误重试与同频道备用线路切换。

历史记录新增稳定 `channel_key` 和成功播放的 `source_index`，保留旧 `url/name/group` 字段以兼容 V1.8.0 数据。恢复时优先 key，再回退精确 URL，绝不保存 `stream-open-filename` 的最终短期跳转地址。

## 8. 配置项

新增发布默认配置：

```ini
iptv_default_user_agent=SYTV/1.6
iptv_network_timeout=8
iptv_retry_count=2
iptv_retry_delay=1.0
iptv_format_fallback=yes
iptv_source_fallback=yes
```

所有次数和延迟均有上下限；不允许配置造成无限重试。

## 9. 实施文件

- `scripts/epg/source.lua`：纯 source/Header/格式/脱敏/候选与 mpv option 工具；
- `scripts/epg/m3u.lua`：纯 M3U 状态机与同频道多 source 聚合；
- `scripts/epg/data.lua`：接入新解析结果、精确 URL 索引、历史与安全格式缓存；
- `scripts/epg/playback.lua`：统一 session/attempt/候选回退；
- `scripts/epg/main.lua`：事件桥接和直播/回看/预加载全入口接线；
- `script-opts/epg.conf`、`mpv.conf`：文件级 IPTV 网络配置与可诊断日志；
- `tests/test_source.lua`、`tests/test_m3u.lua`、`tests/test_data_index.lua`、`tests/test_playback.lua`、`tests/run.lua`：纯 Lua 回归测试；
- `tests/test_mpv_integration.py` 与 `tests/fixtures/`：隔离配置下的真实 mpv 空载及 302 → HLS → TS Header 传播集成测试；
- `README.md`、`CHANGELOG.md`、`AGENTS.md`：使用说明、V1.9.0 变更和经验记录。

不修改 `scripts/uosc/`，因此无需更新 `UOSC_MODIFY_DIFF.md`。

## 10. 验收清单

- [x] `.plan/feat/` 中存在本方案；
- [x] parser 覆盖四类 Header 语法、格式/DRM 和多线路聚合；
- [x] URL pipe 从播放 URL 中剥离且高优先级合并；
- [x] Header 注入被拒绝，日志 query/凭据脱敏；
- [x] mpv option map 的所有值均为字符串，HLS 子请求可继承；
- [x] 动态 `.php/.jsp/.asp` 不再被排除在格式候选外；
- [x] 直播、历史、切台、回看、预加载、续播均传递 descriptor；
- [x] 通用错误处理不再裸 URL 重试，且能切换格式和备用 source；
- [x] DRM-only 频道明确提示不支持；
- [x] query 不同的 source 不会因索引去 query 而串台；
- [x] 安全哈希格式缓存不持久化 URL/token；
- [x] `lua` 单测、`luac -p` 全部通过；
- [x] mpv 空载启动无 Lua 初始化错误；
- [x] README、CHANGELOG、版本日期和配置示例同步为 V1.9.0。

## 11. 回滚边界

新字段均保持 `channel.url` 和旧历史字段兼容。若需回滚，只需恢复 `scripts/epg/`、`script-opts/epg.conf` 和 `mpv.conf`；没有数据库迁移、uosc 修改或外部服务状态变更。

## 12. 实施与验证结果（2026-07-12）

已按本方案完成实现，未修改 `scripts/uosc/`。权威验证结果：

- `luac -p`：生产 Lua、测试 Lua 和集成控制器全部通过；
- `lua tests/run.lua`：source、M3U、query 精确索引、候选/session/queued attempt 共 4 组测试全部通过；
- `python tests/test_mpv_integration.py`：使用隔离临时配置先验证真实 mpv 空载启动，再验证 302 入口、HLS 主清单、TS 分片三层请求均继承 UA、Referer、Origin、Cookie；
- `git diff --check`：通过；
- 静态搜索：只有统一 `dispatch_loadfile` 使用 `loadfile`，没有旧 `pending_hls_retry/error_retry_count/known_hls_urls` 状态，没有 uosc 差异；
- 配置加载：集成测试复制发布版 `epg.conf` 到隔离配置，未出现未知 option 或 Lua error。

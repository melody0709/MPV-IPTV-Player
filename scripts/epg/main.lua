--[[
                重构：四级滑动菜单结构 - 分组 > 频道 > 日期桶 > EPG
    模块化版本：main.lua 入口 + utils / data / playback / menu 子模块
]]

local mp = require 'mp'
local utils = require 'mp.utils'
local opt = require 'mp.options'

-- ==================== 全局选项 ====================

options = {
    epg_download_url = "",
    m3u_download_url = "",
    epg_cache_refresh_start = "00:04",
    epg_cache_refresh_interval_hours = 7,
    catchup_preload_seconds = 15,
    iptv_default_user_agent = "SYTV/1.6",
    iptv_network_timeout = 8,
    iptv_retry_count = 2,
    iptv_retry_delay = 1.0,
    iptv_format_fallback = true,
    iptv_source_fallback = true,
    menu_subtitle_font_size = 0,
    menu_level1_min_width = 0,
    menu_level2_min_width = 0,
    menu_level3_min_width = 0,
    menu_level4_min_width = 0
}

-- 【新增】支持 myepg.conf 本地私有配置覆盖，便于发布时排除个人地址
local function trim_option_value(value)
    if not value then return "" end
    return value:match("^%s*(.-)%s*$")
end

local function coerce_override_value(current_value, raw_value)
    local value = trim_option_value(raw_value)

    if type(current_value) == "number" then
        local parsed_number = tonumber(value)
        if parsed_number ~= nil then
            return parsed_number
        end
        return current_value
    end

    if type(current_value) == "boolean" then
        local normalized = value:lower()
        if normalized == "yes" or normalized == "true" or normalized == "1" then
            return true
        end
        if normalized == "no" or normalized == "false" or normalized == "0" then
            return false
        end
        return current_value
    end

    return value
end

local function load_local_override_options(target_options)
    local override_path = mp.command_native({"expand-path", "~~home/script-opts/myepg.conf"})
    local file = io.open(override_path, "r")
    if not file then
        return
    end

    local content = file:read("*a")
    file:close()
    if not content or content == "" then
        return
    end

    if content:sub(1, 3) == "\239\187\191" then
        content = content:sub(4)
    end

    local applied_count = 0
    for raw_line in content:gmatch("([^\r\n]+)") do
        local line = trim_option_value(raw_line)
        if line ~= "" and not line:match("^#") and not line:match("^;") then
            local key, value = line:match("^([%w_%-%.]+)%s*=%s*(.-)%s*$")
            if key and target_options[key] ~= nil then
                target_options[key] = coerce_override_value(target_options[key], value)
                applied_count = applied_count + 1
            end
        end
    end

    if applied_count > 0 then
        mp.msg.info("已加载 myepg.conf 覆盖配置: " .. override_path)
    end
end

opt.read_options(options)
load_local_override_options(options)

-- ==================== 全局状态 ====================

state = {
    m3u_path = "",
    m3u_source_key = "",
    epg_url = "",
    groups = {},
    group_names = {},
    epg_data = {},
    channel_bucket_cache = {},
    url_to_channel_map = {},
    url_prefix_channel_map = {},
    url_prefix_ambiguous = {},
    channel_key_map = {},
    format_cache = {},
    format_cache_dirty = false,
    last_played_url = nil,
    last_played_source = nil,
    current_source_index = nil,
    playback_generation = 0,
    active_playback_session = nil,
    active_attempt = nil,
    queued_playback_sessions = {},
    playback_retry_timer = nil,
    is_loaded = false,
    current_channel = nil,
    history_file = "epg_history.json",
    channel_history = {},
    history_dirty = false,
    auto_playing = false,  -- 标记是否正在自动播放历史频道
    selected_group_name = nil,
    selected_channel_index = nil,
    -- 当前回看上下文（用于续播）
    -- 结构: {live_url, catchup_template, start_utc, last_end_utc, last_duration}
    current_catchup = nil,
    current_catchup_path = nil,
    queued_catchup = nil,
    queued_catchup_path = nil,
    next_catchup_queued = false,
    current_time_pos = 0,
    last_iptv_menu_data = nil,
    is_subscription_mode = false,
    subscription_url = "",
    subscription_cache_path = nil,
    subscription_last_hash = nil,
    subscription_refresh_in_progress = false,
    subscription_bootstrap_started = false,
    active_source_kind = "none"
}

-- ==================== 全局共享缓存 ====================

channel_search_romanization = nil
channel_search_cache = {}
xmltv_utc_cache = {}
utc_timestamp_cache = {}
display_date_cache = {}
timezone_offset_cache = {}
local_day_start_cache = {}
top_center_osd_timer = nil
history_save_timer = nil
timepos_check_timer = nil

-- ==================== 菜单延迟常量 ====================

MENU_RENDER_DELAY = 0.005
MENU_EXPAND_DELAY = 0.005
MENU_SELECT_DELAY = 0.005
HISTORY_SAVE_DELAY = 2.0
TIMEPOS_CHECK_INTERVAL = 1.0

-- ==================== 日期桶常量 ====================

CHINESE_WEEKDAYS = {"星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"}
DATE_BUCKET_ORDER = {"tomorrow", "today", "yesterday", "day_minus_2", "day_minus_3", "day_minus_4", "day_minus_5", "day_minus_6"}
DATE_BUCKET_LABELS = {
    tomorrow = "明天",
    today = "今天",
    yesterday = "昨天",
}

-- ==================== 前向声明（全局，供各模块赋值） ====================

build_main_menu = nil
build_channel_epg_items = nil
build_channel_date_bucket_items = nil
build_channel_menu_item = nil
get_channel_by_position = nil

function sync_iptv_button_state()
    local current_path = mp.get_property("path")
    local normalized_path = current_path and current_path:gsub("^file://", "") or nil
    local working_directory = mp.get_property("working-directory") or ""

    if normalized_path and working_directory ~= ""
        and not normalized_path:match("^/") and not normalized_path:match("^%a+:") then
        normalized_path = utils.join_path(working_directory, normalized_path)
    end

    local current_channel_url = state.current_channel and state.current_channel.url or nil
    local is_live_channel = false
    if current_path and state.current_channel then
        for _, source in ipairs(state.current_channel.sources or {}) do
            if current_path == source.url or (url_matches and url_matches(current_path, source.url)) then
                is_live_channel = true
                break
            end
        end
        if not is_live_channel and current_channel_url then
            is_live_channel = current_path == current_channel_url
                or (url_matches and url_matches(current_path, current_channel_url))
        end
    end
    local active_attempt = state.active_attempt
    if active_attempt and active_attempt.started and active_attempt.role == "live" then
        is_live_channel = true
    end
    local current_catchup_path = state.current_catchup_path
    local is_catchup_channel = current_path and current_catchup_path
        and (current_path == current_catchup_path or (url_matches and url_matches(current_path, current_catchup_path)))
    if active_attempt and active_attempt.started and active_attempt.role == "catchup" then
        is_catchup_channel = true
    end
    local is_local_m3u = normalized_path and state.m3u_path ~= "" and normalized_path == state.m3u_path
    local is_subscription_source = state.is_subscription_mode and state.is_loaded
    local is_iptv_active = is_live_channel or is_catchup_channel or is_local_m3u or is_subscription_source or false
    local current_group_name = state.current_channel and state.current_channel.group or state.selected_group_name
    local current_channel_name = state.current_channel and state.current_channel.name or nil

    mp.set_property_native("user-data/epg/is_iptv_active", is_iptv_active)
    mp.set_property_native("user-data/epg/is_catchup", state.current_catchup ~= nil)
    mp.set_property_native("user-data/epg/selected_group_name", state.selected_group_name)
    mp.set_property_native("user-data/epg/selected_channel_index", state.selected_channel_index)
    mp.set_property_native("user-data/epg/current_group_name", current_group_name)
    mp.set_property_native("user-data/epg/current_channel_name", current_channel_name)
end

function clear_queued_catchup_state()
    state.queued_catchup = nil
    state.queued_catchup_path = nil
    state.next_catchup_queued = false
    if clear_queued_iptv_playback_sessions then
        clear_queued_iptv_playback_sessions()
    end
end

function cancel_timepos_check_timer()
    if timepos_check_timer then
        timepos_check_timer:kill()
        timepos_check_timer = nil
    end
end

function set_queued_catchup_state(catchup_context, playback_url)
    state.queued_catchup = catchup_context
    state.queued_catchup_path = playback_url
    state.next_catchup_queued = catchup_context ~= nil and playback_url ~= nil
end

function set_current_catchup_state(catchup_context, playback_url)
    state.current_catchup = catchup_context
    state.current_catchup_path = playback_url
    state.current_time_pos = 0
    if not catchup_context then
        cancel_timepos_check_timer()
    end
    if not catchup_context then
        clear_queued_catchup_state()
    end
    sync_iptv_button_state()
end

-- 抽取回看预加载检查为单独函数，供节流定时器调用
local function perform_catchup_preload_check()
    if not state.current_catchup or state.next_catchup_queued then return end

    local time_pos = state.current_time_pos
    if not time_pos or time_pos < 0 then return end

    local duration = mp.get_property_number("duration") or state.current_catchup.last_duration
    if not duration or duration <= 0 then return end

    local preload_seconds = tonumber(options.catchup_preload_seconds) or 15
    if preload_seconds < 1 then preload_seconds = 1 end
    if duration - time_pos > preload_seconds then return end

    local cc = state.current_catchup
    local start_ts = utc_str_to_timestamp(cc.start_utc)
    if not start_ts then
        mp.msg.warn("回看预加载: 无法解析当前 start_utc，跳过预加载")
        return
    end

    local next_start_ts = start_ts + math.floor(duration + 0.5)
    local next_start_utc = to_utc_string(next_start_ts)
    local next_end_utc = calc_resume_end_utc(next_start_utc)
    if not next_end_utc then
        mp.msg.warn("回看预加载: 无法计算 next_end_utc，跳过预加载")
        return
    end

    local new_url = replace_catchup_time_params(cc.catchup_template, next_start_utc, next_end_utc)
    local queued_context = {
        live_url = cc.live_url,
        catchup_template = cc.catchup_template,
        start_utc = next_start_utc,
        last_end_utc = next_end_utc,
        last_duration = nil,
        channel = cc.channel,
        source = cc.source,
        source_index = cc.source_index,
    }

    local catchup_channel = cc.channel or find_channel_by_url(cc.live_url)
    local sources = build_catchup_playback_sources(
        catchup_channel,
        next_start_utc,
        next_end_utc,
        cc.catchup_template,
        new_url
    )
    local loaded, queued_session = load_iptv_sources(sources, "catchup-preload", {
        role = "catchup",
        channel = catchup_channel,
        preferred_source_index = cc.source_index or state.current_source_index or 1,
        load_mode = "insert-next",
        clear_catchup_queue = false,
    })
    if not loaded or not queued_session or not queued_session.current_attempt then
        return
    end

    queued_context.source = queued_session.current_attempt.source
    queued_context.source_index = queued_session.current_attempt.source_index
    set_queued_catchup_state(queued_context, queued_session.current_attempt.source.url)
    mp.msg.info(string.format("回看预加载: 已提前排队下一段 start=%s end=%s", next_start_utc, next_end_utc))
end

function set_current_channel_state(channel)
    state.current_channel = channel
    sync_iptv_button_state()
end

-- ==================== 加载子模块 ====================

require('utils')
require('data')
require('playback')
require('menu')

-- ==================== mp.* 绑定与事件 ====================

-- 快捷键绑定
mp.add_key_binding(nil, "show-iptv-menu", show_iptv_menu)
mp.add_key_binding(nil, "channel-group-prev", function()
    switch_channel_in_current_group(-1)
end)
mp.add_key_binding(nil, "channel-group-next", function()
    switch_channel_in_current_group(1)
end)
mp.add_key_binding(nil, "show-epg-search-menu", show_epg_search_menu)
mp.add_key_binding(nil, "force-refresh-epg", force_refresh_epg)

-- 脚本消息
mp.register_script_message("iptv-channel-search", function(query)
    handle_iptv_channel_search(query)
end)

mp.register_script_message("channel-group-prev", function()
    switch_channel_in_current_group(-1)
end)

mp.register_script_message("channel-group-next", function()
    switch_channel_in_current_group(1)
end)

mp.register_script_message("play-live-channel", function(channel_url, show_osd, group_name, channel_index)
    local numeric_channel_index = tonumber(channel_index)
    local positioned_channel = get_channel_by_position(group_name, numeric_channel_index)
    if positioned_channel and positioned_channel.url == channel_url then
        play_live_channel(positioned_channel, show_osd == "yes", group_name, numeric_channel_index)
        return
    end

    local channel = find_channel_by_url(channel_url)
    if channel then
        local preferred_source_index = find_channel_source_index_by_url(channel, channel_url) or 1
        play_live_channel(
            channel,
            show_osd == "yes",
            group_name,
            numeric_channel_index,
            preferred_source_index
        )
        return
    end

    if channel_url and channel_url ~= "" then
        load_iptv_url(channel_url, "script-message-fallback")
    end
end)

mp.register_script_message("open-channel-date-bucket", function(channel_url, bucket_key, reference_utc, channel_key)
    show_channel_date_bucket_menu(channel_url, bucket_key, reference_utc, channel_key)
end)

-- 处理回看播放请求（由菜单项触发）
-- 参数: catchup_url, catchup_template, start_utc, end_utc, live_url, channel_key（可选）
mp.register_script_message("play-catchup", function(catchup_url, catchup_template, start_utc, end_utc, live_url, channel_key)
    mp.msg.info(string.format("play-catchup: start=%s end=%s", start_utc, end_utc))
    if not catchup_template or not start_utc or not end_utc or not live_url then
        mp.msg.error("play-catchup: 参数不完整")
        if catchup_url and catchup_url ~= "" then load_iptv_url(catchup_url, "catchup-fallback", false) end
        return
    end

    -- 如果菜单构建阶段没有预先计算 URL，则在点击时再根据模板即时生成（避免菜单打开时大量 gsub）
    if not catchup_url or catchup_url == "" then
        catchup_url = replace_catchup_time_params(catchup_template, start_utc, end_utc)
    end

    local catchup_channel
    if channel_key and channel_key ~= "" then
        catchup_channel = find_channel_by_key(channel_key)
        if not catchup_channel then return end
    else
        catchup_channel = find_channel_by_url(live_url)
    end
    local same_current_channel = catchup_channel and state.current_channel and (
        (catchup_channel.key and state.current_channel.key and catchup_channel.key == state.current_channel.key)
        or (not catchup_channel.key and catchup_channel.url == state.current_channel.url)
    )
    local preferred_source_index = same_current_channel and (state.current_source_index or 1) or 1
    local catchup_sources = build_catchup_playback_sources(
        catchup_channel,
        start_utc,
        end_utc,
        catchup_template,
        catchup_url
    )

    local loaded = load_iptv_sources(catchup_sources, "catchup", {
        role = "catchup",
        channel = catchup_channel,
        preferred_source_index = preferred_source_index,
    })
    if not loaded then return end

    set_current_catchup_state({
        live_url         = live_url,
        catchup_template = catchup_template,
        start_utc        = start_utc,
        last_end_utc     = end_utc,
        last_duration    = nil,
        channel          = catchup_channel,
        source           = catchup_sources[preferred_source_index] or catchup_sources[1],
        source_index     = preferred_source_index,
    }, catchup_url)

    if catchup_channel then
        set_current_channel_state(catchup_channel)
    end
end)

local function resolve_local_m3u_path(path)
    if not path or path == "" then return nil end
    local lower_path = path:lower()
    local scheme = lower_path:match("^([%a][%w+.-]*)://")
    if scheme and scheme ~= "file" then
        return nil
    end
    if not lower_path:match("%.m3u$") and not lower_path:match("%.m3u8$") then
        return nil
    end

    local clean_path = path:gsub("^[Ff][Ii][Ll][Ee]://", "")
    local is_windows = package.config:sub(1, 1) == '\\'
    if is_windows and clean_path:match("^/%a:[/\\]") then
        clean_path = clean_path:sub(2)
    end
    local wd = mp.get_property("working-directory") or ""
    if wd ~= "" and not clean_path:match("^/") and not clean_path:match("^%a+:") then
        clean_path = utils.join_path(wd, clean_path)
    end
    return clean_path
end

local local_m3u_hook_enabled = type(mp.add_hook) == "function"
local local_m3u_intercept_generation = 0

if local_m3u_hook_enabled then
    -- 必须在 mpv 原生 playlist demuxer 展开 URL 之前接管。path observer 已经太晚，
    -- 异步产生的裸 HLS 分片可能在 playlist-clear 后重新进入播放列表。
    mp.add_hook("on_load", 20, function(hook)
        local path = mp.get_property("path")
        local clean_path = resolve_local_m3u_path(path)
        if not clean_path then
            hook:cont()
            return
        end

        local is_iptv_m3u, content, parsed = probe_iptv_m3u(clean_path)
        if not is_iptv_m3u then
            -- 本地 HLS 或普通相对路径播放列表仍由 mpv 原生处理。
            hook:cont()
            return
        end

        local_m3u_intercept_generation = local_m3u_intercept_generation + 1
        local generation = local_m3u_intercept_generation
        state.active_source_kind = "local"
        state.m3u_path = clean_path
        set_current_catchup_state(nil, nil)

        -- 让当前顶层条目只打开无网络副作用的 null://，随后由 descriptor session
        -- replace；这样原始 M3U 中的 pipe URL 永远不会交给 mpv 原生解析。
        mp.set_property("stream-open-filename", "null://")
        mp.add_timeout(0, function()
            if generation ~= local_m3u_intercept_generation then return end
            -- stop 会丢弃当前原生 playlist 及其仍在异步展开的子条目；仅
            -- playlist-clear 会保留 current，无法阻止晚到的裸 HLS 分片。
            mp.commandv("stop")
            mp.commandv("playlist-clear")
            mp.osd_message("解析 M3U...", 2)
            if parse_m3u(clean_path, {content = content, parsed = parsed}) then
                mp.osd_message("IPTV 已加载！鼠标右键:选台菜单", 4)
            else
                mp.osd_message("IPTV M3U 解析失败", 4)
            end
            sync_iptv_button_state()
        end)
        hook:cont()
    end)
end

-- 跟踪当前播放路径（M3U加载 + 频道跟踪）
mp.observe_property("path", "string", function(name, path)
    if not path then return end

    -- 本地 M3U 由 on_load hook 在原生 playlist demuxer 前接管；旧 mpv 没有
    -- add_hook 时才保留 observer 兼容回退。
    local clean_path = resolve_local_m3u_path(path)
    if clean_path then
        if local_m3u_hook_enabled then
            sync_iptv_button_state()
            return
        end
        if clean_path == state.m3u_path and state.is_loaded then
            sync_iptv_button_state()
            return
        end
        state.active_source_kind = "local"
        state.m3u_path = clean_path
        set_current_catchup_state(nil, nil)
        mp.osd_message("解析 M3U...", 2)
        if parse_m3u(clean_path) then
            mp.osd_message("IPTV 已加载！鼠标右键:选台菜单", 4)
        end
        sync_iptv_button_state()
        return
    end

    if path_matches_active_catchup(path) then
        sync_iptv_button_state()
        return
    end

    local live_attempt = state.active_attempt
    -- 已知直播请求保留 descriptor 身份；共用 URL 无法区分频道和不同 Header 的线路。
    if live_attempt and live_attempt.role == "live" and live_attempt.channel
        and url_matches(path, live_attempt.source.url) then
        sync_iptv_button_state()
        return
    end

    local map_entry = find_channel_map_entry_by_url(path)

    if map_entry then
        local ch = map_entry.channel
        local matched_group_name = map_entry.group_name
        local matched_channel_index = map_entry.channel_index
        local selected_channel = get_channel_by_position(state.selected_group_name, state.selected_channel_index)
        local selected_matches = selected_channel and (
            (selected_channel.key and ch.key and selected_channel.key == ch.key)
            or (not selected_channel.key and selected_channel.url == ch.url)
        )
        if selected_channel and not selected_matches then
            sync_iptv_button_state()
            return
        end

        set_current_catchup_state(nil, nil)
        if selected_matches then
            matched_group_name = state.selected_group_name
            matched_channel_index = state.selected_channel_index
            ch = selected_channel
        end
        state.current_source_index = find_channel_source_index_by_url(ch, path)
            or state.current_source_index
        set_selected_channel_position(matched_group_name, matched_channel_index)
        local current_matches = state.current_channel and (
            (state.current_channel.key and ch.key and state.current_channel.key == ch.key)
            or (not state.current_channel.key and state.current_channel.url == ch.url)
        )
        if not current_matches then
            set_current_channel_state(ch)
            mp.msg.info("当前频道: " .. ch.name)
            if not state.auto_playing then
                save_current_channel_to_history()
            end
        end
        sync_iptv_button_state()
        return
    end

    sync_iptv_button_state()
end)

-- 回看播放中缓存当前片段时长（end-file时duration可能已不可用）
mp.observe_property("duration", "number", function(name, duration)
    if not state.current_catchup then return end
    if not duration or duration <= 0 then return end
    state.current_catchup.last_duration = duration
end)

mp.observe_property("time-pos", "number", function(name, time_pos)
    state.current_time_pos = (time_pos and time_pos >= 0) and time_pos or 0

    -- 节流：只在未排队并且存在回看上下文时以秒级频率触发检查
    if not state.current_catchup or state.next_catchup_queued then return end

    if not timepos_check_timer then
        timepos_check_timer = mp.add_timeout(TIMEPOS_CHECK_INTERVAL, function()
            timepos_check_timer = nil
            perform_catchup_preload_check()
        end)
    end
end)

local function try_activate_queued_catchup_state()
    if not state.queued_catchup or not state.queued_catchup_path then
        return false
    end

    local current_path = mp.get_property("path")
    if not current_path then
        return false
    end

    if current_path ~= state.queued_catchup_path and not url_matches(current_path, state.queued_catchup_path) then
        return false
    end

    local queued_context = state.queued_catchup
    local queued_path = state.queued_catchup_path
    clear_queued_catchup_state()
    set_current_catchup_state(queued_context, queued_path)
    mp.msg.info(string.format("回看预加载: 已切换到预排队片段 start=%s", tostring(queued_context.start_utc)))
    return true
end

mp.register_event("start-file", function()
    local handled, _, was_queued = handle_iptv_start_file()
    if handled and was_queued then
        try_activate_queued_catchup_state()
    end
end)

mp.register_event("file-loaded", function()
    handle_iptv_file_loaded()
    sync_iptv_button_state()
end)

mp.register_event("shutdown", function()
    flush_channel_history()
    save_iptv_format_cache()
end)

-- end-file 事件驱动回看续播
mp.register_event("end-file", function(event)
    if event.reason == "error" and handle_iptv_end_file(event) then
        sync_iptv_button_state()
        return
    end

    if event.reason ~= "eof" then
        if event.reason == "quit" then
            set_current_catchup_state(nil, nil)
        end
        sync_iptv_button_state()
        return
    end

    if not state.current_catchup then return end

    if state.next_catchup_queued and state.queued_catchup then
        mp.msg.info("回看续播预加载: 当前片段结束，交由已排队下一段继续播放")
        return
    end

    local cc = state.current_catchup
    local live_duration = mp.get_property_number("duration")
    local duration = live_duration or cc.last_duration
    local start_ts = utc_str_to_timestamp(cc.start_utc)
    if not duration or not start_ts then
        mp.msg.warn(string.format("回看续播调试: 无法推算next_start，duration=%s start_utc=%s", tostring(duration), tostring(cc.start_utc)))
        set_current_catchup_state(nil, nil)
        return
    end
    if not live_duration and cc.last_duration then
        mp.msg.info(string.format("回看续播调试: 使用缓存duration=%.3f", cc.last_duration))
    end
    local end_ts = start_ts + math.floor(duration + 0.5)
    local next_start_utc = to_utc_string(end_ts)
    mp.msg.info(string.format("回看续播调试: duration推算next_start=%s (start=%s duration=%.3f)", next_start_utc, cc.start_utc, duration))

    local next_end_utc = calc_resume_end_utc(next_start_utc)
    if not next_end_utc then
        set_current_catchup_state(nil, nil)
        return
    end

    local new_url = replace_catchup_time_params(cc.catchup_template, next_start_utc, next_end_utc)
    mp.msg.info(string.format("回看续播: start_utc %s -> %s, end_utc -> %s", cc.start_utc, next_start_utc, next_end_utc))
    mp.msg.info("回看续播调试: new_url=" .. redact_iptv_url(new_url))
    mp.osd_message(string.format("回看续播中... 已延伸至 %s:%s",
        next_end_utc:sub(9,10), next_end_utc:sub(11,12)), 3)

    cc.start_utc = next_start_utc
    cc.last_end_utc = next_end_utc
    local catchup_channel = cc.channel or find_channel_by_url(cc.live_url)
    local sources = build_catchup_playback_sources(
        catchup_channel,
        next_start_utc,
        next_end_utc,
        cc.catchup_template,
        new_url
    )
    local loaded, session = load_iptv_sources(sources, "catchup-resume", {
        role = "catchup",
        channel = catchup_channel,
        preferred_source_index = cc.source_index or state.current_source_index or 1,
    })
    if loaded and session and session.current_attempt then
        cc.channel = catchup_channel
        cc.source = session.current_attempt.source
        cc.source_index = session.current_attempt.source_index
        set_current_catchup_state(cc, session.current_attempt.source.url)
    else
        set_current_catchup_state(nil, nil)
    end
end)

-- ==================== 初始化 ====================

mp.msg.info("IPTV 脚本已加载: 鼠标右键=四级选台菜单 (分组 > 频道 > 日期桶 > EPG)")
mp.msg.info("===== EPG 脚本初始化调试信息 =====")
mp.msg.info("工作目录: " .. tostring(mp.get_property("working-directory", "未知")))

local expanded_home = ""
local success, home_path = pcall(function()
    return mp.command_native({"expand-path", "~~home/"})
end)
if success then expanded_home = home_path end
mp.msg.info("配置目录: " .. tostring(expanded_home ~= "" and expanded_home or "未找到"))
mp.msg.info("==========================")

load_channel_history()
load_iptv_format_cache()
sync_iptv_button_state()

mp.add_timeout(0.2, function()
    if state.subscription_bootstrap_started or state.is_loaded then
        return
    end

    local subscription_url = trim(options.m3u_download_url)
    if subscription_url == "" then
        return
    end

    local current_path = mp.get_property("path")
    if current_path and current_path ~= "" then
        return
    end

    state.subscription_bootstrap_started = true
    state.active_source_kind = "subscription"
    bootstrap_subscription_m3u()
end)

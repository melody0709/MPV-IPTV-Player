--[[
    playback.lua - IPTV source/session 播放控制层
    包含：文件级 Header/格式选项、有限候选回退、直播/回看 source 构建、组内切台。
]]

local mp = require 'mp'
local source_model = require 'source'

local function clamp_integer(value, default_value, minimum, maximum)
    local number = tonumber(value)
    if not number then
        number = default_value
    end
    number = math.floor(number)
    if number < minimum then number = minimum end
    if number > maximum then number = maximum end
    return number
end

local function clamp_number(value, default_value, minimum, maximum)
    local number = tonumber(value) or default_value
    if number < minimum then number = minimum end
    if number > maximum then number = maximum end
    return number
end

local function copy_array(input)
    local result = {}
    for _, value in ipairs(input or {}) do
        result[#result + 1] = value
    end
    return result
end

local function get_playback_settings(overrides)
    local settings = {
        default_user_agent = options.iptv_default_user_agent,
        network_timeout = clamp_number(options.iptv_network_timeout, 8, 1, 60),
        retry_count = clamp_integer(options.iptv_retry_count, 2, 0, 5),
        retry_delay = clamp_number(options.iptv_retry_delay, 1.0, 0.1, 10),
        format_fallback = options.iptv_format_fallback ~= false,
        source_fallback = options.iptv_source_fallback ~= false,
        format_cache = state.format_cache or {},
    }
    for key, value in pairs(overrides or {}) do
        settings[key] = value
    end
    return settings
end

local function dispatch_loadfile(playback_url, load_mode, file_options)
    local effective_mode = load_mode or "replace"
    mp.command_native({"loadfile", playback_url, effective_mode, -1, file_options or {}})
end

function cancel_iptv_retry_timer()
    if state.playback_retry_timer then
        state.playback_retry_timer:kill()
        state.playback_retry_timer = nil
    end
end

function clear_queued_iptv_playback_sessions()
    if state.queued_playback_sessions and #state.queued_playback_sessions > 0
        and mp.commandv then
        -- playlist-clear 保留当前项，只移除 insert-next 等待项，避免手动切台后旧回看再次跳出。
        mp.commandv("playlist-clear")
    end
    state.queued_playback_sessions = {}
end

local function remove_queued_session(session)
    local retained = {}
    for _, queued in ipairs(state.queued_playback_sessions or {}) do
        if queued ~= session then
            retained[#retained + 1] = queued
        end
    end
    state.queued_playback_sessions = retained
end

local function next_generation()
    state.playback_generation = (tonumber(state.playback_generation) or 0) + 1
    return state.playback_generation
end

local function normalize_sources(sources)
    local result = {}
    for _, value in ipairs(sources or {}) do
        local source
        if type(value) == "string" then
            source = source_model.make_source(value)
        elseif type(value) == "table" and value.url then
            source = source_model.make_source(value.url, value)
        end
        if source and source.url ~= "" then
            result[#result + 1] = source
        end
    end
    return result
end

local function log_attempt(attempt)
    local source = attempt.source
    mp.msg.info(string.format(
        "[IPTV] session=%d context=%s candidate=%d/%d source=%d mode=%s reconnect=%d url=%s headers=%s",
        attempt.generation,
        attempt.context,
        attempt.candidate_index,
        #attempt.session.candidates,
        attempt.source_index,
        attempt.mode,
        attempt.reconnect_count,
        source_model.redact_url(source.url),
        source_model.header_names_summary(source.headers)
    ))
end

local function dispatch_session_candidate(session, candidate_index, reconnect_count, load_mode, activate)
    local candidate = session.candidates[candidate_index]
    if not candidate then
        return false
    end

    local effective_mode = load_mode or session.load_mode or "replace"
    local file_options = source_model.build_mpv_file_options(
        candidate.source,
        candidate.mode,
        session.settings
    )
    local attempt = {
        generation = session.generation,
        channel_key = session.channel and session.channel.key or nil,
        channel = session.channel,
        context = session.context,
        role = session.role,
        source_index = candidate.source.original_source_index or candidate.source_index,
        candidate_source_index = candidate.source_index,
        candidate_index = candidate_index,
        mode = candidate.mode,
        source = candidate.source,
        file_options = file_options,
        file_loaded = false,
        started = false,
        reconnect_count = reconnect_count or 0,
        open_retry_round = session.open_retry_round or 0,
        playlist_entry_id = nil,
        load_mode = effective_mode,
        session = session,
    }
    session.candidate_index = candidate_index
    session.current_attempt = attempt
    session.attempted_sources[attempt.source_index] = true
    session.attempted_modes[attempt.mode] = true

    if activate ~= false then
        state.active_playback_session = session
        state.active_attempt = attempt
        state.last_played_url = attempt.source.url
        state.last_played_source = attempt.source
    end

    if effective_mode == "replace" and activate ~= false and mp.commandv then
        -- IPTV 菜单自行管理频道/回看候选；清掉 mpv 原生 M3U 展开的剩余裸 URL，
        -- 避免当前流结束后绕过 descriptor 自动跳到下一项。
        mp.commandv("playlist-clear")
    end
    log_attempt(attempt)
    dispatch_loadfile(attempt.source.url, effective_mode, file_options)
    return true
end

local function drm_types_for_sources(sources, skipped_indices)
    local types = {}
    local seen = {}
    for _, index in ipairs(skipped_indices or {}) do
        local drm = sources[index] and sources[index].drm or nil
        local drm_type = drm and source_model.trim(drm.type) or ""
        if drm_type == "" then drm_type = "unknown" end
        if not seen[drm_type] then
            seen[drm_type] = true
            types[#types + 1] = drm_type
        end
    end
    return table.concat(types, ", ")
end

local function create_playback_session(sources, context, params)
    local request = params or {}
    local normalized_sources = normalize_sources(sources)
    local settings = get_playback_settings({
        format_fallback = request.format_fallback,
        source_fallback = request.source_fallback,
    })
    if request.format_fallback == nil then
        settings.format_fallback = options.iptv_format_fallback ~= false
    end
    if request.source_fallback == nil then
        settings.source_fallback = options.iptv_source_fallback ~= false
    end

    local candidates, skipped_drm = source_model.build_candidates(
        normalized_sources,
        (function()
            local preferred = tonumber(request.preferred_source_index)
            if preferred then
                for index, source in ipairs(normalized_sources) do
                    if tonumber(source.original_source_index) == preferred then
                        return index
                    end
                end
            end
            return preferred
        end)(),
        settings
    )
    if #candidates == 0 then
        if #skipped_drm > 0 then
            local drm_types = drm_types_for_sources(normalized_sources, skipped_drm)
            mp.msg.error("[IPTV] 频道所有线路都需要当前 mpv 层不支持的 DRM: " .. drm_types)
            mp.osd_message("播放失败：该频道需要 DRM（当前不支持）", 5)
        else
            mp.msg.error("[IPTV] 没有可用的播放线路")
            mp.osd_message("播放失败：没有可用线路", 4)
        end
        return nil
    end

    if #skipped_drm > 0 then
        mp.msg.warn(string.format("[IPTV] 已跳过 %d 条 DRM 线路，继续尝试非 DRM 线路", #skipped_drm))
    end

    return {
        generation = next_generation(),
        context = context or "unknown",
        role = request.role or "generic",
        channel = request.channel,
        sources = normalized_sources,
        candidates = candidates,
        skipped_drm = skipped_drm,
        settings = settings,
        load_mode = request.load_mode or "replace",
        queued = request.load_mode == "insert-next",
        attempted_sources = {},
        attempted_modes = {},
        open_retry_round = 0,
        current_attempt = nil,
        candidate_index = 1,
    }
end

function load_iptv_sources(sources, context, params)
    local request = params or {}
    local session = create_playback_session(sources, context, request)
    if not session then
        return false
    end

    if session.queued then
        state.queued_playback_sessions = state.queued_playback_sessions or {}
        state.queued_playback_sessions[#state.queued_playback_sessions + 1] = session
        if not dispatch_session_candidate(session, 1, 0, "insert-next", false) then
            remove_queued_session(session)
            return false
        end
        return true, session
    end

    cancel_iptv_retry_timer()
    clear_queued_iptv_playback_sessions()
    if request.clear_catchup_queue ~= false and clear_queued_catchup_state then
        clear_queued_catchup_state()
    end
    return dispatch_session_candidate(session, 1, 0, session.load_mode, true), session
end

function load_iptv_channel(channel, context, preferred_source_index, params)
    if not channel then
        return false
    end
    local sources = channel.sources
    if type(sources) ~= "table" or #sources == 0 then
        sources = {{url = channel.url, headers = {}}}
    end
    local request = params or {}
    request.channel = channel
    request.role = request.role or "live"
    request.preferred_source_index = preferred_source_index or request.preferred_source_index
    return load_iptv_sources(sources, context or "live-channel", request)
end

-- 兼容旧调用签名；内部仍创建完整 descriptor/session，不再裸 URL 重试。
function load_iptv_url(url, context, allow_hls_retry, force_hls, load_mode, file_options)
    local source = source_model.make_source(url, {
        headers = {},
        format = force_hls and "hls" or nil,
        format_origin = force_hls and "compat-force" or nil,
        file_options = file_options,
    })
    if not source or source.url == "" then
        return false
    end
    return load_iptv_sources({source}, context, {
        role = context and context:match("^catchup") and "catchup" or "generic",
        load_mode = load_mode or "replace",
        format_fallback = allow_hls_retry ~= false,
        source_fallback = false,
    })
end

function should_force_hls_for_iptv_url(url)
    return source_model.supports_http_format_fallback(url)
        and source_model.infer_format_from_url(url) == nil
end

function redact_iptv_url(url)
    return source_model.redact_url(url)
end

local function attempt_matches_path(attempt, path)
    return attempt and path and (path == attempt.source.url or url_matches(path, attempt.source.url))
end

local function activate_session_for_start(session, path, playlist_entry_id)
    session.queued = false
    session.load_mode = "replace"
    local attempt = session.current_attempt
    attempt.started = true
    attempt.load_mode = "replace"
    attempt.playlist_entry_id = playlist_entry_id
    state.active_playback_session = session
    state.active_attempt = attempt
    state.last_played_url = attempt.source.url
    state.last_played_source = attempt.source
    return attempt
end

function handle_iptv_start_file()
    local path = mp.get_property("path")
    local playlist_entry_id = mp.get_property_number("playlist-entry-id")
    local active = state.active_playback_session
    local active_attempt = active and active.current_attempt or nil
    local active_entry_matches = not active_attempt or not active_attempt.playlist_entry_id
        or not playlist_entry_id or active_attempt.playlist_entry_id == playlist_entry_id
    if active and active_entry_matches and attempt_matches_path(active_attempt, path) then
        activate_session_for_start(active, path, playlist_entry_id)
        return true, active, false
    end

    for _, queued in ipairs(copy_array(state.queued_playback_sessions)) do
        if attempt_matches_path(queued.current_attempt, path) then
            remove_queued_session(queued)
            activate_session_for_start(queued, path, playlist_entry_id)
            return true, queued, true
        end
    end
    -- loadfile replace 前一个 entry 的 start-file 可能晚到；新 attempt 尚未 start 时
    -- 不应被这个旧事件清掉。已确认 start 的 IPTV entry 被真正的外部文件替换时才清理。
    if active_attempt and active_attempt.started then
        cancel_iptv_retry_timer()
        state.active_playback_session = nil
        state.active_attempt = nil
    end
    return false, nil, false
end

local function update_catchup_source_context(attempt)
    if attempt.role ~= "catchup" or not state.current_catchup then
        return
    end
    state.current_catchup_path = attempt.source.url
    state.current_catchup.source = source_model.clone_source(attempt.source)
    state.current_catchup.source_index = attempt.source_index
    if attempt.source.catchup and attempt.source.catchup ~= "" then
        state.current_catchup.catchup_template = attempt.source.catchup
    end
end

function handle_iptv_file_loaded()
    local session = state.active_playback_session
    local attempt = state.active_attempt
    if not session or not attempt or not attempt.started then
        return false
    end

    cancel_iptv_retry_timer()
    attempt.file_loaded = true
    local current_source_index = attempt.source_index
    if attempt.role == "live" and state.current_channel ~= session.channel then
        -- 订阅刷新会重建频道并重排线路，旧会话的序号不能直接用于新频道模型。
        current_source_index = nil
        for index, source in ipairs(state.current_channel and state.current_channel.sources or {}) do
            if source.id == attempt.source.id then
                current_source_index = index
                break
            end
        end
    end
    state.current_source_index = current_source_index
    update_catchup_source_context(attempt)

    local detected_format = source_model.normalize_format(mp.get_property("file-format"))
    local successful_format = attempt.mode ~= "auto" and attempt.mode or detected_format
    if successful_format and remember_iptv_source_format(attempt.source, successful_format) then
        save_iptv_format_cache()
    end

    local stream_path = mp.get_property("stream-open-filename") or attempt.source.url
    mp.msg.info(string.format(
        "[IPTV] 已加载 session=%d source=%d mode=%s final=%s",
        attempt.generation,
        attempt.source_index,
        attempt.mode,
        source_model.redact_url(stream_path)
    ))

    if attempt.role == "live" and state.current_channel and current_source_index then
        save_current_channel_to_history()
    end
    return true
end

local function classify_playback_error(event, attempt)
    if source_model.source_requires_drm(attempt.source) then
        return "drm"
    end
    local message = tostring((event and (event.error or event.file_error)) or ""):lower()
    if message:find("timed out", 1, true) or message:find("timeout", 1, true) then
        return "timeout"
    end
    if message:find("certificate", 1, true) or message:find("tls", 1, true)
        or message:find("ssl", 1, true) then
        return "tls"
    end
    if message:find("401", 1, true) or message:find("403", 1, true)
        or message:find("unauthorized", 1, true) or message:find("forbidden", 1, true) then
        return "auth"
    end
    if message:find("format", 1, true) or message:find("demux", 1, true)
        or message:find("recognize", 1, true) then
        return "format"
    end
    if attempt.file_loaded then
        return "network-after-load"
    end
    return "open-failed"
end

local function count_keys(input)
    local count = 0
    for _ in pairs(input or {}) do
        count = count + 1
    end
    return count
end

local function finish_exhausted(session, event, attempt)
    cancel_iptv_retry_timer()
    local error_class = classify_playback_error(event, attempt)
    local source_count = count_keys(session.attempted_sources)
    local mode_count = count_keys(session.attempted_modes)
    mp.msg.error(string.format(
        "[IPTV] 候选耗尽 session=%d class=%s sources=%d modes=%d last=%s",
        session.generation,
        error_class,
        source_count,
        mode_count,
        source_model.redact_url(attempt.source.url)
    ))
    mp.osd_message(string.format(
        "播放失败：已尝试 %d 条线路 / %d 种模式（%s）",
        source_count,
        mode_count,
        error_class
    ), 5)
    session.exhausted = true
end

local function find_next_different_source_candidate(session, attempt)
    for index = attempt.candidate_index + 1, #session.candidates do
        local candidate = session.candidates[index]
        local source_index = candidate.source.original_source_index or candidate.source_index
        if source_index ~= attempt.source_index then
            return index
        end
    end
    return nil
end

local function schedule_candidate(session, candidate_index, reconnect_count, reason)
    cancel_iptv_retry_timer()
    local delay = session.settings.retry_delay
    mp.msg.warn(string.format(
        "[IPTV] %s，%.1f 秒后尝试 candidate=%d/%d",
        reason,
        delay,
        candidate_index,
        #session.candidates
    ))
    state.playback_retry_timer = mp.add_timeout(delay, function()
        state.playback_retry_timer = nil
        if state.active_playback_session ~= session or session.exhausted then
            return
        end
        dispatch_session_candidate(session, candidate_index, reconnect_count, "replace", true)
    end)
end

function handle_iptv_end_file(event)
    local session = state.active_playback_session
    local attempt = state.active_attempt
    if not session or not attempt or not attempt.started then
        return false
    end

    local event_entry_id = event and tonumber(event.playlist_entry_id) or nil
    if attempt.playlist_entry_id and event_entry_id
        and attempt.playlist_entry_id ~= event_entry_id then
        return false
    end
    if not event or event.reason ~= "error" then
        return false
    end

    local error_class = classify_playback_error(event, attempt)
    mp.msg.warn(string.format(
        "[IPTV] 播放错误 session=%d class=%s source=%d mode=%s loaded=%s",
        session.generation,
        error_class,
        attempt.source_index,
        attempt.mode,
        tostring(attempt.file_loaded)
    ))

    if attempt.file_loaded then
        if attempt.reconnect_count < session.settings.retry_count then
            schedule_candidate(
                session,
                attempt.candidate_index,
                attempt.reconnect_count + 1,
                string.format("已加载线路中断，重连 %d/%d", attempt.reconnect_count + 1, session.settings.retry_count)
            )
            return true
        end

        local next_source_candidate = find_next_different_source_candidate(session, attempt)
        if next_source_candidate then
            schedule_candidate(session, next_source_candidate, 0, "当前线路重连耗尽，切换备用线路")
            return true
        end
        finish_exhausted(session, event, attempt)
        return true
    end

    local next_candidate = attempt.candidate_index + 1
    if next_candidate <= #session.candidates then
        schedule_candidate(session, next_candidate, 0, "打开失败，推进格式/线路候选")
        return true
    end

    if session.open_retry_round < session.settings.retry_count then
        session.open_retry_round = session.open_retry_round + 1
        schedule_candidate(
            session,
            1,
            0,
            string.format("全部候选打开失败，开始有限重试轮次 %d/%d", session.open_retry_round, session.settings.retry_count)
        )
        return true
    end

    finish_exhausted(session, event, attempt)
    return true
end

function get_channel_source(channel, source_index)
    if not channel then
        return nil
    end
    local sources = channel.sources or {}
    local index = tonumber(source_index) or 1
    return sources[index] or sources[1]
end

function find_channel_source_index_by_url(channel, url)
    if not channel or not url then
        return nil
    end

    local clean_url = source_model.split_url_headers(url)
    for source_index, source in ipairs(channel.sources or {}) do
        if source.url == clean_url then
            return source_index
        end
    end

    local best_index = nil
    local best_length = -1
    for source_index, source in ipairs(channel.sources or {}) do
        if url_matches(clean_url, source.url) and #source.url > best_length then
            best_index = source_index
            best_length = #source.url
        end
    end
    return best_index
end

function build_catchup_playback_sources(channel, start_utc, end_utc, requested_template, requested_url)
    local result = {}
    local live_sources = channel and channel.sources or {}

    if #live_sources == 0 and requested_url and requested_url ~= "" then
        local source = source_model.make_source(requested_url, {headers = {}, catchup = requested_template})
        source.original_source_index = 1
        return {source}
    end

    for source_index, live_source in ipairs(live_sources) do
        local template = live_source.catchup
        if not template or template == "" then
            template = requested_template
        end
        if template and template ~= "" then
            local playback_url
            if start_utc and end_utc then
                playback_url = replace_catchup_time_params(template, start_utc, end_utc)
            elseif requested_url and requested_url ~= "" then
                playback_url = requested_url
            end
            if playback_url and playback_url ~= "" then
                local source = source_model.make_source(playback_url, live_source)
                source.catchup = template
                source.id = source_model.source_identity_key(source)
                source.original_source_index = source_index
                result[#result + 1] = source
            end
        end
    end

    if #result == 0 and requested_url and requested_url ~= "" then
        local base_source = get_channel_source(channel, state.current_source_index)
        local source = source_model.make_source(requested_url, base_source or {headers = {}})
        source.catchup = requested_template
        source.id = source_model.source_identity_key(source)
        source.original_source_index = tonumber(state.current_source_index) or 1
        result[1] = source
    end
    return result
end

-- ==================== 直播播放 ====================

function play_live_channel(channel, show_osd, group_name, channel_index, preferred_source_index, context)
    if not channel or not channel.url or channel.url == "" then
        return false
    end

    -- 先验证并提交播放请求；DRM-only 等拒绝情况不能改写旧频道、回看或历史。
    local source_index = tonumber(preferred_source_index) or 1
    local loaded, session = load_iptv_channel(channel, context or "live-channel", source_index, {role = "live"})
    if not loaded then return false end

    set_current_catchup_state(nil, nil)

    if group_name and channel_index then
        set_selected_channel_position(group_name, channel_index)
    else
        local resolved_group_name, resolved_channel_index
        if channel.key then
            resolved_group_name, resolved_channel_index = find_channel_position_by_key(channel.key)
        end
        if not resolved_group_name then
            resolved_group_name, resolved_channel_index = find_channel_position_by_url(channel.url)
        end
        set_selected_channel_position(resolved_group_name, resolved_channel_index)
    end

    local current_identity = state.current_channel
        and (state.current_channel.key or state.current_channel.url) or nil
    local channel_identity = channel.key or channel.url
    local channel_changed = current_identity ~= channel_identity
    set_current_channel_state(channel)
    state.current_source_index = source_index

    if channel_changed then
        mp.msg.info("当前频道: " .. channel.name)
        if not state.auto_playing then
            save_current_channel_to_history()
        end
    end

    if show_osd then
        show_top_center_osd(channel.name, 2)
    end

    return true, session
end

-- ==================== 回看参考时间 ====================

function get_catchup_reference_utc()
    if not state.current_catchup or not state.current_catchup.start_utc then
        return nil
    end

    local start_ts = utc_str_to_timestamp(state.current_catchup.start_utc)
    if not start_ts then
        return nil
    end

    local time_pos = state.current_time_pos
    if not time_pos or time_pos < 0 then
        time_pos = 0
    end

    return to_utc_string(start_ts + math.floor(time_pos))
end

function get_menu_reference_utc_for_channel(ch, menu_active_channel, default_utc)
    if not ch or not menu_active_channel then
        return default_utc
    end

    if state.current_catchup and (menu_active_channel.key or menu_active_channel.url) == (ch.key or ch.url) then
        local catchup_utc = get_catchup_reference_utc()
        if catchup_utc then
            return catchup_utc
        end
    end

    return default_utc
end

-- ==================== 组内频道切换 ====================

function switch_channel_in_current_group(direction)
    if state.current_catchup then
        mp.osd_message("回看中不支持组内切台", 2)
        return
    end

    local current_group_name = state.selected_group_name
    local current_index = state.selected_channel_index

    if not current_group_name or not current_index then
        local current_channel = get_menu_active_channel()
        if not current_channel or not current_channel.group then
            return
        end
        if current_channel.key then
            current_group_name, current_index = find_channel_position_by_key(current_channel.key)
        end
        if not current_group_name then
            current_group_name, current_index = find_channel_position_by_url(current_channel.url)
        end
    end

    if not current_group_name or not current_index then
        return
    end

    local group_channels = state.groups[current_group_name]
    if not group_channels or #group_channels == 0 then
        return
    end

    local target_index = current_index + direction
    if target_index < 1 or target_index > #group_channels then
        return
    end

    local target_channel = group_channels[target_index]
    if not target_channel or not target_channel.url or target_channel.url == "" then
        return
    end

    play_live_channel(target_channel, true, current_group_name, target_index)
end

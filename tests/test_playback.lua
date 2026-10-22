return function()
    local source = require 'source'

    local sources = {
        source.make_source("https://one.test/live.php?id=1", {headers = {Referer = "https://ref/"}}),
        source.make_source("https://two.test/live", {headers = {}}),
        source.make_source("https://drm.test/live.mpd", {
            headers = {},
            drm = {type = "com.widevine.alpha", license_key = "secret"},
        }),
    }
    local candidates, skipped = source.build_candidates(sources, 1, {
        format_fallback = true,
        source_fallback = true,
        format_cache = {},
    })
    assert(#candidates == 6)
    assert(candidates[1].source_index == 1 and candidates[1].mode == "auto")
    assert(candidates[2].source_index == 1 and candidates[2].mode == "hls")
    assert(candidates[3].source_index == 1 and candidates[3].mode == "mpegts")
    assert(candidates[4].source_index == 2 and candidates[4].mode == "auto")
    assert(#skipped == 1 and skipped[1] == 3)

    local preferred = source.build_candidates(sources, 2, {
        format_fallback = false,
        source_fallback = false,
        format_cache = {},
    })
    assert(#preferred == 1)
    assert(preferred[1].source_index == 2)

    local cache_key = source.source_cache_key(sources[1])
    local cached = source.build_candidates({sources[1]}, 1, {
        format_fallback = true,
        source_fallback = true,
        format_cache = {[cache_key] = "hls"},
    })
    assert(cached[1].mode == "hls")
    assert(cached[2].mode == "auto")
    assert(cached[3].mode == "mpegts")

    local dash_source = source.make_source("https://dash.test/manifest.mpd", {headers = {}})
    local dash = source.build_candidates({dash_source}, 1, {
        format_fallback = true,
        source_fallback = true,
        format_cache = {},
    })
    assert(#dash == 2)
    assert(dash[1].mode == "dash" and dash[2].mode == "auto")

    local commands = {}
    local timers = {}
    local properties = {}
    local osd_messages = {}
    package.loaded.mp = {
        command_native = function(command)
            commands[#commands + 1] = command
        end,
        commandv = function() end,
        get_property = function(name)
            return properties[name]
        end,
        get_property_number = function(name)
            return tonumber(properties[name])
        end,
        add_timeout = function(_, callback)
            local timer = {callback = callback, killed = false}
            function timer:kill() self.killed = true end
            timers[#timers + 1] = timer
            return timer
        end,
        osd_message = function(message)
            osd_messages[#osd_messages + 1] = message
        end,
        msg = {
            info = function() end,
            warn = function() end,
            error = function() end,
        },
    }

    options = {
        iptv_default_user_agent = "fallback",
        iptv_network_timeout = 8,
        iptv_retry_count = 2,
        iptv_retry_delay = 0.1,
        iptv_format_fallback = true,
        iptv_source_fallback = true,
    }
    state = {
        format_cache = {},
        queued_playback_sessions = {},
        playback_generation = 0,
    }
    function url_matches(path, target)
        if path == target then return true end
        if not path or not target or target == "" then return false end
        local target_len = #target
        if path:sub(1, target_len) == target then
            local next_char = path:sub(target_len + 1, target_len + 1)
            local target_has_query = target:find("?", 1, true) ~= nil
            return (target_has_query and next_char:match("[&#]")) ~= nil
                or (not target_has_query and next_char:match("[?#]")) ~= nil
        end
        return false
    end
    function clear_queued_catchup_state() end
    function remember_iptv_source_format(_, format)
        state.remembered_format = format
        return true
    end
    function save_iptv_format_cache()
        state.format_cache_saved = true
    end
    function save_current_channel_to_history() end

    package.loaded.playback = nil
    assert(loadfile("scripts/epg/playback.lua"))()

    local match_channel = {
        sources = {
            {url = "https://same.test/live"},
            {url = "https://same.test/live?channel=two"},
        },
    }
    assert(find_channel_source_index_by_url(
        match_channel,
        "https://same.test/live?channel=two&token=short"
    ) == 2)

    local runtime_source = source.make_source("https://runtime.test/live.php?id=1", {
        headers = {Referer = "https://ref/", Cookie = "sid=secret"},
    })
    local loaded = load_iptv_sources({runtime_source}, "unit-runtime", {role = "generic"})
    assert(loaded)
    assert(#commands == 1)
    assert(commands[1][1] == "loadfile")
    assert(commands[1][2] == "https://runtime.test/live.php?id=1")
    assert(commands[1][5].referrer == "https://ref/")
    assert(commands[1][5]["http-header-fields"]:find("Cookie: sid=secret", 1, true))
    assert(commands[1][5]["demuxer-lavf-format"] == nil)

    properties.path = runtime_source.url
    properties["playlist-entry-id"] = 10
    local started = handle_iptv_start_file()
    assert(started and state.active_attempt.started)
    assert(handle_iptv_end_file({reason = "error", playlist_entry_id = 10, error = "loading failed"}))
    assert(#timers == 1)
    timers[#timers].callback()
    assert(#commands == 2)
    assert(commands[2][5]["demuxer-lavf-format"] == "hls")
    assert(commands[2][5].referrer == "https://ref/")

    properties["playlist-entry-id"] = 11
    assert(handle_iptv_start_file())
    properties["file-format"] = "hls"
    properties["stream-open-filename"] = "https://cdn.test/live.m3u8?token=short-lived"
    assert(handle_iptv_file_loaded())
    assert(state.remembered_format == "hls")
    assert(state.format_cache_saved)
    assert(not handle_iptv_end_file({reason = "error", playlist_entry_id = 10, error = "old entry"}))

    assert(handle_iptv_end_file({reason = "error", playlist_entry_id = 11, error = "timeout"}))
    timers[#timers].callback()
    assert(#commands == 3)
    assert(commands[3][5]["demuxer-lavf-format"] == "hls")
    assert(state.active_attempt.reconnect_count == 1)

    properties["playlist-entry-id"] = 12
    assert(handle_iptv_start_file())
    assert(handle_iptv_file_loaded())
    local queued_source = source.make_source("https://runtime.test/next.php?id=2", {
        headers = {Referer = "https://next-ref/", Origin = "https://next-origin/"},
    })
    local queued_ok, queued_session = load_iptv_sources({queued_source}, "queue-test", {
        role = "catchup",
        load_mode = "insert-next",
    })
    assert(queued_ok and queued_session.queued)
    assert(#commands == 4 and commands[4][3] == "insert-next")
    assert(commands[4][5].referrer == "https://next-ref/")
    assert(state.active_playback_session ~= queued_session)

    properties.path = queued_source.url
    properties["playlist-entry-id"] = 20
    local queue_started, claimed_session, was_queued = handle_iptv_start_file()
    assert(queue_started and was_queued and claimed_session == queued_session)
    assert(state.active_playback_session == queued_session)
    assert(#state.queued_playback_sessions == 0)

    -- 打开补试轮次与已加载后的断线重连计数必须相互独立。
    local retry_source = source.make_source("https://retry.test/live.m3u8", {headers = {}})
    assert(load_iptv_sources({retry_source}, "retry-counter-test", {role = "generic"}))
    properties.path = retry_source.url
    properties["playlist-entry-id"] = 30
    assert(handle_iptv_start_file())
    assert(handle_iptv_end_file({reason = "error", playlist_entry_id = 30, error = "open failed"}))
    timers[#timers].callback() -- 第二个格式候选

    properties["playlist-entry-id"] = 31
    assert(handle_iptv_start_file())
    assert(handle_iptv_end_file({reason = "error", playlist_entry_id = 31, error = "open failed"}))
    timers[#timers].callback() -- 第一个打开补试轮次

    properties["playlist-entry-id"] = 32
    assert(handle_iptv_start_file())
    properties["file-format"] = "hls"
    assert(handle_iptv_file_loaded())
    assert(state.active_attempt.open_retry_round == 1)
    assert(state.active_attempt.reconnect_count == 0)
    assert(handle_iptv_end_file({reason = "error", playlist_entry_id = 32, error = "timeout"}))
    timers[#timers].callback()
    assert(state.active_attempt.reconnect_count == 1)

    local drm_only = source.make_source("https://runtime.test/drm.mpd", {
        headers = {},
        drm = {type = "com.widevine.alpha", license_key = "secret"},
    })
    assert(not load_iptv_sources({drm_only}, "drm-test", {role = "generic"}))
    assert(#osd_messages > 0)

    -- 拒绝 DRM 切台时，旧会话、回看队列、频道位置及历史必须一起保留。
    local old_channel = {name = "Playing", url = runtime_source.url, key = "playing"}
    local old_catchup = {channel = old_channel}
    local old_session = state.active_playback_session
    local old_attempt = state.active_attempt
    local old_retry_timer = state.playback_retry_timer
    local old_queue = {queued_session}
    local history_channel = old_channel
    state.current_channel = old_channel
    state.current_catchup = old_catchup
    state.queued_playback_sessions = old_queue
    state.current_source_index = 2
    state.selected_group_name, state.selected_channel_index = "TV", 1
    function set_current_catchup_state(value) state.current_catchup = value end
    function set_current_channel_state(value) state.current_channel = value end
    function set_selected_channel_position(group, index)
        state.selected_group_name, state.selected_channel_index = group, index
    end
    function save_current_channel_to_history() history_channel = state.current_channel end
    assert(not play_live_channel({
        name = "DRM", url = drm_only.url, key = "drm", sources = {drm_only},
    }, false, "TV", 2))
    assert(state.current_channel == old_channel and history_channel == old_channel)
    assert(state.current_catchup == old_catchup)
    assert(state.selected_group_name == "TV" and state.selected_channel_index == 1)
    assert(state.current_source_index == 2)
    assert(state.active_playback_session == old_session and state.active_attempt == old_attempt)
    assert(state.playback_retry_timer == old_retry_timer)
    assert(state.queued_playback_sessions == old_queue)
end

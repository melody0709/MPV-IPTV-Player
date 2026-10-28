return function()
    local messages, observers, commands, events, timers, properties = {}, {}, {}, {}, {}, {}
    local function noop() end
    package.loaded.mp = {
        msg = {info = noop, warn = noop, error = noop, verbose = noop},
        command_native = function(command)
            if command[1] == "expand-path" then
                return "__epg_test_missing__/" .. command[2]:gsub("[~:]", "")
            end
            commands[#commands + 1] = command
        end,
        commandv = noop,
        get_property = function(name, default) return properties[name] or default end,
        get_property_number = function(name) return tonumber(properties[name]) end,
        set_property_native = noop,
        register_script_message = function(name, callback) messages[name] = callback end,
        register_event = function(name, callback)
            events[name] = events[name] or {}
            events[name][#events[name] + 1] = callback
        end,
        observe_property = function(name, _, callback) observers[name] = callback end,
        add_key_binding = noop,
        add_hook = noop,
        add_timeout = function(_, callback)
            local timer = {callback = callback, kill = noop}
            timers[#timers + 1] = timer
            return timer
        end,
        osd_message = noop,
    }
    package.loaded["mp.utils"] = {
        join_path = function(left, right) return left .. "/" .. right end,
        format_json = function() return "{}" end,
    }
    package.loaded["mp.options"] = {read_options = noop}
    for _, name in ipairs({"utils", "data", "playback", "menu"}) do
        package.loaded[name] = nil
    end
    assert(loadfile("scripts/epg/main.lua"))()

    local playlist = [[
#EXTM3U
#EXTINF:-1 tvg-id="a" group-title="TV" catchup-source="https://catch.test/a?start=${utc:yyyyMMddHHmmss}",A
#EXTVLCOPT:http-user-agent=UA-A
https://stream.test/live
#EXTINF:-1 tvg-id="b" group-title="TV" catchup-source="https://catch.test/b?start=${utc:yyyyMMddHHmmss}",B
#EXTVLCOPT:http-user-agent=UA-B
https://stream.test/live
#EXTINF:-1 tvg-id="drm" group-title="TV" catchup-source="https://catch.test/drm?start=${utc:yyyyMMddHHmmss}",DRM
#KODIPROP:inputstream.adaptive.license_type=com.widevine.alpha
https://stream.test/drm.mpd
]]
    assert(parse_m3u("test.m3u", {
        content = playlist,
        history_autoplay = false,
        skip_epg_refresh = true,
    }))
    local a, b, drm = state.groups.TV[1], state.groups.TV[2], state.groups.TV[3]
    local function program(title)
        return {
            title = title, start_utc = "20200101010000", end_utc = "20200101020000",
            display_start = "01:00", display_end = "02:00",
        }
    end
    state.epg_data = {a = {program("Program A")}, b = {program("Program B")}}
    function get_channel_bucket_data(channel)
        local programs = state.epg_data[channel.tvg_id]
        return {
            today = {label = "Today", subtitle = "", programs = programs},
            yesterday = {label = "Yesterday", subtitle = "", programs = programs},
        }
    end
    local function invoke(command)
        assert(command[1] == "script-message-to" and command[2] == "epg")
        messages[command[3]](table.unpack(command, 4))
    end

    messages["play-live-channel"](b.url, "no", "TV", "2")
    assert(state.current_channel == b and state.active_attempt.source.headers["User-Agent"] == "UA-B")
    local menu = build_main_menu()
    local b_item = find_menu_group_item(menu, "TV").items[2]
    invoke(b_item.items[1].items[1].value)
    assert(state.current_channel == b, "date-menu catchup must retain B's identity")
    assert(state.active_attempt.source.headers["User-Agent"] == "UA-B")
    assert(state.active_attempt.source.url == "https://catch.test/b?start=20200101010000")
    assert(get_menu_active_channel() == b)

    -- 延迟展开昨天节目时，同 URL 的 A 不能替换 B 的节目或请求上下文。
    menu = build_main_menu()
    state.last_iptv_menu_data = menu
    b_item = find_menu_group_item(menu, "TV").items[2]
    invoke(b_item.items[2].value)
    b_item = find_menu_group_item(state.last_iptv_menu_data, "TV").items[2]
    assert(b_item.items[2].items, "lazy date bucket must expand B")
    assert(b_item.items[2].items[1].title == "Program B")
    invoke(b_item.items[2].items[1].value)
    assert(state.current_channel == b and state.active_attempt.source.headers["User-Agent"] == "UA-B")

    -- 菜单缓存丢失后重建，同样必须按 key 展开 B。
    local lazy_command = find_menu_group_item(build_main_menu(), "TV").items[2].items[2].value
    state.last_iptv_menu_data = nil
    invoke(lazy_command)
    b_item = find_menu_group_item(state.last_iptv_menu_data, "TV").items[2]
    assert(b_item.items[2].items[1].title == "Program B")
    invoke(b_item.items[2].items[1].value)
    assert(state.current_channel == b and state.active_attempt.source.headers["User-Agent"] == "UA-B")

    -- 跨频道节目搜索必须能从 B 切换到同 URL 的 A，不能依赖当前频道猜测。
    local found_a = false
    for _, item in ipairs(build_catchup_epg_menu().items) do
        if item.title:match("^A |") then
            found_a = true
            invoke(item.value)
            assert(state.current_channel == a)
            assert(state.active_attempt.source.headers["User-Agent"] == "UA-A")
        end
    end
    assert(found_a, "catchup search must include A")
    -- 旧消息没有 key 时仍可使用 URL；带失效 key 的消息不能退回其他频道。
    messages["play-catchup"]("", a.catchup, "20200101010000", "20200101020000", a.url)
    assert(state.current_channel == a)
    local attempt, command_count = state.active_attempt, #commands
    messages["play-catchup"]("", b.catchup, "20200101010000", "20200101020000", b.url, "missing")
    assert(state.active_attempt == attempt and #commands == command_count)

    -- 从真实消息入口拒绝 DRM 时，保留原直播/回看状态与历史。
    local old_channel, old_catchup = state.current_channel, state.current_catchup
    local old_catchup_path = state.current_catchup_path
    local old_history = state.channel_history[get_m3u_key(state.m3u_path)]
    local old_group, old_index = state.selected_group_name, state.selected_channel_index
    local old_session = state.active_playback_session
    for _, command in ipairs({
        {"script-message-to", "epg", "play-live-channel", drm.url, "no", "TV", "3"},
        {"script-message-to", "epg", "play-catchup", "", drm.catchup,
            "20200101010000", "20200101020000", drm.url, drm.key},
    }) do
        invoke(command)
        assert(state.current_channel == old_channel, "DRM rejection must retain the playing channel")
        assert(state.current_catchup == old_catchup and state.current_catchup_path == old_catchup_path)
        assert(state.selected_group_name == old_group and state.selected_channel_index == old_index)
        assert(state.channel_history[get_m3u_key(state.m3u_path)] == old_history)
        assert(state.active_playback_session == old_session and state.active_attempt == attempt)
        assert(#commands == command_count)
    end

    -- 历史恢复不能绕过播放入口，提前把失败的 DRM 频道写进界面。
    state.channel_history[get_m3u_key(state.m3u_path)] = {url = drm.url, channel_key = drm.key}
    assert(parse_m3u("test.m3u", {content = playlist, skip_epg_refresh = true}))
    assert(state.current_channel == nil, "rejected history restore must not select a DRM channel")
    assert(state.selected_group_name == nil and state.selected_channel_index == nil)
    assert(state.active_playback_session == old_session and #commands == command_count)

    local function parse_refresh(content, preserve_current_channel)
        assert(parse_m3u("test.m3u", {
            content = content,
            preserve_current_channel = preserve_current_channel,
            history_autoplay = false,
            skip_epg_refresh = true,
        }))
    end
    state.auto_playing = false

    -- 刷新移除 B 后，共用 URL 的 A 不能接管 B 的界面、菜单和播放上下文。
    parse_refresh(playlist, false)
    local playing_b = state.groups.TV[2]
    assert(play_live_channel(playing_b, false, "TV", 2))
    local playing_b_session = state.active_playback_session
    local playing_b_history = state.channel_history[get_m3u_key(state.m3u_path)]
    local only_a = [[
#EXTM3U
#EXTINF:-1 tvg-id="a" group-title="TV",A
#EXTVLCOPT:http-user-agent=UA-A
https://stream.test/live
]]
    parse_refresh(only_a, true)
    state.active_attempt.started, state.active_attempt.file_loaded = true, true
    assert(handle_iptv_end_file({reason = "error", error = "timeout"}))
    state.playback_retry_timer.callback()
    observers.path("path", state.active_attempt.source.url)
    assert(state.current_channel == playing_b, "removed channel key must not fall back to another channel's URL")
    assert(get_menu_active_channel() == playing_b)
    assert(state.selected_group_name == nil and state.selected_channel_index == nil)
    assert(state.active_playback_session == playing_b_session)
    assert(state.active_attempt.source.headers["User-Agent"] == "UA-B")
    assert(state.channel_history[get_m3u_key(state.m3u_path)] == playing_b_history)

    -- 没有 key 的旧频道仍可按 URL 兼容匹配。
    state.current_channel = {name = "Legacy", url = playing_b.url}
    parse_refresh(only_a, true)
    assert(state.current_channel == state.groups.TV[1])
    assert(state.selected_group_name == "TV" and state.selected_channel_index == 1)

    -- 同 URL、不同 Header 的线路重排后，重连和历史必须按完整 source 身份定位。
    local line_x = [[
#EXTINF:-1 tvg-id="same" group-title="TV" catchup-source="https://catch.test/x?start=${utc:yyyyMMddHHmmss}",Same
#EXTVLCOPT:http-user-agent=UA-X
https://lines.test/live.php
]]
    local line_y = [[
#EXTINF:-1 tvg-id="same" group-title="TV" catchup-source="https://catch.test/y?start=${utc:yyyyMMddHHmmss}",Same
#EXTVLCOPT:http-user-agent=UA-Y
https://lines.test/live.php
]]
    parse_refresh("#EXTM3U\n" .. line_x .. line_y, false)
    assert(play_live_channel(state.groups.TV[1], false, "TV", 1))
    state.active_attempt.started, state.active_attempt.file_loaded = true, true
    local source_x_id = state.active_attempt.source.id
    parse_refresh("#EXTM3U\n" .. line_y .. line_x, true)
    assert(state.current_source_index == 2)
    local function reconnect()
        assert(handle_iptv_end_file({reason = "error", error = "timeout"}))
        state.playback_retry_timer.callback()
        state.active_attempt.started = true
        assert(handle_iptv_file_loaded())
        observers.path("path", state.active_attempt.source.url)
    end
    reconnect()
    local history = state.channel_history[get_m3u_key(state.m3u_path)]
    assert(state.active_attempt.source.id == source_x_id)
    assert(state.current_source_index == 2, "reconnect must resolve X's index in the refreshed channel")
    assert(history.source_index == 2 and history.source_id == source_x_id)
    assert(commands[#commands][5]["user-agent"] == "UA-X")
    local refreshed_channel = state.current_channel
    messages["play-catchup"]("", refreshed_channel.catchup,
        "20200101010000", "20200101020000", refreshed_channel.url, refreshed_channel.key)
    assert(state.active_attempt.source.headers["User-Agent"] == "UA-X")
    assert(state.active_attempt.source.url == "https://catch.test/x?start=20200101010000")

    -- X 已被刷新移除时，不能把新序号 1 的 Y 记成刚重连成功的线路。
    assert(play_live_channel(refreshed_channel, false, "TV", 1, 2))
    state.active_attempt.started, state.active_attempt.file_loaded = true, true
    local history_before_removal = state.channel_history[get_m3u_key(state.m3u_path)]
    parse_refresh("#EXTM3U\n" .. line_y, true)
    reconnect()
    assert(state.active_attempt.source.id == source_x_id)
    assert(state.current_source_index == nil, "removed source must not reuse its old positional index")
    assert(state.channel_history[get_m3u_key(state.m3u_path)] == history_before_removal)

    -- append 的备用线路、路径保护、预加载和 EOF 续播必须共用实际 source。
    local append_playlist = [[
#EXTM3U catchup="append" catchup-source="?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}"
#EXTINF:-1 tvg-id="append" group-title="TV",Append
#EXTVLCOPT:http-user-agent=UA-1
https://append.test/live?channel=one&token=first
#EXTINF:-1 tvg-id="append" group-title="TV",Append
#EXTVLCOPT:http-user-agent=UA-2
https://append.test/live?channel=two&token=second
]]
    parse_refresh(append_playlist, false)
    options.catchup_local_timezone_override = "+08:00"
    local append_channel = state.groups.TV[1]
    assert(play_live_channel(append_channel, false, "TV", 1, 2))
    messages["play-catchup"]("", append_channel.catchup, "20200101010000", "20200101020000",
        append_channel.url, append_channel.key)
    local prefix = "https://append.test/live?channel=two&token=second&playseek="
    assert(state.active_attempt.source.url == prefix .. "20200101090000-20200101100000")
    assert(state.current_catchup_path == state.active_attempt.source.url)
    assert(state.current_catchup.source_index == 2)
    observers.path("path", state.current_catchup_path)
    assert(state.current_catchup and state.current_channel == append_channel)

    properties.duration = 3600
    observers.duration("duration", 3600)
    observers["time-pos"]("time-pos", 3590)
    timers[#timers].callback()
    assert(state.queued_catchup_path == prefix .. "20200101100000-20200101150000")
    assert(state.queued_catchup.source.headers["User-Agent"] == "UA-2")
    assert(commands[#commands][3] == "insert-next")

    clear_queued_catchup_state()
    for _, callback in ipairs(events["end-file"]) do callback({reason = "eof"}) end
    assert(state.current_catchup_path == prefix .. "20200101100000-20200101150000")
    assert(state.current_catchup.start_utc == "20200101020000")
    assert(state.current_catchup.source.headers["User-Agent"] == "UA-2")

    local old_attempt, old_context, old_commands = state.active_attempt, state.current_catchup, #commands
    messages["play-catchup"]("", "?playseek=${unsupported}", "20200101010000", "20200101020000",
        "https://unknown.test/live")
    assert(state.active_attempt == old_attempt and state.current_catchup == old_context and #commands == old_commands)

    -- 日期菜单与 F9 按各线路的窗口取可用并集。
    append_channel.sources[1].catchup_days = 1
    append_channel.sources[2].catchup_days = 7
    local now = os.time()
    local recent, expired = program("Recent"), program("Expired")
    recent.start_utc, recent.end_utc = to_utc_string(now - 2 * 86400), to_utc_string(now - 2 * 86400 + 3600)
    expired.start_utc, expired.end_utc = to_utc_string(now - 8 * 86400), to_utc_string(now - 8 * 86400 + 3600)
    state.epg_data = {append = {recent, expired}}
    local items = build_channel_epg_items(append_channel)
    assert(not items[1].muted and items[2].muted)
    local search = build_catchup_epg_menu()
    assert(#search.items == 1 and search.items[1].title:find("Recent", 1, true))
    assert(play_live_channel(append_channel, false, "TV", 1, 1))
    invoke(items[1].value)
    assert(state.current_catchup.source_index == 2, "expired first source must retain the backup's original index")
    assert(state.active_attempt.source.headers["User-Agent"] == "UA-2")

    -- 新增回看元数据后的历史恢复仍识别旧 source.id，不依赖已过时的序号。
    state.channel_history[get_m3u_key(state.m3u_path)] = {
        url = append_channel.url, channel_key = append_channel.key, source_index = 1,
        source_id = require('source').source_identity_key(append_channel.sources[2], true),
    }
    assert(parse_m3u("test.m3u", {content = append_playlist, skip_epg_refresh = true}))
    assert(state.current_source_index == 2 and state.active_attempt.source.headers["User-Agent"] == "UA-2")
end

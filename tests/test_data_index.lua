return function()
    package.loaded.mp = {msg = {info = function() end, warn = function() end, error = function() end}}
    package.loaded["mp.utils"] = {
        join_path = function(left, right) return left .. "/" .. right end,
    }

    assert(loadfile("scripts/epg/data.lua"))()

    local base_channel = {
        key = "base",
        url = "https://same.test/live",
        sources = {{url = "https://same.test/live"}},
    }
    local query_channel = {
        key = "query",
        url = "https://same.test/live?channel=two",
        sources = {{url = "https://same.test/live?channel=two"}},
    }
    local base_entry = {group_name = "TV", channel_index = 1, channel = base_channel}
    local query_entry = {group_name = "TV", channel_index = 2, channel = query_channel}
    state = {
        group_names = {"TV"},
        groups = {TV = {base_channel, query_channel}},
        url_to_channel_map = {
            [base_channel.url] = base_entry,
            [query_channel.url] = query_entry,
        },
        -- 这个 base 同时存在带 query source，因此不能启用快速前缀映射。
        url_prefix_channel_map = {},
        url_prefix_ambiguous = {[base_channel.url] = true},
    }

    assert(find_channel_map_entry_by_url(query_channel.url).channel == query_channel)
    assert(find_channel_map_entry_by_url(query_channel.url .. "&token=short").channel == query_channel)
    assert(find_channel_map_entry_by_url(base_channel.url .. "?unrelated=1").channel == base_channel)
    assert(find_channel_position_by_url(query_channel.url .. "&token=short") == "TV")

    state.current_catchup = {start_utc = "20260712010000"}
    state.current_catchup_path = base_channel.url .. "?start=20260712010000"
    assert(path_matches_active_catchup(state.current_catchup_path))
    assert(path_matches_active_catchup(state.current_catchup_path .. "&token=short"))
    state.current_catchup = nil
    state.current_catchup_path = nil
    state.active_attempt = {
        role = "catchup",
        source = {url = base_channel.url .. "?start=20260712020000"},
    }
    assert(path_matches_active_catchup(base_channel.url .. "?start=20260712020000"))

    local hls_playlist, hls_reason = validate_iptv_m3u_content([[
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXTINF:6,
segment.ts
]])
    assert(hls_playlist == nil and hls_reason == "hls-playlist")

    -- 无效的远程响应必须在写缓存前被拒绝，并保留 last-known-good。
    trim = function(value)
        return tostring(value or ""):match("^%s*(.-)%s*$")
    end
    options = {m3u_download_url = "https://subscription.test/tv.m3u"}
    local temp_path = (os.getenv("TEMP") or ".") .. "\\mpv_epg_subscription_test_"
        .. tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999)) .. ".m3u"
    local original = "#EXTM3U\n#EXTINF:-1,Old\nhttps://old.test/live\n"
    local file = assert(io.open(temp_path, "wb"))
    assert(file:write(original))
    file:close()

    get_subscription_m3u_cache_path = function() return temp_path end
    state = {
        subscription_refresh_in_progress = false,
        subscription_last_hash = nil,
        active_source_kind = "subscription",
        is_loaded = false,
        m3u_source_key = "",
    }
    download_url_async = function(_, _, callback)
        callback(true, "<html>login required</html>")
        return true
    end
    local invalid_success, invalid_result
    assert(refresh_subscription_m3u_async(false, function(success, result)
        invalid_success, invalid_result = success, result
    end))
    assert(invalid_success == false and invalid_result.reason == "parse-failed")
    local unchanged = assert(io.open(temp_path, "rb"))
    assert(unchanged:read("*a") == original)
    unchanged:close()

    local replacement = "#EXTM3U\n#EXTINF:-1,New\nhttps://new.test/live\n"
    state.active_source_kind = "local" -- 验证后缓存，但不切换当前本地播放状态
    download_url_async = function(_, _, callback)
        callback(true, replacement)
        return true
    end
    local valid_success, valid_result
    assert(refresh_subscription_m3u_async(false, function(success, result)
        valid_success, valid_result = success, result
    end))
    assert(valid_success == true and valid_result.applied == false)
    local replaced = assert(io.open(temp_path, "rb"))
    assert(replaced:read("*a") == replacement)
    replaced:close()
    os.remove(temp_path)
    os.remove(temp_path .. ".bak")
end

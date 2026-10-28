return function()
    local source = require 'source'
    local parser = require 'm3u'
    local notices = {}
    local function noop() end
    package.loaded.mp = {
        msg = {info = noop, warn = noop},
        osd_message = function(message) notices[#notices + 1] = message end,
    }
    package.loaded["mp.utils"] = {}
    utc_timestamp_cache, xmltv_utc_cache = {}, {}
    assert(loadfile("scripts/epg/utils.lua"))()
    assert(loadfile("scripts/epg/playback.lua"))()
    options = {catchup_local_timezone_override = "+08:00"}

    assert(utc_str_to_timestamp("19700101000000") == 0)
    assert(utc_str_to_timestamp("20261021120000") == 1792584000)
    for timestamp = 0, 4102444800, 17 * 86400 + 1234 do
        assert(utc_str_to_timestamp(os.date("!%Y%m%d%H%M%S", timestamp)) == timestamp)
    end
    for _, date in ipairs({"20260121120000", "20261021120000", "20260308023000", "20261101013000", "20000229000000"}) do
        assert(os.date("!%Y%m%d%H%M%S", utc_str_to_timestamp(date)) == date, "UTC roundtrip: " .. date)
    end
    for _, date in ipairs({"", "bad", "20260229000000", "21000229000000", "20260101240000", "20261301000000"}) do
        assert(utc_str_to_timestamp(date) == nil)
    end
    assert(utc_str_to_timestamp(nil) == nil)
    assert(xmltv_to_utc("20261021200000 +0800") == "20261021120000")
    assert(xmltv_to_utc("20260121200000 +0800") == "20260121120000")
    assert(xmltv_to_utc("20261021230000 -0330") == "20261022023000")
    assert(xmltv_to_utc("20260229200000 +0800") == "")
    assert(xmltv_to_utc(nil) == "")

    local start, finish = "20261021120000", "20261021130000"
    local start_ts, end_ts = 1792584000, 1792587600
    local template = "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}"
    assert(replace_catchup_time_params(template, start, finish, "+08:00")
        == "?playseek=20261021200000-20261021210000")
    assert(replace_catchup_time_params("${(b)yyyy-MM-dd/HH:mm:ss|GMT+8}", start, finish)
        == "2026-10-21/20:00:00")
    assert(replace_catchup_time_params("${(b)yyyyMMddHHmmss|-03:30}", start, finish) == "20261021083000")
    assert(replace_catchup_time_params("${(b)yyyyMMddHHmmss|+0545}", start, finish) == "20261021174500")
    assert(replace_catchup_time_params("${(b)yyyyMMddHHmmss}", start, finish) == os.date("%Y%m%d%H%M%S", start_ts))
    assert(replace_catchup_time_params("${(b)yyyyMMddHHmmss|Local}", start, finish, "+08:00")
        == os.date("%Y%m%d%H%M%S", start_ts))
    for _, utc_template in ipairs({
        "${utc:yyyyMMddHHmmss}-${utcend:yyyyMMddHHmmss}",
        "${(b)yyyyMMddHHmmss|UTC}-${(e)yyyyMMddHHmmss|UTC}",
        "${(b)yyyyMMddHHmmss:utc}-${(e)yyyyMMddHHmmss:utc}",
        "{utc:YmdHMS}-{utcend:YmdHMS}",
    }) do
        assert(replace_catchup_time_params(utc_template, start, finish, "+08:00")
            == "20261021120000-20261021130000", "UTC compatibility: " .. utc_template)
    end
    assert(replace_catchup_time_params("${(b)timestamp}-${(e)timestamp}", start, finish)
        == "1792584000-1792587600")
    assert(replace_catchup_time_params("{utc}-{utcend}-{lutc}-{duration}", start, finish, nil, end_ts + 10)
        == "1792584000-1792587600-1792587610-3600")
    assert(replace_catchup_time_params("${start}-${end}-${now}-${duration}", start, finish, nil, end_ts + 10)
        == "1792584000-1792587600-1792587610-3600")
    for _, invalid in ipairs({"${unknown}", "${(b)bad}", "${(b)yyyyMMddHHmmss|Asia/Shanghai}", "${(b)yyyyMMddHHmmss|+15:00}"}) do
        local url, reason = replace_catchup_time_params(invalid, start, finish)
        assert(url == nil and reason)
    end
    assert(replace_catchup_time_params(template, start, start) == nil)

    local expected = "playseek=20261021200000-20261021210000"
    local live = "https://live.test/play.php?channel=two&token=a%2Fb#part"
    assert(build_catchup_url(live, template, "append", start, finish, "GMT+8")
        == "https://live.test/play.php?channel=two&token=a%2Fb&" .. expected .. "#part")
    assert(build_catchup_url("https://live.test/play", template, nil, start, finish, "+08:00")
        == "https://live.test/play?" .. expected)
    assert(build_catchup_url("https://live.test/play?", "&" .. template:sub(2), "append", start, finish, "+08:00")
        == "https://live.test/play?" .. expected)
    assert(build_catchup_url("https://live.test/play", "{url}" .. template, "default", start, finish, "+08:00")
        == "https://live.test/play?" .. expected)
    assert(build_catchup_url("https://live.test/play", "/{utc}", "append", start, finish)
        == "https://live.test/play/1792584000")
    assert(build_catchup_url(live, "https://catch.test/{utc}", "append", start, finish) == nil)
    assert(catchup_time_in_window(start, 7, start_ts + 7 * 86400))
    assert(not catchup_time_in_window(start, 7, start_ts + 7 * 86400 + 1))

    local parsed = parser.parse([[
#EXTM3U catchup="append" catchup-days="7" catchup-source="?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}"
#EXTINF:-1 tvg-id="a" group-title="TV",A
https://live.test/a
#EXTINF:-1 tvg-id="a" group-title="TV" catchup="default" catchup-days="2" catchup-source="https://catch.test/{utc}-{duration}",A
https://live.test/a
#EXTINF:-1 tvg-id="b" group-title="TV" catchup="none" catchup-days="-2",B
https://live.test/b
]])
    local a, b = parsed.groups.TV[1], parsed.groups.TV[2]
    assert(#a.sources == 2 and a.catchup_type == "append" and a.catchup_days == 7)
    assert(a.sources[2].catchup_type == "default" and a.sources[2].catchup_days == 2)
    assert(b.sources[1].catchup_days == 7, "invalid override must retain the playlist catchup window")
    assert(channel_has_catchup(a, start, start_ts + 3 * 86400))
    assert(not channel_has_catchup(a, start, start_ts + 8 * 86400))
    assert(not channel_has_catchup(b, start, start_ts))
    local legacy = source.make_source("https://live.test/a", {catchup = "https://catch.test/{utc}"})
    local explicit = source.make_source(legacy.url, {catchup = legacy.catchup, catchup_type = "default"})
    assert(legacy.id == explicit.id, "default complete URL must retain the old source identity")
    local relative = source.make_source(legacy.url, {catchup = template})
    local append = source.make_source(legacy.url, {catchup = template, catchup_type = "append"})
    local default = source.make_source(legacy.url, {catchup = template, catchup_type = "default"})
    assert(relative.id == append.id and append.id ~= default.id)

    local first = source.make_source("https://live.test/a?channel=one", {catchup = template, catchup_type = "append", headers = {Cookie = "sid=one"}})
    local second = source.make_source("https://live.test/b?channel=two", {catchup = template, catchup_type = "append", headers = {Cookie = "sid=two"}})
    local sources = build_catchup_playback_sources({sources = {first, second}}, start, finish, template)
    assert(#sources == 2 and sources[2].original_source_index == 2)
    assert(sources[2].url == second.url .. "&" .. expected)
    assert(sources[2].headers.Cookie == "sid=two" and sources[2].live_url == second.url)
    local resumed = build_catchup_playback_sources(nil, start, finish, template, nil, sources[2])
    assert(#resumed == 1 and resumed[1].url == sources[2].url and resumed[1].original_source_index == 2)
    local invalid = source.make_source(first.url, {catchup = "?start=${unknown}", catchup_type = "append"})
    assert(#build_catchup_playback_sources({sources = {invalid}}, start, finish, invalid.catchup, "https://fallback.test/") == 0)
    assert(#notices == 1 and notices[1]:find("占位符", 1, true))
    invalid.catchup, invalid.catchup_type = template, "default"
    assert(#build_catchup_playback_sources({sources = {invalid}}, start, finish) == 0)
end

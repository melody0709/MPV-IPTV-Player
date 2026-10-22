return function()
    local parser = require 'm3u'

    local content = [[
#EXTM3U x-tvg-url="https://epg.test/guide.xml" http-user-agent="PlaylistUA/1.0"
#EXTINF:-1 tvg-id="c1" tvg-name="News" group-title="TV" http-referrer="https://entry.ref/" catchup-source="https://catch.test/${utc:yyyyMMddHHmmss}.m3u8",News, HD
#EXTVLCOPT:http-origin=https://origin.test
#EXTHTTP:{"Cookie":"sid=abc","X-Test":"one"}
#KODIPROP:inputstream.adaptive.manifest_type=hls
https://primary.test/play.php?ch=1|User-Agent=Pipe%2F2.0&Referer=https%3A%2F%2Fpipe.ref%2F
#EXTINF:-1 tvg-id="c1" tvg-name="News" group-title="TV",News, HD
#KODIPROP:inputstream.adaptive.common_headers=Authorization=Bearer%20token
https://backup.test/live.m3u8
#EXTINF:-1 tvg-id="c2" group-title="TV",DRM Channel
#KODIPROP:inputstream.adaptive.license_type=com.widevine.alpha
#KODIPROP:inputstream.adaptive.license_key=https://license.test/key
https://drm.test/manifest.mpd
#EXTINF:-1 tvg-id="c3" group-title="TV",Query Identity
https://same.test/live?channel=one
#EXTINF:-1 tvg-id="c3" group-title="TV",Query Identity
https://same.test/live?channel=two
#EXTINF:-1 tvg-id="c3" group-title="TV",Query Identity
https://same.test/live?channel=two
]]

    local parsed = parser.parse(content, {
        json_decode = function()
            return {Cookie = "sid=abc", ["X-Test"] = "one"}
        end,
    })

    assert(parsed.epg_url == "https://epg.test/guide.xml")
    assert(parsed.channel_count == 3)
    assert(parsed.source_count == 5)
    assert(parsed.duplicate_source_count == 1)
    assert(parsed.drm_source_count == 1)
    assert(#parsed.group_names == 1 and parsed.group_names[1] == "TV")

    local news = parsed.groups.TV[1]
    assert(news.name == "News, HD")
    assert(news.url == "https://primary.test/play.php?ch=1")
    assert(#news.sources == 2)
    assert(news.sources[1].headers["User-Agent"] == "Pipe/2.0")
    assert(news.sources[1].headers.Referer == "https://pipe.ref/")
    assert(news.sources[1].headers.Origin == "https://origin.test")
    assert(news.sources[1].headers.Cookie == "sid=abc")
    assert(news.sources[1].headers["X-Test"] == "one")
    assert(news.sources[1].format == "hls")
    assert(news.sources[1].format_origin == "kodiprop")
    assert(news.sources[2].headers["User-Agent"] == "PlaylistUA/1.0")
    assert(news.sources[2].headers.Authorization == "Bearer token")
    assert(news.sources[2].format == "hls")
    assert(news.catchup:find("catch.test", 1, true))

    local drm = parsed.groups.TV[2].sources[1]
    assert(drm.format == "dash")
    assert(drm.drm.type == "com.widevine.alpha")
    assert(drm.drm.license_key == "https://license.test/key")

    local query_channel = parsed.groups.TV[3]
    assert(#query_channel.sources == 2)
    assert(query_channel.sources[1].url:find("channel=one", 1, true))
    assert(query_channel.sources[2].url:find("channel=two", 1, true))
    assert(query_channel.sources[1].id ~= query_channel.sources[2].id)

    local unsafe = parser.parse([[
#EXTM3U
#EXTINF:-1 group-title="TV",Unsafe
https://unsafe.test/live|X-Test=ok%0d%0aInjected%3Ayes
]])
    assert(unsafe.rejected_header_count == 1)
    assert(next(unsafe.groups.TV[1].sources[1].headers) == nil)

    local identity = parser.parse([[
#EXTM3U
#EXTINF:-1 tvg-id="same" group-title="TV" format="hls",Same
https://identity.test/live
#EXTINF:-1 tvg-id="same" group-title="TV" format="mpegts",Same
https://identity.test/live
]])
    local identity_sources = identity.groups.TV[1].sources
    assert(#identity_sources == 2)
    assert(identity_sources[1].id ~= identity_sources[2].id)

    local bare = parser.parse([[
#EXTM3U
https://bare.test/live|Authorization=Bearer%20secret
]])
    local bare_channel = bare.groups[bare.group_names[1]][1]
    assert(bare_channel.url == "https://bare.test/live")
    assert(bare_channel.sources[1].headers.Authorization == "Bearer secret")
    assert(not bare_channel.name:find("Authorization", 1, true))
    assert(not bare_channel.name:find("secret", 1, true))

    local clear = parser.parse([[
#EXTM3U
#EXTINF:-1 group-title="TV",Clear
#KODIPROP:inputstream.adaptive.license_type=none
https://clear.test/live
]])
    assert(clear.groups.TV[1].sources[1].drm == nil)

    local unsafe_scheme = parser.parse([[
#EXTM3U
#EXTINF:-1,Local file
file:///C:/secret.mp4
]])
    assert(unsafe_scheme.channel_count == 0)
end

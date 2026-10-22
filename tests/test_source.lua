return function()
    local source = require 'source'

    local clean_url, headers, rejected = source.split_url_headers(
        "https://example.test/live.php?id=1|User-Agent=Pipe%2F2.0&Referer=https%3A%2F%2Fref.test%2F"
    )
    assert(clean_url == "https://example.test/live.php?id=1")
    assert(headers["User-Agent"] == "Pipe/2.0")
    assert(headers.Referer == "https://ref.test/")
    assert(rejected == 0)

    local unsafe_headers, unsafe_rejected = source.parse_header_query(
        "X-Good=yes&X-Bad=ok%0d%0aInjected%3Ayes"
    )
    assert(unsafe_headers["X-Good"] == "yes")
    assert(unsafe_headers["X-Bad"] == nil)
    assert(unsafe_rejected == 1)
    local control_headers, control_rejected = source.parse_header_query("X-Control=bad%00value")
    assert(next(control_headers) == nil)
    assert(control_rejected == 1)

    local merged = source.merge_headers(
        {['User-Agent'] = "playlist", Referer = "https://first/"},
        {['User-Agent'] = "entry"},
        {['User-Agent'] = "pipe", Origin = "https://origin/"}
    )
    assert(merged["User-Agent"] == "pipe")
    assert(merged.Referer == "https://first/")
    assert(merged.Origin == "https://origin/")

    local fields = source.serialize_http_header_fields({
        ["User-Agent"] = "ua",
        Referer = "https://ref/",
        ["X-Test"] = "a,b\\c",
    })
    assert(fields == "X-Test: a\\,b\\\\c")

    local descriptor = source.make_source("https://example.test/path", {
        headers = {
            ["User-Agent"] = "channel-ua",
            Referer = "https://ref/",
            Origin = "https://origin/",
            Cookie = "sid=secret",
        },
    })
    local options = source.build_mpv_file_options(descriptor, "hls", {
        default_user_agent = "fallback-ua",
        network_timeout = 8,
    })
    assert(options["user-agent"] == "channel-ua")
    assert(options.referrer == "https://ref/")
    assert(options["http-header-fields"]:find("Cookie: sid=secret", 1, true))
    assert(options["http-header-fields"]:find("Origin: https://origin/", 1, true))
    assert(options.demuxer == "lavf")
    assert(options["demuxer-lavf-format"] == "hls")
    assert(options["demuxer-lavf-propagate-opts"] == "yes")
    assert(options["network-timeout"] == "8")
    for _, value in pairs(options) do
        assert(type(value) == "string")
    end

    local fallback_options = source.build_mpv_file_options({url = "https://example.test", headers = {}}, "auto", {
        default_user_agent = "fallback-ua",
    })
    assert(fallback_options["user-agent"] == "fallback-ua")
    assert(fallback_options.demuxer == "lavf")
    assert(fallback_options["demuxer-lavf-format"] == nil)

    local redacted = source.redact_url(
        "https://user:pass@example.test/live?token=abc&id=42#access-token|Cookie=sid%3Dsecret"
    )
    assert(redacted == "https://<redacted>@example.test/live?token=<redacted>&id=<redacted>#<redacted>")
    assert(not redacted:find("abc", 1, true))
    assert(not redacted:find("secret", 1, true))

    assert(source.infer_format_from_url("https://example.test/live.m3u8?token=x") == "hls")
    assert(source.infer_format_from_url("https://example.test/live.php?id=1") == nil)
    assert(source.supports_http_format_fallback("https://example.test/live.php?id=1"))
    assert(not source.supports_http_format_fallback("https://example.test/movie.mp4"))
    assert(source.is_media_url("https://example.test/live|Cookie=sid%3D1"))
    assert(source.is_media_url("srt://example.test:9000"))
    assert(not source.is_media_url("file:///C:/secret.mp4"))
    assert(not source.is_media_url("av://lavfi:testsrc"))
    assert(source.source_cache_key(descriptor):match("^src:%x%x%x%x%x%x%x%x$"))

    local hls_identity = source.make_source("https://same.test/live", {
        headers = {Referer = "https://ref/"},
        format = "hls",
    })
    local ts_identity = source.make_source("https://same.test/live", {
        headers = {Referer = "https://ref/"},
        format = "mpegts",
    })
    assert(hls_identity.id ~= ts_identity.id)
    assert(source.source_cache_key(hls_identity) == source.source_cache_key(ts_identity))
    assert(source.normalize_drm_type("none") == nil)
    assert(not source.source_requires_drm({drm = {type = "none"}}))

    local unsafe_cache_key_source = source.make_source("https://example.test/live", {
        headers = {},
        format_cache_key = "https://secret.test/token",
    })
    assert(unsafe_cache_key_source.format_cache_key:match("^src:%x%x%x%x%x%x%x%x$"))
end

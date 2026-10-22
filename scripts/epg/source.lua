--[[
    source.lua - IPTV source descriptor 纯工具层
    不依赖 mp/state，可由 Lua 单元测试直接加载。
]]

local M = {}

local HEADER_ALIASES = {
    ["user-agent"] = "User-Agent",
    ["http-user-agent"] = "User-Agent",
    ["referer"] = "Referer",
    ["referrer"] = "Referer",
    ["http-referer"] = "Referer",
    ["http-referrer"] = "Referer",
    ["origin"] = "Origin",
    ["http-origin"] = "Origin",
    ["cookie"] = "Cookie",
    ["http-cookie"] = "Cookie",
    ["authorization"] = "Authorization",
    ["http-authorization"] = "Authorization",
}

local ATTRIBUTE_HEADER_KEYS = {
    "user-agent",
    "http-user-agent",
    "referer",
    "referrer",
    "http-referer",
    "http-referrer",
    "origin",
    "http-origin",
    "cookie",
    "http-cookie",
    "authorization",
    "http-authorization",
}

-- 远程 IPTV M3U 只允许明确的网络媒体协议。脚本会直接对解析结果执行
-- loadfile，因此不能像 mpv 原生远程播放列表那样依赖 unsafe-playlist 保护。
local SAFE_MEDIA_SCHEMES = {
    http = true,
    https = true,
    rtsp = true,
    rtsps = true,
    rtmp = true,
    rtmps = true,
    rtp = true,
    srtp = true,
    srt = true,
    udp = true,
    udplite = true,
    mms = true,
    mmsh = true,
}

local CLEAR_DRM_TYPES = {
    ["none"] = true,
    ["no"] = true,
    ["false"] = true,
    ["off"] = true,
    ["clear"] = true,
    ["unencrypted"] = true,
    ["disabled"] = true,
}

local function trim(value)
    if value == nil then
        return ""
    end
    return tostring(value):match("^%s*(.-)%s*$")
end

local function copy_table(input)
    local result = {}
    if type(input) ~= "table" then
        return result
    end
    for key, value in pairs(input) do
        result[key] = value
    end
    return result
end

local function option_string(value)
    if type(value) == "boolean" then
        return value and "yes" or "no"
    end
    return tostring(value)
end

function M.trim(value)
    return trim(value)
end

function M.copy_table(input)
    return copy_table(input)
end

function M.url_decode(value)
    local decoded = tostring(value or ""):gsub("+", " ")
    return (decoded:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

function M.canonical_header_name(name)
    local candidate = trim(name)
    if candidate == "" then
        return nil, "empty-name"
    end
    if candidate:find("[\r\n:]") then
        return nil, "invalid-name"
    end
    if candidate:find("[^%w!#$%%&'*+%.%^_`|~%-]") then
        return nil, "invalid-name"
    end
    return HEADER_ALIASES[candidate:lower()] or candidate
end

function M.add_header(headers, name, value)
    if type(headers) ~= "table" then
        return false, "invalid-target"
    end

    local canonical, err = M.canonical_header_name(name)
    if not canonical then
        return false, err
    end

    local canonical_lower = canonical:lower()
    for existing_name in pairs(headers) do
        if tostring(existing_name):lower() == canonical_lower then
            canonical = existing_name
            break
        end
    end

    local normalized_value = trim(value)
    for index = 1, #normalized_value do
        local byte = normalized_value:byte(index)
        if (byte < 32 and byte ~= 9) or byte == 127 then
            return false, "invalid-value"
        end
    end
    if normalized_value == "" then
        return false, "empty-value"
    end

    headers[canonical] = normalized_value
    return true
end

function M.normalize_headers(input)
    local result = {}
    local rejected = 0
    if type(input) ~= "table" then
        return result, rejected
    end

    for name, value in pairs(input) do
        if type(value) == "string" or type(value) == "number" then
            local ok = M.add_header(result, name, value)
            if not ok then
                rejected = rejected + 1
            end
        else
            rejected = rejected + 1
        end
    end
    return result, rejected
end

function M.merge_headers(...)
    local result = {}
    for index = 1, select("#", ...) do
        local input = select(index, ...)
        if type(input) == "table" then
            for name, value in pairs(input) do
                M.add_header(result, name, value)
            end
        end
    end
    return result
end

function M.parse_header_query(value)
    local headers = {}
    local rejected = 0
    local input = trim(value):gsub("^|", "", 1)
    if not input:find("=", 1, true) and input:lower():find("%%3d", 1, true) then
        input = M.url_decode(input)
    end
    if input == "" then
        return headers, rejected
    end

    for part in input:gmatch("([^&]+)") do
        local raw_name, raw_value = part:match("^([^=]+)=(.*)$")
        if raw_name then
            local ok = M.add_header(headers, M.url_decode(raw_name), M.url_decode(raw_value))
            if not ok then
                rejected = rejected + 1
            end
        else
            rejected = rejected + 1
        end
    end
    return headers, rejected
end

function M.parse_header_assignment(value)
    local input = trim(value)
    local name, header_value = input:match("^([^:=]+)%s*[:=]%s*(.+)$")
    if not name then
        return {}, 1
    end
    local result = {}
    local ok = M.add_header(result, name, header_value)
    return result, ok and 0 or 1
end

function M.split_url_headers(raw_url)
    local input = trim(raw_url)
    local url, pipe_value = input:match("^(.-)|(.+)$")
    if not url then
        return input, {}, 0
    end
    local headers, rejected = M.parse_header_query(pipe_value)
    return trim(url), headers, rejected
end

function M.headers_from_attributes(attributes)
    local result = {}
    local rejected = 0
    if type(attributes) ~= "table" then
        return result, rejected
    end

    for _, key in ipairs(ATTRIBUTE_HEADER_KEYS) do
        if attributes[key] ~= nil then
            local ok = M.add_header(result, key, attributes[key])
            if not ok then
                rejected = rejected + 1
            end
        end
    end

    for _, key in ipairs({"headers", "http-headers", "http-header-fields"}) do
        if attributes[key] then
            local parsed, parsed_rejected = M.parse_header_query(attributes[key])
            result = M.merge_headers(result, parsed)
            rejected = rejected + parsed_rejected
        end
    end

    return result, rejected
end

function M.normalize_format(value)
    local normalized = trim(value):lower()
    normalized = normalized:match("^([^;]+)") or normalized
    normalized = trim(normalized)
    if normalized == "" or normalized == "auto" or normalized == "unknown" then
        return nil
    end
    if normalized == "hls" or normalized == "m3u8" or normalized:find("mpegurl", 1, true) then
        return "hls"
    end
    if normalized == "dash" or normalized == "mpd" or normalized:find("dash+xml", 1, true) then
        return "dash"
    end
    if normalized == "mpegts" or normalized == "mpeg-ts" or normalized == "ts"
        or normalized == "video/mp2t" or normalized:find("mp2t", 1, true) then
        return "mpegts"
    end
    return nil
end

function M.format_from_attributes(attributes)
    if type(attributes) ~= "table" then
        return nil
    end
    for _, key in ipairs({
        "manifest-type", "manifest_type", "format", "stream-format", "stream_format",
        "mime-type", "mime_type", "mimetype", "type",
    }) do
        local normalized = M.normalize_format(attributes[key])
        if normalized then
            return normalized
        end
    end
    return nil
end

function M.normalize_drm_type(value)
    local normalized = trim(value)
    if normalized == "" or CLEAR_DRM_TYPES[normalized:lower()] then
        return nil
    end
    return normalized
end

function M.drm_from_attributes(attributes)
    if type(attributes) ~= "table" then
        return nil
    end

    local drm_type = attributes["license-type"] or attributes.license_type
        or attributes["drm-type"] or attributes.drm_type or attributes.drm
    local license_key = attributes["license-key"] or attributes.license_key
    drm_type = M.normalize_drm_type(drm_type)
    license_key = trim(license_key)

    if not drm_type and license_key == "" then
        return nil
    end

    return {
        type = drm_type or "unknown",
        license_key = license_key ~= "" and license_key or nil,
    }
end

function M.merge_drm(...)
    local result = nil
    for index = 1, select("#", ...) do
        local drm = select(index, ...)
        if type(drm) == "table" then
            result = result or {}
            local drm_type = M.normalize_drm_type(drm.type)
            if drm_type then
                result.type = drm_type
            end
            if trim(drm.license_key) ~= "" then
                result.license_key = trim(drm.license_key)
            end
        end
    end
    if result and not result.type and not result.license_key then
        return nil
    end
    return result
end

function M.infer_format_from_url(url)
    local clean_url = M.split_url_headers(url)
    local path = clean_url:match("^[%a][%w+.-]*://[^/]*(/.*)$") or clean_url
    path = (path:match("^[^?#]*") or path):lower()
    if path:match("%.m3u8$") then
        return "hls"
    end
    if path:match("%.mpd$") then
        return "dash"
    end
    if path:match("%.m2?ts$") then
        return "mpegts"
    end
    return nil
end

function M.is_media_url(value)
    local url = M.split_url_headers(value)
    local scheme = url:match("^([%a][%w+.-]*)://")
    return scheme ~= nil and SAFE_MEDIA_SCHEMES[scheme:lower()] == true
end

function M.is_http_url(value)
    local url = trim(value):lower()
    return url:match("^https?://") ~= nil
end

function M.supports_http_format_fallback(value)
    if not M.is_http_url(value) then
        return false
    end

    local clean_url = M.split_url_headers(value)
    local path = clean_url:match("^https?://[^/]*(/.*)$") or ""
    path = (path:match("^[^?#]*") or path):lower()
    if path:match("%.mp4$") or path:match("%.mkv$") or path:match("%.webm$")
        or path:match("%.mov$") or path:match("%.avi$") or path:match("%.flv$")
        or path:match("%.mp3$") or path:match("%.aac$") or path:match("%.ogg$")
        or path:match("%.opus$") or path:match("%.wav$") then
        return false
    end
    return true
end

function M.hash_string(value)
    local hash = 5381
    local input = tostring(value or "")
    for index = 1, #input do
        hash = ((hash * 33) + input:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
end

local function sorted_keys(input)
    local keys = {}
    for key in pairs(input or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        local left_lower = tostring(left):lower()
        local right_lower = tostring(right):lower()
        if left_lower == right_lower then
            return tostring(left) < tostring(right)
        end
        return left_lower < right_lower
    end)
    return keys
end

function M.source_cache_key(source)
    if type(source) ~= "table" then
        return "src:" .. M.hash_string("")
    end
    local parts = {trim(source.url)}
    for _, name in ipairs(sorted_keys(source.headers or {})) do
        parts[#parts + 1] = tostring(name) .. ":" .. tostring(source.headers[name])
    end
    return "src:" .. M.hash_string(table.concat(parts, "\n"))
end

local function append_identity_part(parts, label, value)
    local text = tostring(value or "")
    parts[#parts + 1] = string.format("%s:%d:%s", label, #text, text)
end

-- source.id 用于历史恢复和线路身份，必须覆盖所有会改变播放语义的字段。
-- format_cache_key 则继续单独使用 URL + Header，避免把两个用途混在一起。
function M.source_identity_key(source)
    if type(source) ~= "table" then
        return "src:" .. M.hash_string("") .. M.hash_string("source-identity")
    end

    local parts = {}
    append_identity_part(parts, "url", trim(source.url))
    for _, name in ipairs(sorted_keys(source.headers or {})) do
        append_identity_part(parts, "header-name", name)
        append_identity_part(parts, "header-value", source.headers[name])
    end
    append_identity_part(parts, "format", M.normalize_format(source.format) or trim(source.format))
    append_identity_part(parts, "catchup", source.catchup)
    append_identity_part(parts, "drm-type", source.drm and M.normalize_drm_type(source.drm.type) or "")
    append_identity_part(parts, "drm-license", source.drm and source.drm.license_key or "")
    for _, name in ipairs(sorted_keys(source.file_options or {})) do
        append_identity_part(parts, "option-name", name)
        append_identity_part(parts, "option-value", source.file_options[name])
    end

    local serialized = table.concat(parts, "\n")
    return "src:" .. M.hash_string(serialized)
        .. M.hash_string("source-identity\0" .. serialized)
end

function M.clone_source(source)
    if type(source) ~= "table" then
        return nil
    end
    local result = copy_table(source)
    result.headers = copy_table(source.headers)
    result.file_options = copy_table(source.file_options)
    result.drm = source.drm and copy_table(source.drm) or nil
    return result
end

function M.make_source(raw_url, base_source)
    local source = M.clone_source(base_source) or {}
    local inherited_format_cache_key = source.format_cache_key
    if type(inherited_format_cache_key) ~= "string"
        or not inherited_format_cache_key:match("^src:%x+$") then
        inherited_format_cache_key = nil
    end
    local clean_url, pipe_headers, rejected = M.split_url_headers(raw_url)
    source.url = clean_url
    source.headers = M.merge_headers(source.headers, pipe_headers)
    if not source.format then
        source.format = M.infer_format_from_url(clean_url)
        if source.format then
            source.format_origin = "url"
        end
    end
    source.id = M.source_identity_key(source)
    source.format_cache_key = inherited_format_cache_key or M.source_cache_key(source)
    return source, rejected
end

function M.source_requires_drm(source)
    return type(source) == "table" and type(source.drm) == "table"
        and (M.normalize_drm_type(source.drm.type) ~= nil or trim(source.drm.license_key) ~= "")
end

function M.escape_mpv_string_list_item(value)
    return tostring(value or ""):gsub("\\", "\\\\"):gsub(",", "\\,")
end

function M.serialize_http_header_fields(headers)
    local fields = {}
    for _, name in ipairs(sorted_keys(headers or {})) do
        if name ~= "User-Agent" and name ~= "Referer" then
            fields[#fields + 1] = M.escape_mpv_string_list_item(name .. ": " .. tostring(headers[name]))
        end
    end
    return table.concat(fields, ",")
end

function M.build_mpv_file_options(source, mode, settings)
    local config = settings or {}
    local result = {}
    for key, value in pairs((source and source.file_options) or {}) do
        result[tostring(key)] = option_string(value)
    end

    local headers = M.merge_headers(source and source.headers or {})
    if not headers["User-Agent"] and trim(config.default_user_agent) ~= "" then
        M.add_header(headers, "User-Agent", config.default_user_agent)
    end

    if headers["User-Agent"] then
        result["user-agent"] = tostring(headers["User-Agent"])
    end
    if headers["Referer"] then
        result.referrer = tostring(headers["Referer"])
    end

    local header_fields = M.serialize_http_header_fields(headers)
    if header_fields ~= "" then
        if result["http-header-fields"] and result["http-header-fields"] ~= "" then
            result["http-header-fields"] = result["http-header-fields"] .. "," .. header_fields
        else
            result["http-header-fields"] = header_fields
        end
    end

    local timeout = tonumber(config.network_timeout)
    if timeout and timeout > 0 then
        result["network-timeout"] = tostring(timeout)
    end
    result["demuxer-lavf-propagate-opts"] = "yes"

    -- IPTV descriptor 的网络链统一留在 lavf 中。若 auto 探测失败后继续落到
    -- mpv playlist demuxer，远端 M3U8 会被展开成不继承 file options 的裸分片。
    if not result.demuxer or result.demuxer == "" then
        result.demuxer = "lavf"
    end

    local normalized_mode = M.normalize_format(mode)
    if normalized_mode then
        result["demuxer-lavf-format"] = normalized_mode
    else
        result["demuxer-lavf-format"] = nil
    end

    for key, value in pairs(result) do
        result[key] = option_string(value)
    end
    return result
end

function M.build_format_modes(source, cached_format, allow_format_fallback)
    local modes = {}
    local seen = {}
    local function add(mode)
        local normalized = mode == "auto" and "auto" or M.normalize_format(mode)
        if normalized and not seen[normalized] then
            seen[normalized] = true
            modes[#modes + 1] = normalized
        end
    end

    local declared = M.normalize_format(source and source.format)
    local cached = M.normalize_format(cached_format)
    add(declared)
    if not declared then
        add(cached)
    end
    add("auto")

    if allow_format_fallback ~= false and not declared
        and source and M.supports_http_format_fallback(source.url) then
        add("hls")
        add("mpegts")
    end
    return modes
end

function M.build_candidates(sources, preferred_source_index, settings)
    local config = settings or {}
    local list = type(sources) == "table" and sources or {}
    local preferred = tonumber(preferred_source_index) or 1
    preferred = math.floor(preferred)
    if preferred < 1 or preferred > #list then
        preferred = 1
    end

    local source_order = {}
    if #list > 0 then
        source_order[#source_order + 1] = preferred
        if config.source_fallback ~= false then
            for index = 1, #list do
                if index ~= preferred then
                    source_order[#source_order + 1] = index
                end
            end
        end
    end

    local candidates = {}
    local skipped_drm = {}
    for _, source_index in ipairs(source_order) do
        local source = list[source_index]
        if M.source_requires_drm(source) then
            skipped_drm[#skipped_drm + 1] = source_index
        elseif type(source) == "table" and trim(source.url) ~= "" then
            local cache_key = type(source.format_cache_key) == "string"
                and source.format_cache_key:match("^src:%x+$") and source.format_cache_key
                or M.source_cache_key(source)
            local cached_format = config.format_cache and config.format_cache[cache_key] or nil
            local modes = M.build_format_modes(source, cached_format, config.format_fallback)
            for _, mode in ipairs(modes) do
                candidates[#candidates + 1] = {
                    source = source,
                    source_index = source_index,
                    mode = mode,
                    cache_key = cache_key,
                }
            end
        end
    end
    return candidates, skipped_drm
end

function M.redact_url(value)
    local clean_url = M.split_url_headers(value)
    clean_url = clean_url:gsub("^([%a][%w+.-]*://)[^/@]+@", function(scheme)
        return scheme .. "<redacted>@"
    end)

    local without_fragment, fragment = clean_url:match("^(.-)#(.*)$")
    local fragment_suffix = ""
    if without_fragment then
        clean_url = without_fragment
        fragment_suffix = "#<redacted>"
    end

    local prefix, query = clean_url:match("^([^?]*)%?(.*)$")
    if not prefix then
        return clean_url .. fragment_suffix
    end

    local redacted = {}
    for part in tostring(query):gmatch("([^&]+)") do
        local name = part:match("^([^=]+)=")
        if name and name ~= "" then
            redacted[#redacted + 1] = name .. "=<redacted>"
        else
            redacted[#redacted + 1] = "<redacted>"
        end
    end
    return prefix .. "?" .. table.concat(redacted, "&") .. fragment_suffix
end

function M.header_names_summary(headers)
    local keys = sorted_keys(headers or {})
    if #keys == 0 then
        return "none"
    end
    return table.concat(keys, ",")
end

return M

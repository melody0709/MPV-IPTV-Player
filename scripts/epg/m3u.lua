--[[
    m3u.lua - M3U/M3U8 IPTV 纯解析器
    输出带多 source、Header、格式和 DRM 元数据的频道模型。
]]

local source_model = require 'source'

local M = {}

local function trim(value)
    return source_model.trim(value)
end

local function new_pending_options()
    return {
        headers = {},
        format = nil,
        format_origin = nil,
        drm = nil,
        rejected_headers = 0,
    }
end

local function split_first_unquoted_comma(value)
    local quote = nil
    for index = 1, #value do
        local char = value:sub(index, index)
        if quote then
            if char == quote and value:sub(index - 1, index - 1) ~= "\\" then
                quote = nil
            end
        elseif char == '"' or char == "'" then
            quote = char
        elseif char == "," then
            return value:sub(1, index - 1), value:sub(index + 1)
        end
    end
    return value, ""
end

function M.parse_attributes(value)
    local attributes = {}
    local input = tostring(value or "")
    local index = 1

    while index <= #input do
        local remaining = input:sub(index)
        local whitespace = remaining:match("^(%s+)")
        if whitespace then
            index = index + #whitespace
        else
            local key = remaining:match("^([%w_%.:%-]+)")
            if not key then
                index = index + 1
            else
                local cursor = index + #key
                while input:sub(cursor, cursor):match("%s") do
                    cursor = cursor + 1
                end

                if input:sub(cursor, cursor) ~= "=" then
                    index = cursor + 1
                else
                    cursor = cursor + 1
                    while input:sub(cursor, cursor):match("%s") do
                        cursor = cursor + 1
                    end

                    local quote = input:sub(cursor, cursor)
                    local parsed_value
                    if quote == '"' or quote == "'" then
                        local value_start = cursor + 1
                        local value_end = value_start
                        while value_end <= #input do
                            if input:sub(value_end, value_end) == quote
                                and input:sub(value_end - 1, value_end - 1) ~= "\\" then
                                break
                            end
                            value_end = value_end + 1
                        end
                        parsed_value = input:sub(value_start, value_end - 1)
                        index = value_end + 1
                    else
                        local value_start = cursor
                        local value_end = cursor
                        while value_end <= #input and not input:sub(value_end, value_end):match("[%s,]") do
                            value_end = value_end + 1
                        end
                        parsed_value = input:sub(value_start, value_end - 1)
                        index = value_end
                    end
                    attributes[key:lower()] = parsed_value
                end
            end
        end
    end

    return attributes
end

local function parse_catchup_days(value)
    local days = tonumber(value)
    if days and days >= 0 and days < math.huge then return days end
    return nil
end

local function parse_extinf(line)
    local payload = line:gsub("^#EXTINF:%s*", "", 1)
    local attribute_text, display_name = split_first_unquoted_comma(payload)
    attribute_text = attribute_text:gsub("^%s*[%+%-]?[%d%.]+%s*", "", 1)
    local attributes = M.parse_attributes(attribute_text)
    local headers, rejected = source_model.headers_from_attributes(attributes)

    local name = trim(display_name)
    if name == "" then
        name = trim(attributes["tvg-name"])
    end
    if name == "" then
        name = "未知频道"
    end

    return {
        attributes = attributes,
        tvg_id = trim(attributes["tvg-id"]),
        name = name,
        catchup = attributes["catchup-source"] and trim(attributes["catchup-source"]),
        catchup_type = attributes.catchup and trim(attributes.catchup):lower(),
        catchup_days = parse_catchup_days(attributes["catchup-days"]),
        group = trim(attributes["group-title"]) ~= "" and trim(attributes["group-title"]) or "其他频道",
        logo = trim(attributes["tvg-logo"]),
        headers = headers,
        format = source_model.format_from_attributes(attributes),
        drm = source_model.drm_from_attributes(attributes),
        rejected_headers = rejected,
    }
end

local function merge_pending_headers(pending, headers, rejected)
    pending.headers = source_model.merge_headers(pending.headers, headers)
    pending.rejected_headers = pending.rejected_headers + (tonumber(rejected) or 0)
end

local function apply_extvlcopt(pending, line)
    local key, value = line:match("^#EXTVLCOPT:([^=]+)=(.*)$")
    if not key then
        return
    end

    local normalized_key = trim(key):lower()
    if normalized_key == "http-header" then
        local headers, rejected = source_model.parse_header_assignment(value)
        merge_pending_headers(pending, headers, rejected)
    elseif normalized_key == "http-headers" or normalized_key == "http-header-fields" then
        local headers, rejected = source_model.parse_header_query(value)
        merge_pending_headers(pending, headers, rejected)
    elseif normalized_key == "http-user-agent" or normalized_key == "http-referrer"
        or normalized_key == "http-referer" or normalized_key == "http-origin"
        or normalized_key == "http-cookie" or normalized_key == "http-authorization" then
        local ok = source_model.add_header(pending.headers, normalized_key, value)
        if not ok then
            pending.rejected_headers = pending.rejected_headers + 1
        end
    elseif normalized_key == "demuxer-lavf-format" or normalized_key == "format" then
        local format = source_model.normalize_format(value)
        if format then
            pending.format = format
            pending.format_origin = "extvlcopt"
        end
    end
end

local function lowercase_keys(input)
    local result = {}
    for key, value in pairs(input or {}) do
        result[tostring(key):lower()] = value
    end
    return result
end

local EXTHHTTP_METADATA_KEYS = {
    headers = true,
    header = true,
    format = true,
    ["manifest-type"] = true,
    manifest_type = true,
    ["mime-type"] = true,
    mime_type = true,
    mimetype = true,
    drm = true,
    ["drm-type"] = true,
    drm_type = true,
    ["license-type"] = true,
    license_type = true,
    ["license-key"] = true,
    license_key = true,
}

local function apply_exthttp(pending, line, json_decode)
    if type(json_decode) ~= "function" then
        return
    end

    local payload = line:match("^#EXTHTTP:%s*(.*)$")
    if not payload or trim(payload) == "" then
        return
    end

    local ok, decoded = pcall(json_decode, payload)
    if not ok or type(decoded) ~= "table" then
        return
    end

    local lowered = lowercase_keys(decoded)
    local direct_headers = {}
    for key, value in pairs(decoded) do
        local lower_key = tostring(key):lower()
        if not EXTHHTTP_METADATA_KEYS[lower_key]
            and (type(value) == "string" or type(value) == "number") then
            direct_headers[key] = value
        end
    end

    local normalized_direct, direct_rejected = source_model.normalize_headers(direct_headers)
    merge_pending_headers(pending, normalized_direct, direct_rejected)

    if type(lowered.headers) == "table" then
        local nested, nested_rejected = source_model.normalize_headers(lowered.headers)
        merge_pending_headers(pending, nested, nested_rejected)
    end
    if type(lowered.header) == "table" then
        local nested, nested_rejected = source_model.normalize_headers(lowered.header)
        merge_pending_headers(pending, nested, nested_rejected)
    end

    local format = source_model.format_from_attributes(lowered)
    if format then
        pending.format = format
        pending.format_origin = "exthttp"
    end
    pending.drm = source_model.merge_drm(pending.drm, source_model.drm_from_attributes(lowered))
end

local function kodi_key_ends_with(key, suffix)
    return key:sub(-#suffix) == suffix
end

local function apply_kodiprop(pending, line)
    local key, value = line:match("^#KODIPROP:([^=]+)=(.*)$")
    if not key then
        return
    end

    local normalized_key = trim(key):lower()
    if kodi_key_ends_with(normalized_key, "stream_headers")
        or kodi_key_ends_with(normalized_key, "manifest_headers")
        or kodi_key_ends_with(normalized_key, "common_headers") then
        local headers, rejected = source_model.parse_header_query(value)
        merge_pending_headers(pending, headers, rejected)
        return
    end

    if kodi_key_ends_with(normalized_key, "manifest_type")
        or kodi_key_ends_with(normalized_key, "mimetype") then
        local format = source_model.normalize_format(value)
        if format then
            pending.format = format
            pending.format_origin = "kodiprop"
        end
        return
    end

    if kodi_key_ends_with(normalized_key, "license_type") then
        local drm_type = source_model.normalize_drm_type(value)
        if drm_type then
            pending.drm = source_model.merge_drm(pending.drm, {type = drm_type})
        end
        return
    end
    if kodi_key_ends_with(normalized_key, "license_key") then
        pending.drm = source_model.merge_drm(pending.drm, {license_key = trim(value)})
    end
end

local function source_dedupe_key(source)
    return source_model.source_identity_key(source)
end

local function channel_identity(entry)
    local identity
    if entry.identity_key and entry.identity_key ~= "" then
        identity = entry.identity_key
    elseif entry.tvg_id and entry.tvg_id ~= "" then
        identity = "tvg:" .. entry.tvg_id
    else
        identity = "name:" .. entry.name
    end
    return entry.group .. "\n" .. identity
end

local function append_source(result, channel_map, entry, pending, playlist_defaults, raw_url)
    local clean_url, pipe_headers, pipe_rejected = source_model.split_url_headers(raw_url)
    if clean_url == "" or not source_model.is_media_url(clean_url) then
        return false
    end

    local inferred_format = source_model.infer_format_from_url(clean_url)
    local format = pending.format or entry.format or playlist_defaults.format or inferred_format
    local format_origin = pending.format and pending.format_origin
        or (entry.format and "extinf")
        or (playlist_defaults.format and "playlist")
        or (inferred_format and "url")
        or nil
    local headers = source_model.merge_headers(
        playlist_defaults.headers,
        entry.headers,
        pending.headers,
        pipe_headers
    )
    local drm = source_model.merge_drm(entry.drm, pending.drm)
    local source = {
        url = clean_url,
        headers = headers,
        format = format,
        format_origin = format_origin,
        catchup = entry.catchup or playlist_defaults.catchup or "",
        catchup_type = entry.catchup_type or playlist_defaults.catchup_type,
        catchup_days = entry.catchup_days or playlist_defaults.catchup_days,
        drm = drm,
    }
    source.id = source_model.source_identity_key(source)

    local identity = channel_identity(entry)
    local channel = channel_map[identity]
    if not channel then
        channel = {
            key = "ch:" .. source_model.hash_string(identity),
            name = entry.name,
            url = source.url,
            tvg_id = entry.tvg_id,
            catchup = source.catchup,
            catchup_type = source.catchup_type,
            catchup_days = source.catchup_days,
            logo = entry.logo,
            group = entry.group,
            sources = {},
            _source_keys = {},
        }
        channel_map[identity] = channel
        if not result.groups[entry.group] then
            result.groups[entry.group] = {}
            result.group_names[#result.group_names + 1] = entry.group
        end
        result.groups[entry.group][#result.groups[entry.group] + 1] = channel
        result.channel_count = result.channel_count + 1
    end

    local dedupe_key = source_dedupe_key(source)
    if not channel._source_keys[dedupe_key] then
        channel._source_keys[dedupe_key] = true
        channel.sources[#channel.sources + 1] = source
        result.source_count = result.source_count + 1
        if source_model.source_requires_drm(source) then
            result.drm_source_count = result.drm_source_count + 1
        end
    else
        result.duplicate_source_count = result.duplicate_source_count + 1
    end

    if channel.catchup == "" and source.catchup ~= "" then
        channel.catchup = source.catchup
        channel.catchup_type = source.catchup_type
        channel.catchup_days = source.catchup_days
    end
    if channel.logo == "" and entry.logo ~= "" then
        channel.logo = entry.logo
    end

    result.rejected_header_count = result.rejected_header_count
        + (entry.rejected_headers or 0)
        + (pending.rejected_headers or 0)
        + (pipe_rejected or 0)
    return true
end

function M.parse(content, options)
    local config = options or {}
    local input = tostring(content or "")
    if input:sub(1, 3) == "\239\187\191" then
        input = input:sub(4)
    end

    local result = {
        groups = {},
        group_names = {},
        epg_url = "",
        channel_count = 0,
        source_count = 0,
        duplicate_source_count = 0,
        drm_source_count = 0,
        rejected_header_count = 0,
    }
    local channel_map = {}
    local playlist_defaults = {headers = {}, format = nil}
    local current_entry = nil
    local pending = new_pending_options()

    for raw_line in input:gmatch("([^\r\n]+)") do
        local line = trim(raw_line)
        if line:match("^#EXTM3U") then
            local attributes = M.parse_attributes(line:gsub("^#EXTM3U%s*", "", 1))
            result.epg_url = trim(attributes["x-tvg-url"] or attributes["url-tvg"] or attributes["tvg-url"])
            local headers, rejected = source_model.headers_from_attributes(attributes)
            playlist_defaults.headers = source_model.merge_headers(playlist_defaults.headers, headers)
            result.rejected_header_count = result.rejected_header_count + rejected
            playlist_defaults.format = source_model.format_from_attributes(attributes)
            playlist_defaults.catchup = attributes["catchup-source"] and trim(attributes["catchup-source"])
            playlist_defaults.catchup_type = attributes.catchup and trim(attributes.catchup):lower()
            playlist_defaults.catchup_days = parse_catchup_days(attributes["catchup-days"])
        elseif line:match("^#EXTINF:") then
            if current_entry then
                pending = new_pending_options()
            end
            current_entry = parse_extinf(line)
        elseif line:match("^#EXTGRP:") and current_entry then
            local group = trim(line:match("^#EXTGRP:%s*(.*)$"))
            if group ~= "" then
                current_entry.group = group
            end
        elseif line:match("^#EXTVLCOPT:") then
            apply_extvlcopt(pending, line)
        elseif line:match("^#EXTHTTP:") then
            apply_exthttp(pending, line, config.json_decode)
        elseif line:match("^#KODIPROP:") then
            apply_kodiprop(pending, line)
        elseif line ~= "" and not line:match("^#") and source_model.is_media_url(line) then
            local bare_url = source_model.split_url_headers(line)
            local entry = current_entry or {
                tvg_id = "",
                -- 裸 URL 没有频道名时只展示脱敏 URL；pipe Header/凭据不能进入
                -- 菜单、日志或历史。内部 identity_key 仍区分不同真实 URL。
                name = source_model.redact_url(bare_url),
                identity_key = "url:" .. source_model.source_cache_key({url = bare_url, headers = {}}),
                catchup = nil,
                group = "其他频道",
                logo = "",
                headers = {},
                format = nil,
                drm = nil,
                rejected_headers = 0,
            }
            append_source(result, channel_map, entry, pending, playlist_defaults, line)
            current_entry = nil
            pending = new_pending_options()
        end
    end

    for _, group_name in ipairs(result.group_names) do
        for _, channel in ipairs(result.groups[group_name]) do
            channel._source_keys = nil
            if channel.sources[1] then
                channel.url = channel.sources[1].url
                if channel.catchup == "" then
                    channel.catchup = channel.sources[1].catchup or ""
                end
            end
        end
    end

    return result
end

return M

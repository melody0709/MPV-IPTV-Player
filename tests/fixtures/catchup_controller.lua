local mp = require 'mp'
mp.add_timeout(5, function() mp.commandv("quit", 1) end)

utc_timestamp_cache, xmltv_utc_cache = {}, {}
assert(loadfile(mp.command_native({"expand-path", "~~home/scripts/epg/utils.lua"})))()
assert(utc_str_to_timestamp("20261021120000") == 1792584000)
assert(xmltv_to_utc("20261021200000 +0800") == "20261021120000")
assert(os.date("!%Y%m%d%H%M%S", utc_str_to_timestamp("20260308023000")) == "20260308023000")

local requested = false
mp.add_periodic_timer(0.05, function()
    local name = mp.get_property_native("user-data/epg/current_channel_name")
    if requested or name ~= "Redirect HLS Integration" then return end
    requested = true
    mp.commandv("script-message-to", "epg", "play-catchup", "",
        "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}",
        "20261021120000", "20261021130000", "http://127.0.0.1:18991/start?channel=13")
end)

mp.add_timeout(4, function()
    if not requested or not mp.get_property_native("user-data/epg/is_catchup") then
        mp.msg.error("catchup state missing; requested=" .. tostring(requested))
        mp.commandv("quit", 1)
        return
    end
    mp.commandv("quit")
end)

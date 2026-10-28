package.path = "./scripts/epg/?.lua;./?.lua;" .. package.path

local test_files = {
    "tests/test_source.lua",
    "tests/test_m3u.lua",
    "tests/test_catchup.lua",
    "tests/test_data_index.lua",
    "tests/test_playback.lua",
    "tests/test_channel_actions.lua",
}

local passed = 0
for _, path in ipairs(test_files) do
    local test = assert(loadfile(path))()
    assert(type(test) == "function", path .. " must return a test function")
    test()
    passed = passed + 1
    io.write("PASS ", path, "\n")
end

io.write(string.format("PASS all (%d files)\n", passed))

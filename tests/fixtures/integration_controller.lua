local mp = require 'mp'

mp.add_timeout(4.0, function()
    mp.commandv("quit")
end)

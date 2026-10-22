local mp = require 'mp'

mp.add_timeout(0.5, function()
    mp.commandv("quit")
end)

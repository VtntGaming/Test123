local Loader = require(game.ReplicatedStorage.Module.Utils.Loader)

local module = {}
module = Loader.LoadChildren(script)

return module

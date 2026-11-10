--!strict
--// Services

--// Modules

--// References

--// Types
export type VoteItem = {
    __index: VoteItem,
    new: () -> VoteItem,
    Start: (self: VoteItem) -> (),
}

local Item = {} :: VoteItem
Item.__index = Item

function Item.new()
    local self = setmetatable({}, Item) :: VoteItem

    return self
end

function Item:Start()
    
end

return Item
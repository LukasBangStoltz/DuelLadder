local ADDON, ns = ...

ns.ADDON = ADDON
ns.VERSION = ns.Compat.GetAddOnMetadata(ADDON, "Version") or "dev"

function ns.Print(...)
    print("|cffff8800DuelLadder|r:", ...)
end

------------------------------------------------------------------------
-- Tiny event bus: game events and our own internal events share one API.
------------------------------------------------------------------------

local handlers = {}
local eventFrame = CreateFrame("Frame")

function ns:On(event, fn)
    handlers[event] = handlers[event] or {}
    table.insert(handlers[event], fn)
end

function ns:Fire(event, ...)
    local list = handlers[event]
    if not list then return end
    for _, fn in ipairs(list) do fn(...) end
end

-- Like On, but for real game events.
function ns:Listen(event, fn)
    eventFrame:RegisterEvent(event)
    ns:On(event, fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...) ns:Fire(event, ...) end)

------------------------------------------------------------------------
-- Startup
------------------------------------------------------------------------

-- Switches the active guild when it changes and fires GUILD_READY once it is known.
local function CheckGuild()
    local Data = ns.Data
    local key = ns.Compat.GuildKey()
    if key == Data.guildKey then return end
    if Data:SetGuild(key) then ns:Fire("GUILD_READY") end
    ns:Fire("DATA_CHANGED")
end

ns:Listen("PLAYER_LOGIN", function()
    ns.Data:Init()
    ns.Compat.RegisterPrefix(ns.PREFIX)
    ns.Compat.RequestGuildRoster()

    -- Guild info can take a while after login. Give it up to a minute.
    local tries = 0
    local function TryStart()
        CheckGuild()
        if not ns.Data.guildKey and IsInGuild() and tries < 12 then
            tries = tries + 1
            C_Timer.After(5, TryStart)
        end
    end
    C_Timer.After(3, TryStart)
end)

ns:Listen("PLAYER_GUILD_UPDATE", function(unit)
    if not ns.Data.db or (unit and unit ~= "player") then return end
    CheckGuild()
end)

ns:On("GUILD_READY", function()
    ns.Compat.RequestGuildRoster()
end)

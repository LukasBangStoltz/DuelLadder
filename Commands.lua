local _, ns = ...
local Data, UI = ns.Data, ns.UI

local function OnOff(v) return v and "|cff20ff20on|r" or "|cffff4040off|r" end

SLASH_DUELLADDER1 = "/duels"
SLASH_DUELLADDER2 = "/duelladder"
SlashCmdList.DUELLADDER = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(.-)%s*$")
    if not Data.db then
        ns.Print("Still loading, try again in a moment.")
    elseif cmd == "" then
        UI:Toggle()
    elseif cmd == "bets" then
        UI:ShowTab("Bets")
    elseif cmd == "me" then
        UI:ShowProfile(ns.Compat.PlayerKey())
    elseif cmd == "sync" then
        ns.Sync:Request()
        ns.Print("Asking the guild for fresh stats...")
    elseif cmd == "guildonly" then
        Data.settings.guildOnly = not Data.settings.guildOnly
        ns.Print("Count only duels against guild members: " .. OnOff(Data.settings.guildOnly))
        UI:RequestRefresh()
    elseif cmd == "announce" then
        Data.settings.announce = not Data.settings.announce
        ns.Print("Announce wins in guild chat: " .. OnOff(Data.settings.announce))
        UI:RequestRefresh()
    elseif cmd == "minimap" then
        ns.Minimap:Toggle()
    else
        ns.Print("Commands:")
        print("  |cffffffff/duels|r - show or hide the window")
        print("  |cffffffff/duels me|r - your profile")
        print("  |cffffffff/duels bets|r - open bets")
        print("  |cffffffff/duels sync|r - ask the guild for fresh stats")
        print("  |cffffffff/duels guildonly|r - toggle counting only duels against guild members")
        print("  |cffffffff/duels announce|r - toggle posting your wins in guild chat")
        print("  |cffffffff/duels minimap|r - show or hide the minimap button")
    end
end

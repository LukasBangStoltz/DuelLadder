local _, ns = ...
local Compat, Data = ns.Compat, ns.Data

-- Duel results come as system messages ("Ann has defeated Bob in a duel"), and both
-- duelists get one. Each player records only their own side and syncs it to the guild.

-- Turns a GlobalStrings format like "%2$s has fled from %1$s in a duel" into a function
-- that pulls the names out of a message and returns them in their numbered order.
local function Matcher(fmt)
    local order = {}
    local pattern = fmt:gsub("%%(%d)%$s", function(n)
        order[#order + 1] = tonumber(n)
        return "\001"
    end)
    pattern = pattern:gsub("%%s", function()
        order[#order + 1] = #order + 1
        return "\001"
    end)
    pattern = pattern:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    pattern = "^" .. pattern:gsub("\001", "(.+)") .. "$"

    return function(msg)
        local captures = { msg:match(pattern) }
        if #captures == 0 then return nil end
        local args = {}
        for i, argIndex in ipairs(order) do
            args[argIndex] = captures[i]
        end
        return args[1], args[2]
    end
end

local matchKnockout = Matcher(Compat.DUEL_KNOCKOUT) -- returns winner, loser
local matchRetreat = Matcher(Compat.DUEL_RETREAT)   -- returns winner, the one who fled

-- Strips colour codes and player links in case something wrapped the names.
local function CleanName(name)
    return (name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h%[?(.-)%]?|h", "%1"))
end

-- Duel length: from when we entered combat to the result. Good enough for badges.
-- If we left combat well before the result, that combat was something else (a duel where
-- nobody attacked, e.g. someone fled during the countdown), so the length is unknown.
local COMBAT_GAP = 15 -- seconds out of combat before the result that still count as the duel
local combatStart, combatEnd
ns:Listen("PLAYER_REGEN_DISABLED", function() combatStart, combatEnd = GetTime(), nil end)
ns:Listen("PLAYER_REGEN_ENABLED", function() combatEnd = GetTime() end)

local function Duration()
    local start, now = combatStart, GetTime()
    combatStart = nil
    if not start or (combatEnd and now - combatEnd > COMBAT_GAP) then return nil end
    local d = now - start
    if d < 0 or d > 600 then return nil end
    return d
end

local function Feedback(ctx, e, h)
    local name = Compat.DisplayName(ctx.opp)
    local rating = ("|cffffffff%d|r (%s%d)"):format(e.rating, ctx.delta >= 0 and "+" or "", ctx.delta)
    local record = ("|cffffffff%d-%d|r vs %s"):format(h.w, h.l, name)
    if ctx.won then
        local streak = e.streak > 1 and (" |cff20ff20%d wins in a row!|r"):format(e.streak) or ""
        ns.Print(("|cff20ff20Victory|r vs %s. Rating %s, %s.%s"):format(name, rating, record, streak))
        if Data.settings.announce then
            Compat.SendChatMessage(("[DuelLadder] %s defeated %s (rating %d)"):format(
                UnitName("player"), Compat.ShortName(ctx.opp), e.rating), "GUILD")
        end
    elseif ctx.fled then
        ns.Print(("You fled from %s. That counts as a |cffff4040loss|r. Rating %s, %s."):format(name, rating, record))
    else
        ns.Print(("|cffff4040Defeat|r vs %s. Rating %s, %s."):format(name, rating, record))
    end

    if ctx.tookCrown then
        ns.Print("|TInterface\\GroupFrame\\UI-Group-LeaderIcon:0|t |cffffd100You are the King of the Hill!|r Anyone who beats you takes the crown.")
        Compat.PlaySound("LEVEL_UP")
        if Data.settings.announce then
            Compat.SendChatMessage(("[DuelLadder] %s is the new King of the Hill!"):format(UnitName("player")), "GUILD")
        end
    elseif ctx.lostCrown then
        ns.Print("You lost the crown.")
    end
    if ctx.titleAfter ~= ctx.titleBefore then
        local _, colored = Data.Title(e)
        ns.Print("New title: " .. colored)
    end
    ns.Badges.Announce(ctx.newBadges)
end

ns:Listen("CHAT_MSG_SYSTEM", function(msg)
    if not Data.guild or type(msg) ~= "string" or Compat.IsSecret(msg) then return end

    local fled = false
    local winner, loser = matchKnockout(msg)
    if not winner then
        winner, loser = matchRetreat(msg)
        fled = true
    end
    if not winner or not loser then return end

    winner, loser = Compat.FullName(CleanName(winner)), Compat.FullName(CleanName(loser))
    local me = Compat.PlayerKey()
    local ctx = { health = Compat.HealthPct(), duration = Duration(), zone = Compat.ZoneName() }
    if winner == me then
        ctx.opp, ctx.won = loser, true
    elseif loser == me then
        ctx.opp, ctx.won, ctx.fled = winner, false, fled
    else
        return -- someone else's duel nearby
    end

    local e, h = Data:RecordDuel(ctx)
    if not e then return end
    ns.Sync:SendOwn()
    ns:Fire("DATA_CHANGED")
    Feedback(ctx, e, h)
end)

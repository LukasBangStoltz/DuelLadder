local _, ns = ...
local Compat, Data = ns.Compat, ns.Data

-- Badges are earned by the duelist's own addon when a duel ends (or a bet is won), stored
-- as counts in their entry, and synced like everything else. Ids are short to keep the
-- messages small; never change an id once released.
local Badges = {}
ns.Badges = Badges

local ICON = "Interface\\Icons\\"

-- TBC's classes, for Class Collector.
local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local function ClassesBeaten(e)
    local beaten = {}
    for opp, r in pairs(e.h2h) do
        local class = Data:ClassOf(opp)
        if r.w > 0 and class then beaten[class] = true end
    end
    local count = 0
    for _, class in ipairs(CLASSES) do
        if beaten[class] then count = count + 1 end
    end
    return count
end

-- check(e, ctx) runs after the duel was recorded. repeatable badges count every time.
Badges.LIST = {
    { id = "fb", name = "First Blood", icon = "Ability_Warrior_Charge",
      desc = "Win your first duel.",
      check = function(e, ctx) return ctx.won and e.w >= 1 end },
    { id = "fl", name = "Flawless", icon = "Spell_Holy_PowerWordShield", repeatable = true,
      desc = "Win with 90% or more of your health left.",
      check = function(e, ctx) return ctx.won and ctx.health and ctx.health >= 0.9 end },
    { id = "cl", name = "Clutch", icon = "Ability_Racial_BloodRage", repeatable = true,
      desc = "Win with less than 10% health left.",
      check = function(e, ctx) return ctx.won and ctx.health and ctx.health < 0.1 end },
    { id = "gs", name = "Giant Slayer", icon = "INV_Misc_Head_Dragon_01", repeatable = true,
      desc = "Beat someone 5 or more levels above you.",
      check = function(e, ctx) return ctx.won and ctx.oppLevel - ctx.myLevel >= 5 end },
    { id = "ud", name = "Underdog", icon = "Spell_Holy_SealOfMight", repeatable = true,
      desc = "Beat someone rated 150 or more above you.",
      check = function(e, ctx) return ctx.won and ctx.oppRating - (e.rating - ctx.delta) >= 150 end },
    { id = "sp", name = "Speedrun", icon = "Ability_Rogue_Sprint", repeatable = true,
      desc = "Win a duel in under 15 seconds.",
      check = function(e, ctx) return ctx.won and ctx.duration and ctx.duration < 15 end },
    { id = "ma", name = "Marathon", icon = "INV_Misc_PocketWatch_01", repeatable = true,
      desc = "Fight a duel that lasts over 2 minutes, win or lose.",
      check = function(e, ctx) return ctx.duration and ctx.duration > 120 end },
    { id = "s5", name = "Rampage", icon = "Ability_Warrior_BattleShout", repeatable = true,
      desc = "Win 5 duels in a row.",
      check = function(e, ctx) return ctx.won and e.streak == 5 end },
    { id = "s10", name = "Unstoppable", icon = "Ability_Warrior_InnerRage", repeatable = true,
      desc = "Win 10 duels in a row.",
      check = function(e, ctx) return ctx.won and e.streak == 10 end },
    { id = "sb", name = "Streak Breaker", icon = "Ability_Warrior_Sunder", repeatable = true,
      desc = "End someone's winning streak of 3 or more.",
      check = function(e, ctx) return ctx.won and ctx.oppStreak >= 3 end },
    { id = "kr", name = "Kingslayer", icon = "INV_Crown_01", repeatable = true,
      desc = "Take the crown by beating the King of the Hill.",
      check = function(e, ctx) return ctx.kingslayer end },
    { id = "de", name = "Defender", icon = "Spell_Holy_DevotionAura", repeatable = true,
      desc = "Defend the crown 5 times in a row.",
      check = function(e, ctx) return ctx.defended and e.defenses == 5 end },
    { id = "rv", name = "Bitter Rivals", icon = "Ability_Warrior_Disarm",
      desc = "Fight 10 duels against the same person.",
      check = function(e, ctx)
          local h = e.h2h[ctx.opp]
          return h and h.w + h.l >= 10
      end },
    { id = "cc", name = "Class Collector", icon = "INV_Misc_Book_09",
      desc = "Beat at least one of every class.",
      check = function(e, ctx) return ctx.won and ClassesBeaten(e) >= #CLASSES end },
    { id = "vt", name = "Veteran", icon = "INV_Shield_06",
      desc = "Fight 50 duels.",
      check = function(e) return e.w + e.l >= 50 end },
    { id = "ce", name = "Centurion", icon = "INV_Shield_05",
      desc = "Fight 100 duels.",
      check = function(e) return e.w + e.l >= 100 end },
    { id = "ch", name = "Chicken", icon = "Spell_Magic_PolymorphChicken",
      desc = "Run away from 5 duels. Bawk bawk.",
      check = function(e) return e.fled >= 5 end },
    { id = "hr", name = "High Roller", icon = "INV_Misc_Coin_02", repeatable = true,
      desc = "Win a bet of 50 gold or more.",
      check = function(e, ctx) return ctx.betWon and ctx.betWon >= 50 end },
}

Badges.BY_ID = {}
for _, badge in ipairs(Badges.LIST) do
    badge.texture = ICON .. badge.icon
    Badges.BY_ID[badge.id] = badge
end

local function MostDuelsVsOne(e)
    local most = 0
    for _, r in pairs(e.h2h) do most = math.max(most, r.w + r.l) end
    return most
end

-- How close you are to badges you don't have yet: progress(e) returns current, goal, unit.
local PROGRESS = {
    fb  = function(e) return e.w, 1, "wins" end,
    s5  = function(e) return e.best, 5, "best streak" end,
    s10 = function(e) return e.best, 10, "best streak" end,
    de  = function(e) return e.crown > 0 and e.defenses or 0, 5, "defenses" end,
    rv  = function(e) return MostDuelsVsOne(e), 10, "duels vs one person" end,
    cc  = function(e) return ClassesBeaten(e), #CLASSES, "classes beaten" end,
    vt  = function(e) return e.w + e.l, 50, "duels" end,
    ce  = function(e) return e.w + e.l, 100, "duels" end,
    ch  = function(e) return e.fled, 5, "times fled" end,
}
for id, fn in pairs(PROGRESS) do
    Badges.BY_ID[id].progress = fn
end

-- Milestone badges you can tell from your stats alone. Checked at login too, so stats from
-- before a badge existed (or from an older version of the addon) still earn it.
local REACHED = {
    fb  = function(e) return e.w >= 1 end,
    s5  = function(e) return e.best >= 5 end,
    s10 = function(e) return e.best >= 10 end,
    rv  = function(e) return MostDuelsVsOne(e) >= 10 end,
    cc  = function(e) return ClassesBeaten(e) >= #CLASSES end,
    vt  = function(e) return e.w + e.l >= 50 end,
    ce  = function(e) return e.w + e.l >= 100 end,
    ch  = function(e) return e.fled >= 5 end,
}

-- Awards milestone badges we've reached but don't have. Returns the badges earned.
function Badges:CatchUp(e)
    local earned = {}
    for _, badge in ipairs(self.LIST) do
        local reached = REACHED[badge.id]
        if reached and not e.badges[badge.id] and reached(e) then
            e.badges[badge.id] = 1
            earned[#earned + 1] = badge
        end
    end
    return earned
end

-- Checks every badge against what just happened. Returns the badges that were earned.
function Badges:Award(e, ctx)
    local earned = {}
    for _, badge in ipairs(self.LIST) do
        if (badge.repeatable or not e.badges[badge.id]) and badge.check(e, ctx) then
            e.badges[badge.id] = (e.badges[badge.id] or 0) + 1
            earned[#earned + 1] = badge
        end
    end
    return earned
end

function Badges.Count(e)
    local n = 0
    for _ in pairs(e.badges) do n = n + 1 end
    return n
end

-- "|T...|t Flawless x3" for chat and tooltips.
function Badges.Label(badge, count)
    local label = ("|T%s:14|t %s"):format(badge.texture, badge.name)
    if count and count > 1 then label = label .. " x" .. count end
    return label
end

-- Catch up on login (after the roster has loaded, so Class Collector knows everyone's class).
ns:On("GUILD_READY", function()
    C_Timer.After(5, function()
        local e = Data:MyEntry()
        if not e then return end
        local earned = Badges:CatchUp(e)
        if #earned > 0 then
            e.rev = e.rev + 1
            ns.Sync:SendOwn()
            ns:Fire("DATA_CHANGED")
            Badges.Announce(earned)
        end
    end)
end)

function Badges.Announce(list)
    if not list or #list == 0 then return end
    for _, badge in ipairs(list) do
        ns.Print("Badge earned: " .. Badges.Label(badge) .. " |cff888888- " .. badge.desc .. "|r")
    end
    Compat.PlaySound("LEVEL_UP")
end

local _, ns = ...
local Compat = ns.Compat

-- Saved data, per guild:
--   DuelLadderDB.guilds["Realm/Guild"].entries["Name-Realm"] = entry
--   DuelLadderDB.guilds["Realm/Guild"].pools[id] = betting pool (see Bets.lua)
-- Every character is its own entry, so alts show up separately. Only the owner of a
-- character changes its entry; everyone else keeps the copy with the highest rev.
-- Only characters with the addon have an entry.
local Data = {}
ns.Data = Data

Data.roster = {}
Data.rosterComplete = false

Data.START_RATING = 1500
Data.RECENT_MAX = 10       -- duels kept per character for History and bets
Data.PLACEMENT_GAMES = 5   -- duels before you get a real title

local DEFAULTS = {
    guildOnly = true,   -- only count duels against guild members
    announce = false,   -- post your wins in guild chat
    sortKey = "rating",
    sortDesc = true,
}

local function NewEntry()
    return {
        rev = 0, class = nil, level = 0, ver = "",
        w = 0, l = 0, fled = 0, streak = 0, best = 0, last = 0,
        rating = Data.START_RATING, crown = 0, defenses = 0,
        h2h = {}, badges = {}, recent = {},
    }
end

-- Fills in fields added in later versions.
local function Upgrade(e)
    for k, v in pairs(NewEntry()) do
        if e[k] == nil then e[k] = v end
    end
end

function Data:Init()
    DuelLadderDB = DuelLadderDB or {}
    local db = DuelLadderDB
    db.version = 2
    db.settings = db.settings or {}
    for k, v in pairs(DEFAULTS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end
    db.settings.minimap = db.settings.minimap or {} -- LibDBIcon stores position and hidden state here
    db.guilds = db.guilds or {}
    for _, guild in pairs(db.guilds) do
        guild.entries = guild.entries or {}
        guild.pools = guild.pools or {}
        guild.poolAlias = guild.poolAlias or {}
        guild.betSeen = guild.betSeen or {}
        for _, e in pairs(guild.entries) do Upgrade(e) end
    end
    -- Characters on this account, so the UI can mark them.
    db.myChars = db.myChars or {}
    db.myChars[Compat.PlayerKey()] = true

    self.db = db
    self.settings = db.settings
end

function Data:SetGuild(guildKey)
    self.guildKey = guildKey
    if not guildKey then
        self.guild = nil
        return false
    end
    self.db.guilds[guildKey] = self.db.guilds[guildKey] or { entries = {}, pools = {}, poolAlias = {}, betSeen = {} }
    self.guild = self.db.guilds[guildKey]
    self:TouchMyEntry()
    return true
end

function Data:Entries()
    return self.guild and self.guild.entries or {}
end

function Data:MyEntry()
    return self:Entries()[Compat.PlayerKey()]
end

-- Makes sure our own entry exists and has our current class, level and addon version.
-- Returns true when it changed (and its rev was bumped).
function Data:TouchMyEntry()
    if not self.guild then return false end
    local key = Compat.PlayerKey()
    local e = self.guild.entries[key]
    if not e then
        e = NewEntry()
        self.guild.entries[key] = e
    end
    local _, class = UnitClass("player")
    local level = UnitLevel("player")
    if e.class ~= class or e.level ~= level or e.ver ~= ns.VERSION or e.rev == 0 then
        e.class, e.level, e.ver = class, level, ns.VERSION
        e.rev = e.rev + 1
        return true
    end
    return false
end

function Data:IsGuildMember(key)
    if next(self.roster) == nil then return true end -- roster not loaded yet: benefit of the doubt
    return self.roster[key] ~= nil
end

function Data:IsOnline(key)
    if key == Compat.PlayerKey() then return true end
    local r = self.roster[key]
    return r ~= nil and r.online
end

function Data:ClassOf(key)
    local e = self:Entries()[key]
    if e and e.class then return e.class end
    local r = self.roster[key]
    return r and r.class
end

function Data:LevelOf(key)
    local e = self:Entries()[key]
    if e and e.level and e.level > 0 then return e.level end
    local r = self.roster[key]
    return r and r.level
end

-- Members shown in the UI: characters with the addon who are still in the guild
-- (once we have the full roster).
function Data:Members()
    local list = {}
    for key, e in pairs(self:Entries()) do
        if not self.rosterComplete or self.roster[key] then
            list[#list + 1] = key
        end
    end
    return list
end

------------------------------------------------------------------------
-- Rating, titles and the crown
------------------------------------------------------------------------

local TITLES = {
    { min = 1800, name = "Warlord",   color = "ff8000" },
    { min = 1700, name = "Gladiator", color = "a335ee" },
    { min = 1600, name = "Champion",  color = "0070dd" },
    { min = 1500, name = "Duelist",   color = "1eff00" },
    { min = 1400, name = "Squire",    color = "ffffff" },
    { min = -math.huge, name = "Peasant", color = "9d9d9d" },
}
Data.TITLES = TITLES

-- Returns the title name and a colored version of it.
function Data.Title(e)
    if e.w + e.l < Data.PLACEMENT_GAMES then
        return "Recruit", "|cff808080Recruit|r"
    end
    for _, t in ipairs(TITLES) do
        if e.rating >= t.min then
            return t.name, ("|cff%s%s|r"):format(t.color, t.name)
        end
    end
end

-- Chess-style rating change: beating someone rated above you is worth more.
function Data.RatingChange(rating, oppRating, won, games)
    local k = games <= 10 and 40 or 32
    local expected = 1 / (1 + 10 ^ ((oppRating - rating) / 400))
    return math.floor(k * ((won and 1 or 0) - expected) + 0.5)
end

-- King of the Hill: whoever claimed the crown most recently. Beating the king takes it.
function Data:King()
    local king, since
    for key, e in pairs(self:Entries()) do
        if e.crown > 0 and (not since or e.crown > since) then
            king, since = key, e.crown
        end
    end
    return king, since
end

-- If someone else claimed the crown after us, our claim is stale: drop it.
-- Returns true if our entry changed.
function Data:CheckCrown()
    local me = self:MyEntry()
    if not me or me.crown == 0 then return false end
    if self:King() ~= Compat.PlayerKey() then
        me.crown, me.defenses = 0, 0
        me.rev = me.rev + 1
        return true
    end
    return false
end

------------------------------------------------------------------------
-- Recording our own duels
------------------------------------------------------------------------

-- ctx = { opp, won, fled, health (0..1 or nil), duration (seconds or nil), zone }
-- Fills ctx with what happened (rating change, crown, new badges) and returns our
-- entry and head-to-head record, or nil if the duel wasn't counted.
function Data:RecordDuel(ctx)
    if not self.guild then return nil end
    local opp = ctx.opp
    if self.settings.guildOnly and not self:IsGuildMember(opp) then
        ns.Print(Compat.DisplayName(opp) .. " isn't in your guild, so that duel wasn't counted. (|cffffffff/duels guildonly|r to change)")
        return nil
    end
    self:TouchMyEntry()
    local me = Compat.PlayerKey()
    local e = self.guild.entries[me]
    local oe = self.guild.entries[opp]
    local now = Compat.Now()

    -- What we knew about the opponent before the duel
    ctx.oppRating = oe and oe.rating or Data.START_RATING
    ctx.oppStreak = oe and oe.streak or 0
    ctx.oppLevel = self:LevelOf(opp) or 0
    ctx.myLevel = UnitLevel("player")
    ctx.titleBefore = Data.Title(e)
    local king = self:King()
    ctx.kingBefore = king

    local h = e.h2h[opp] or { w = 0, l = 0 }
    e.h2h[opp] = h
    if ctx.won then
        e.w, h.w = e.w + 1, h.w + 1
        e.streak = e.streak > 0 and e.streak + 1 or 1
        if e.streak > e.best then e.best = e.streak end
    else
        e.l, h.l = e.l + 1, h.l + 1
        if ctx.fled then e.fled = e.fled + 1 end
        e.streak = e.streak < 0 and e.streak - 1 or -1
    end

    ctx.delta = Data.RatingChange(e.rating, ctx.oppRating, ctx.won, e.w + e.l)
    e.rating = e.rating + ctx.delta

    if ctx.won then
        if king == me then
            e.defenses = e.defenses + 1
            ctx.defended = true
        elseif king == nil or king == opp then
            e.crown, e.defenses = now, 0
            ctx.tookCrown = true
            ctx.kingslayer = king == opp
        end
    elseif e.crown > 0 then
        e.crown, e.defenses = 0, 0
        ctx.lostCrown = true
    end

    table.insert(e.recent, 1, {
        t = now, o = opp, r = ctx.won and "W" or (ctx.fled and "F" or "L"),
        d = ctx.delta, z = ctx.zone or "",
        du = ctx.duration and math.floor(ctx.duration + 0.5) or nil, -- seconds, for when it started
    })
    while #e.recent > Data.RECENT_MAX do table.remove(e.recent) end
    e.last = now

    ctx.newBadges = ns.Badges:Award(e, ctx)
    ctx.titleAfter = Data.Title(e)
    e.rev = e.rev + 1
    return e, h
end

-- Takes an entry received from someone else. Returns true if it replaced what we had.
-- This also restores our own stats if our SavedVariables were lost.
function Data:ApplyRemote(key, e)
    if not self.guild then return false end
    local cur = self.guild.entries[key]
    if cur and cur.rev >= e.rev then return false end
    self.guild.entries[key] = e
    return true
end

-- When a recorded duel started. Without a known length we assume a minute, so bets can't be
-- cancelled in the last minute before a result.
Data.UNKNOWN_DUEL_LENGTH = 60
function Data.DuelStart(r)
    return r.t - (r.du or Data.UNKNOWN_DUEL_LENGTH)
end

function Data:RefreshRoster()
    self.roster, self.rosterComplete = Compat.GetGuildRoster()
end

------------------------------------------------------------------------
-- Wire format (fields separated by ";"):
--   2;class;version;rev;level;w;l;fled;streak;best;last;rating;crown;defenses;
--   h2h (Opp-Realm=w/l,...);badges (id=count,...);recent (end:Opp-Realm:W|L|F:delta:duration:zone,...)
-- Version 2 had no duration in recent; we still read it.
------------------------------------------------------------------------

local FIELDS = { "rev", "level", "w", "l", "fled", "streak", "best", "last", "rating", "crown", "defenses" }
local FORMAT_VERSION = "3"
local LIST_START = #FIELDS + 4 -- index of the h2h field

-- Characters that would break the format.
local function Clean(s)
    return (tostring(s or ""):gsub("[;,:=%^|/]", ""))
end

function Data.Serialize(e)
    local parts = { FORMAT_VERSION, e.class or "", Clean(e.ver) }
    for _, f in ipairs(FIELDS) do
        parts[#parts + 1] = tostring(e[f] or 0)
    end
    local list = {}
    for opp, r in pairs(e.h2h) do
        list[#list + 1] = opp .. "=" .. r.w .. "/" .. r.l
    end
    table.sort(list)
    parts[#parts + 1] = table.concat(list, ",")

    list = {}
    for id, count in pairs(e.badges) do
        list[#list + 1] = id .. "=" .. count
    end
    table.sort(list)
    parts[#parts + 1] = table.concat(list, ",")

    list = {}
    for _, r in ipairs(e.recent) do
        list[#list + 1] = ("%d:%s:%s:%d:%d:%s"):format(r.t, r.o, r.r, r.d, r.du or -1, Clean(r.z))
    end
    parts[#parts + 1] = table.concat(list, ",")
    return table.concat(parts, ";")
end

function Data.Deserialize(s)
    local parts = {}
    for field in (s .. ";"):gmatch("([^;]*);") do
        parts[#parts + 1] = field
    end
    local version = parts[1]
    if (version ~= FORMAT_VERSION and version ~= "2") or #parts ~= LIST_START + 2 then return nil end

    local e = NewEntry()
    e.class = parts[2]:match("^%u+$")
    e.ver = parts[3]
    for i, f in ipairs(FIELDS) do
        local n = tonumber(parts[i + 3])
        if not n then return nil end
        e[f] = n
    end
    for opp, w, l in parts[LIST_START]:gmatch("([^,=]+)=(%d+)/(%d+)") do
        e.h2h[opp] = { w = tonumber(w), l = tonumber(l) }
    end
    for id, count in parts[LIST_START + 1]:gmatch("([^,=]+)=(%d+)") do
        e.badges[id] = tonumber(count)
    end
    if version == "2" then
        for t, o, r, d, z in parts[LIST_START + 2]:gmatch("(%d+):([^:,]+):([WLF]):(%-?%d+):([^,]*)") do
            e.recent[#e.recent + 1] = { t = tonumber(t), o = o, r = r, d = tonumber(d), z = z }
        end
    else
        for t, o, r, d, du, z in parts[LIST_START + 2]:gmatch("(%d+):([^:,]+):([WLF]):(%-?%d+):(%-?%d+):([^,]*)") do
            du = tonumber(du)
            e.recent[#e.recent + 1] = { t = tonumber(t), o = o, r = r, d = tonumber(d), z = z, du = du >= 0 and du or nil }
        end
    end
    return e
end

ns:Listen("GUILD_ROSTER_UPDATE", function()
    if not Data.db then return end
    Data:RefreshRoster()
    ns:Fire("DATA_CHANGED")
end)

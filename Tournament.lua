local _, ns = ...
local Compat, Data = ns.Compat, ns.Data

-- Tournaments: a knockout bracket of up to 16 guild members.
--
-- Anyone can host one. Members join while sign-ups are open; the host presses Start, which
-- seeds the bracket by ladder rating (the top seeds get the byes) and locks it. From then on
-- the duels decide it: a match is won by the first duel between its two players that starts
-- after the match opened (once both players were known). The final is best of three. Duels
-- from before a match opened never count, and tournament duels count for the ladder like any
-- other. The host can award a walkover when someone doesn't show up.
--
-- Every client works the bracket out the same way from the tournament and the duel history.
-- Duels that decide matches are copied into the tournament ("games"), because a character
-- only keeps its last 10 duels. Only the winner's copy of a duel is used, so each duel is one
-- game.
--
-- Betting: every match has a pot, open until its first duel starts (a walkover voids it), and
-- there's a champion pot, open until the host presses Start. They work like the public pots in
-- Bets.lua: the winners split the losers' money by how much they bet, and players can only bet
-- on themselves.
--
-- Who owns what, for merging copies: the host owns the name, start, seeds, walkovers and the
-- cancel (the copy with the higher hrev wins); each member owns their join; each bettor owns
-- their bets; games and payment confirmations are only ever added.
local T = {}
ns.Tournament = T

T.MAX_PLAYERS = 16
T.MIN_PLAYERS = 3
T.CHAMPION = "W"            -- id of the champion pot; match ids are "round.slot", e.g. "2.1"
T.KEEP_DAYS = 30            -- finished tournaments are forgotten after this
local MAX_GAMES = 8         -- games kept per match (a best of three needs at most three)
local NAME_MAX = 32
local NEWS_SECONDS = 2 * 86400

local counter = 0

local function Me() return Compat.PlayerKey() end

function T:All()
    local guild = Data.guild
    if not guild then return {} end
    guild.tourneys = guild.tourneys or {}
    return guild.tourneys
end

function T.Started(t)
    return t.start > 0
end

-- "signup", "running", "finished" or "cancelled".
function T.Status(t, b)
    if t.cancel then return "cancelled" end
    if not T.Started(t) then return "signup" end
    b = b or T.Bracket(t)
    return b.champion and "finished" or "running"
end

-- The tournament to show: the newest one that isn't over, otherwise the newest.
function T:Latest()
    local best, bestLive
    for _, t in pairs(self:All()) do
        local status = T.Status(t)
        local live = status == "signup" or status == "running"
        if not best or (live and not bestLive) or (live == bestLive and t.t > best.t) then
            best, bestLive = t, live
        end
    end
    return best
end

function T.Rating(key)
    local e = Data:Entries()[key]
    return e and e.rating or Data.START_RATING
end

-- Who's in, in the order they joined, and the waiting list (everyone past MAX_PLAYERS).
-- Once it has started, it's the seeds.
function T.Entrants(t)
    if T.Started(t) then return t.seeds, {} end
    local list = {}
    for key, j in pairs(t.joins) do
        if not j.out then list[#list + 1] = key end
    end
    table.sort(list, function(x, y)
        local tx, ty = t.joins[x].t, t.joins[y].t
        if tx ~= ty then return tx < ty end
        return x < y
    end)
    local waiting = {}
    while #list > T.MAX_PLAYERS do table.insert(waiting, 1, table.remove(list)) end
    return list, waiting
end

function T.IsIn(t, key)
    for _, k in ipairs((T.Entrants(t))) do
        if k == key then return true end
    end
    return false
end

------------------------------------------------------------------------
-- The bracket
------------------------------------------------------------------------

-- Seed numbers in bracket order, so 1 and 2 can only meet in the final (8: 1 8 4 5 2 7 3 6).
local function SeedOrder(size)
    local order = { 1 }
    while #order < size do
        local n, nextOrder = #order * 2, {}
        for _, seed in ipairs(order) do
            nextOrder[#nextOrder + 1] = seed
            nextOrder[#nextOrder + 1] = n + 1 - seed
        end
        order = nextOrder
    end
    return order
end

function T.RoundName(r, rounds)
    local left = rounds - r
    if left == 0 then return "Final" end
    if left == 1 then return "Semifinal" end
    if left == 2 then return "Quarterfinal" end
    return ("Round of %d"):format(2 ^ (left + 1))
end

-- Plays a match's games in order until someone has enough wins, or takes the walkover.
local function Decide(t, m)
    local wo = t.wo[m.id]
    local wins = { [m.a] = 0, [m.b] = 0 }
    m.played = {}
    for _, g in ipairs(t.games[m.id] or {}) do
        if m.winner then break end
        local inMatch = (g.w == m.a and g.o == m.b) or (g.w == m.b and g.o == m.a)
        if inMatch and g.s > m.open and (not wo or g.s < wo.t) then
            m.lock = m.lock or g.s -- betting closes when the first duel starts
            wins[g.w] = wins[g.w] + 1
            m.played[#m.played + 1] = g
            if wins[g.w] >= m.need then m.winner, m.finish = g.w, g.t end
        end
    end
    if not m.winner and wo and (wo.w == m.a or wo.w == m.b) then
        m.winner, m.finish, m.walkover = wo.w, wo.t, true
    end
    m.wa, m.wb = wins[m.a], wins[m.b]
end

-- Works out the whole bracket. Returns { size, rounds, rows[r][i] = match, byId, seedOf,
-- champion }. A match is { id, r, i, a, b, seedA, seedB, need (wins), open (when both
-- players were known), live (being played), lock (first duel started), winner, loser,
-- finish, wa, wb, played (games that counted), bye, walkover }.
function T.Bracket(t)
    local seeds = t.seeds
    local size, rounds = 2, 1
    while size < #seeds do size, rounds = size * 2, rounds + 1 end
    local order = SeedOrder(size)
    local b = { size = size, rounds = rounds, rows = {}, byId = {}, seedOf = {} }
    for i, key in ipairs(seeds) do b.seedOf[key] = i end

    for r = 1, rounds do
        local row = {}
        b.rows[r] = row
        for i = 1, size / 2 ^ r do
            local m = { id = r .. "." .. i, r = r, i = i, need = r == rounds and 2 or 1 }
            if r == 1 then
                m.a, m.b = seeds[order[2 * i - 1]], seeds[order[2 * i]]
                if m.a and m.b then
                    m.open = t.start
                elseif m.a or m.b then
                    m.winner, m.finish, m.bye = m.a or m.b, t.start, true
                end
            else
                local x, y = b.rows[r - 1][2 * i - 1], b.rows[r - 1][2 * i]
                m.a, m.b = x.winner, y.winner
                if m.a and m.b then m.open = math.max(x.finish, y.finish) end
            end
            m.seedA, m.seedB = b.seedOf[m.a], b.seedOf[m.b]
            if m.open then
                Decide(t, m)
                m.live = not m.winner and not t.cancel
            end
            if m.winner and not m.bye then m.loser = m.winner == m.a and m.b or m.a end
            row[i] = m
            b.byId[m.id] = m
        end
    end
    b.final = b.rows[rounds][1]
    b.champion = b.final.winner
    return b
end

-- The live match a player is in, if any.
function T.CurrentMatch(b, key)
    for _, m in pairs(b.byId) do
        if m.live and (m.a == key or m.b == key) then return m end
    end
    return nil
end

-- Adds a game to a match unless it's already there. Returns true if it was added.
local function AddGame(t, mid, g)
    local list = t.games[mid]
    if not list then
        list = {}
        t.games[mid] = list
    end
    for _, x in ipairs(list) do
        if x.t == g.t and x.w == g.w then return false end
    end
    if #list >= MAX_GAMES and g.s >= list[#list].s then return false end
    list[#list + 1] = g
    table.sort(list, function(x, y)
        if x.s ~= y.s then return x.s < y.s end
        return x.w < y.w
    end)
    for i = #list, MAX_GAMES + 1, -1 do list[i] = nil end
    return true
end

-- Copies the duels that decide live matches into the tournament. Deciding a match opens the
-- next one, so keep going until nothing new turns up. Returns true if anything was added.
local function Collect(t)
    if not T.Started(t) or t.cancel then return false end
    local entries = Data:Entries()
    local added = false
    for _ = 1, 8 do
        local found = false
        for _, m in pairs(T.Bracket(t).byId) do
            if m.live then
                for _, side in ipairs({ { m.a, m.b }, { m.b, m.a } }) do
                    local e = entries[side[1]]
                    for _, r in ipairs(e and e.recent or {}) do
                        if r.o == side[2] and r.r == "W" then
                            local s = Data.DuelStart(r)
                            if s > m.open and AddGame(t, m.id, { t = r.t, s = s, w = side[1], o = side[2] }) then
                                found = true
                            end
                        end
                    end
                end
            end
        end
        if not found then break end
        added = true
    end
    return added
end

------------------------------------------------------------------------
-- Pots
------------------------------------------------------------------------

local function PotFor(t, mid)
    local pot = t.pots[mid]
    if not pot then
        pot = { stakes = {}, paid = {} }
        t.pots[mid] = pot
    end
    return pot
end

local EMPTY_POT = { stakes = {}, paid = {} }

-- A pot as Bets.lua sees a pool ({ stakes, paid, res = who won, rs = when betting closed }),
-- plus its state: "waiting" (match not ready yet), "open", "locked" (betting closed, not
-- decided yet), "void", "settled" (payments outstanding) or "paid".
function T.Pot(t, mid, b)
    if T.Started(t) then b = b or T.Bracket(t) end
    local pot = t.pots[mid] or EMPTY_POT
    local view = { stakes = pot.stakes, paid = pot.paid, mid = mid }
    local state
    if mid == T.CHAMPION then
        if not T.Started(t) then
            state = t.cancel and "void" or "open"
        else
            -- Bets on people who didn't make the bracket don't count.
            local stakes = {}
            for key, s in pairs(pot.stakes) do
                if b.seedOf[s.side] then stakes[key] = s end
            end
            view.stakes, view.rs, view.res = stakes, t.start, b.champion
            if not b.champion then state = t.cancel and "void" or "locked" end
        end
    else
        local m = b and b.byId[mid]
        view.match = m
        if not m or not m.open then
            state = t.cancel and "void" or "waiting"
        elseif m.walkover then
            state = "void"
        elseif m.winner then
            view.res, view.rs = m.winner, m.lock
        elseif t.cancel then
            state = "void"
        else
            state = m.lock and "locked" or "open"
        end
    end
    if not state then
        state = "void"
        for _, x in ipairs(ns.Bets.Transfers(view)) do
            if not x.paid then
                state = "settled"
                break
            end
            state = "paid"
        end
    end
    view.state = state
    return view
end

-- Copper on each side of a pot that counts right now: { [side] = { amt, count } }.
function T.Sides(view)
    local cutoff = view.rs or (view.match and view.match.lock) or math.huge
    local sides = {}
    for _, s in pairs(view.stakes) do
        if s.t < cutoff and (not s.cancel or s.cancel >= cutoff) then
            local side = sides[s.side] or { amt = 0, count = 0 }
            side.amt, side.count = side.amt + s.amt, side.count + 1
            sides[s.side] = side
        end
    end
    return sides
end

-- What you'd get back in total if `side` wins and you add `copper` to it.
function T.PreviewReturn(view, side, copper)
    local mine, others = 0, 0
    for key, x in pairs(T.Sides(view)) do
        if key == side then mine = x.amt else others = others + x.amt end
    end
    if others == 0 then return copper end
    return copper + math.floor(others * copper / (mine + copper))
end

-- The match pots and the champion pot, as views.
function T.Pots(t)
    local b = T.Started(t) and T.Bracket(t)
    local list = { T.Pot(t, T.CHAMPION, b) }
    if b then
        for r = 1, b.rounds do
            for _, m in ipairs(b.rows[r]) do
                if m.open then list[#list + 1] = T.Pot(t, m.id, b) end
            end
        end
    end
    return list
end

------------------------------------------------------------------------
-- Actions (our own)
------------------------------------------------------------------------

local function Changed(t)
    ns.Sync:SendTourney(t.id, true)
    T:Update()
end

local function Clean(s)
    s = tostring(s or ""):gsub("[;,:=%^|/\r\n]", ""):match("^%s*(.-)%s*$")
    if #s > NAME_MAX then
        s = s:sub(1, NAME_MAX):gsub("[\192-\255][\128-\191]*$", "") -- don't cut a letter in half
    end
    return s
end

local function Guild(msg)
    if IsInGuild() then SendChatMessage(msg, "GUILD") end
end

function T:Create(name)
    if not Data.guild then return nil, "You're not in a guild." end
    local latest = self:Latest()
    local status = latest and T.Status(latest)
    if status == "signup" or status == "running" then
        return nil, ("%s is still going. It has to finish (or be cancelled) before a new one starts."):format(latest.name)
    end
    local me, now = Me(), Compat.Now()
    name = Clean(name)
    if name == "" then name = Compat.ShortName(me) .. "'s Tournament" end
    counter = counter + 1
    local t = {
        id = ("%s#%d#%d"):format(me, now, counter), host = me, name = name, t = now, hrev = 1,
        start = 0, seeds = {}, wo = {}, joins = {}, games = {}, pots = {},
    }
    self:All()[t.id] = t
    Guild(("[DuelLadder] %s is hosting a duel tournament: %s. Sign up in /duels > Tournament!"):format(
        Compat.ShortName(me), name))
    Changed(t)
    return t.id
end

local function Get(id)
    local t = T:All()[id]
    if not t then return nil, "Unknown tournament." end
    return t
end

function T:Join(id)
    local t, err = Get(id)
    if not t then return nil, err end
    if T.Status(t) ~= "signup" then return nil, "Sign-ups for that tournament are closed." end
    local me = Me()
    local j = t.joins[me]
    if j and not j.out then return nil, "You've already joined." end
    if #T.Entrants(t) >= T.MAX_PLAYERS then
        return nil, ("It's full (%d players)."):format(T.MAX_PLAYERS)
    end
    t.joins[me] = { t = math.max(Compat.Now(), j and j.t + 1 or 0), out = false }
    Changed(t)
    return true
end

function T:Leave(id)
    local t, err = Get(id)
    if not t then return nil, err end
    if T.Status(t) ~= "signup" then return nil, "It has started, so you can't leave. The host can give your opponent a walkover." end
    local me = Me()
    local j = t.joins[me]
    if not j or j.out then return nil, "You haven't joined." end
    t.joins[me] = { t = math.max(Compat.Now(), j.t + 1), out = true }
    Changed(t)
    return true
end

-- Host only: seeds the bracket by rating (ties drawn at random) and locks it.
function T:Start(id)
    local t, err = Get(id)
    if not t then return nil, err end
    if t.host ~= Me() then return nil, "Only the host can start the tournament." end
    if T.Status(t) ~= "signup" then return nil, "It has already started." end
    local seeds = {}
    for i, key in ipairs((T.Entrants(t))) do seeds[i] = key end
    if #seeds < T.MIN_PLAYERS then
        return nil, ("You need at least %d players to start (%d joined)."):format(T.MIN_PLAYERS, #seeds)
    end
    local draw = {}
    for _, key in ipairs(seeds) do draw[key] = math.random() end
    table.sort(seeds, function(x, y)
        local rx, ry = T.Rating(x), T.Rating(y)
        if rx ~= ry then return rx > ry end
        return draw[x] < draw[y]
    end)
    t.seeds, t.start, t.hrev = seeds, Compat.Now(), t.hrev + 1
    Guild(("[DuelLadder] The %s tournament has started: %d players, top seed %s. Good luck!"):format(
        t.name, #seeds, Compat.ShortName(seeds[1])))
    Changed(t)
    return true
end

function T:Cancel(id)
    local t, err = Get(id)
    if not t then return nil, err end
    if t.host ~= Me() then return nil, "Only the host can cancel the tournament." end
    local status = T.Status(t)
    if status ~= "signup" and status ~= "running" then return nil, "It's already over." end
    t.cancel, t.hrev = Compat.Now(), t.hrev + 1
    Changed(t)
    return true
end

-- Host only: `winner` goes through without a duel (their opponent didn't show up).
function T:Walkover(id, mid, winner)
    local t, err = Get(id)
    if not t then return nil, err end
    if t.host ~= Me() then return nil, "Only the host can award a walkover." end
    local m = T.Status(t) == "running" and T.Bracket(t).byId[mid]
    if not m or not m.live then return nil, "That match isn't being played." end
    if winner ~= m.a and winner ~= m.b then return nil, "Pick one of the two players." end
    t.wo[mid] = { w = winner, t = Compat.Now() }
    t.hrev = t.hrev + 1
    Changed(t)
    return true
end

function T:Bet(id, mid, side, copper)
    local t, err = Get(id)
    if not t then return nil, err end
    local me = Me()
    local view = T.Pot(t, mid)
    if view.state ~= "open" then
        return nil, mid == T.CHAMPION and "Bets on the champion closed when the tournament started."
            or "Betting on that match is closed."
    end
    if mid == T.CHAMPION then
        if not T.IsIn(t, side) then return nil, "Pick someone who's in the tournament." end
        if T.IsIn(t, me) and side ~= me then return nil, "You're playing, so you can only bet on yourself to win." end
    else
        local m = view.match
        if side ~= m.a and side ~= m.b then return nil, "Pick one of the two players." end
        if (me == m.a or me == m.b) and side ~= me then return nil, "You can't bet against yourself." end
    end
    local pot = PotFor(t, mid)
    local stake = pot.stakes[me]
    if stake then
        return nil, stake.cancel and "You cancelled your bet on this, so you can't bet on it again."
            or "You already have a bet on this. Cancel it first if you want to change it."
    end
    local amount
    amount, err = ns.Bets.CheckAmount(copper)
    if not amount then return nil, err end
    pot.stakes[me] = { side = side, amt = amount, t = Compat.Now() }
    Changed(t)
    return true
end

function T:CancelBet(id, mid)
    local t, err = Get(id)
    if not t then return nil, err end
    local stake = t.pots[mid] and t.pots[mid].stakes[Me()]
    if not stake or stake.cancel then return nil, "You don't have a bet there to cancel." end
    if T.Pot(t, mid).state ~= "open" then return nil, "Betting has closed, so your bet stands." end
    stake.cancel = Compat.Now()
    Changed(t)
    return true
end

-- The receiver confirms they got a payment.
function T:MarkPaid(id, mid, from)
    local t, err = Get(id)
    if not t then return nil, err end
    for _, x in ipairs(ns.Bets.Transfers(T.Pot(t, mid))) do
        if x.from == from and x.to == Me() then
            PotFor(t, mid).paid[from .. ">" .. x.to] = true
            Changed(t)
            return true
        end
    end
    return nil, "Only the person being paid can confirm a payment."
end

-- Pays what we owe `to` from a pot (fills in a trade or mail, like a bet payment).
function T:Pay(id, mid, to)
    local t = self:All()[id]
    if not t then return end
    for _, x in ipairs(ns.Bets.Transfers(T.Pot(t, mid))) do
        if x.from == Me() and x.to == to and not x.paid then
            ns.Bets:SendMoney(to, x.copper, "DuelLadder tournament bet")
            return
        end
    end
end

------------------------------------------------------------------------
-- News, badges and keeping up to date
------------------------------------------------------------------------

local function Seen(id)
    local guild = Data.guild
    guild.tourneySeen = guild.tourneySeen or {}
    guild.tourneySeen[id] = guild.tourneySeen[id] or {}
    return guild.tourneySeen[id]
end

local function Fresh(time)
    return time ~= nil and Compat.Now() - time < NEWS_SECONDS
end

local function Short(key) return Compat.DisplayName(key) end

-- Tells us what happened, once each. What we've been told is kept per character, not synced.
local function Notify(t)
    local seen, me = Seen(t.id), Me()
    local name = "|cffffd100" .. t.name .. "|r"
    if not seen.created then
        seen.created = true
        if t.host ~= me and not T.Started(t) and not t.cancel and Fresh(t.t) then
            ns.Print(("%s is hosting a duel tournament, %s! Open |cffffffff/duels|r > Tournament to join."):format(Short(t.host), name))
            Compat.PlaySound("READY_CHECK")
        end
    end
    if t.cancel then
        if not seen.cancel then
            seen.cancel = true
            if t.host ~= me and Fresh(t.cancel) then ns.Print(name .. " was cancelled by the host.") end
        end
        return
    end
    if not T.Started(t) then return end

    local b = T.Bracket(t)
    if not seen.start then
        seen.start = true
        if Fresh(t.start) then
            local mine = b.seedOf[me] and (" You're seed |cffffffff#%d|r."):format(b.seedOf[me]) or ""
            ns.Print(("%s has started with %d players!%s"):format(name, #t.seeds, mine))
        end
    end
    for r = 1, b.rounds do
        for _, m in ipairs(b.rows[r]) do
            local round = T.RoundName(m.r, b.rounds)
            if m.live and (m.a == me or m.b == me) and not seen["o" .. m.id] then
                seen["o" .. m.id] = true
                if Fresh(m.open) then
                    local opp = m.a == me and m.b or m.a
                    local how = m.need > 1 and "Best of three: first to two wins." or "Your next duel against them decides it."
                    ns.Print(("|cffffd100%s:|r you vs %s in %s. %s"):format(round, Short(opp), name, how))
                    Compat.PlaySound("READY_CHECK")
                end
            end
            if m.winner and not m.bye and not seen["d" .. m.id] then
                seen["d" .. m.id] = true
                if Fresh(m.finish) then
                    if m.walkover then
                        ns.Print(("%s %s: %s goes through, %s didn't show (walkover)."):format(name, round, Short(m.winner), Short(m.loser)))
                    else
                        local score = m.need > 1 and (" %d - %d"):format(math.max(m.wa, m.wb), math.min(m.wa, m.wb)) or ""
                        ns.Print(("%s %s: %s beat %s%s."):format(name, round, Short(m.winner), Short(m.loser), score))
                        if m.winner == me and m.r < b.rounds and Data.settings.announce then
                            Guild(("[DuelLadder] %s beat %s in the %s %s."):format(
                                Compat.ShortName(me), Compat.ShortName(m.loser), t.name, round:lower()))
                        end
                    end
                end
            end
        end
    end
    if b.champion and not seen.champion then
        seen.champion = true
        if Fresh(b.final.finish) then
            ns.Print(("|TInterface\\GroupFrame\\UI-Group-LeaderIcon:0|t |cffffd100%s wins %s!|r"):format(Short(b.champion), t.name))
            Compat.PlaySound("LEVEL_UP")
            if b.champion == me then
                Guild(("[DuelLadder] %s wins the %s tournament!"):format(Compat.ShortName(me), t.name))
            end
        end
    end

    -- Our winnings and losses.
    for _, view in ipairs(T.Pots(t)) do
        local key = "p" .. view.mid
        if view.res and not seen[key] then
            seen[key] = true
            local net = ns.Bets.Payouts(view)
            local mine = net and net[me]
            if mine and Fresh(view.rs) then
                local what = view.mid == T.CHAMPION and "the champion" or "a tournament match"
                if mine > 0 then
                    ns.Print(("|cff20ff20You won %s|r on %s! Open |cffffffff/duels|r > Tournament > Bets to see who pays you."):format(
                        Compat.MoneyText(mine), what))
                else
                    ns.Print(("|cffff4040You lost %s|r on %s. Pay with the Pay button in |cffffffff/duels|r > Tournament > Bets."):format(
                        Compat.MoneyText(-mine), what))
                end
            end
        end
    end
end

-- Tournament badges are counted from the tournaments we know (like High Roller), so a wiped
-- SavedVariables can't award them twice.
local function UpdateBadges()
    local e = Data:MyEntry()
    if not e then return end
    local me = Me()
    local counts = { tc = 0, tf = 0, ts = 0 }
    for _, t in pairs(T:All()) do
        if T.Started(t) and not t.cancel then
            local b = T.Bracket(t)
            if b.champion == me then counts.tc = counts.tc + 1 end
            if b.final.a == me or b.final.b == me then counts.tf = counts.tf + 1 end
            for _, m in pairs(b.byId) do
                if m.winner == me and m.loser == t.seeds[1] and not m.walkover then counts.ts = counts.ts + 1 end
            end
        end
    end
    local earned = {}
    for id, n in pairs(counts) do
        if n > (e.badges[id] or 0) then
            e.badges[id] = n
            earned[#earned + 1] = ns.Badges.BY_ID[id]
        end
    end
    if #earned > 0 then
        e.rev = e.rev + 1
        ns.Sync:SendOwn()
        ns.Badges.Announce(earned)
        ns:Fire("DATA_CHANGED")
    end
end

-- Picks up decided matches, tells us about them and refreshes the window.
function T:Update()
    if not Data.guild then return end
    for id, t in pairs(self:All()) do
        if Collect(t) then ns.Sync:SendTourney(id) end
        Notify(t)
    end
    UpdateBadges()
    ns:Fire("TOURNEY_CHANGED")
end

-- Forgets old tournaments once everything in them is paid.
function T:Prune()
    local cutoff = Compat.Now() - T.KEEP_DAYS * 86400
    local all = self:All()
    for id, t in pairs(all) do
        local status = T.Status(t)
        if (status == "finished" or status == "cancelled") and (t.cancel or t.start) < cutoff then
            local unpaid = false
            for _, view in ipairs(T.Pots(t)) do
                if view.state == "settled" then unpaid = true end
            end
            if not unpaid then
                all[id] = nil
                if Data.guild.tourneySeen then Data.guild.tourneySeen[id] = nil end
            end
        end
    end
end

------------------------------------------------------------------------
-- Merging and wire format
------------------------------------------------------------------------

-- Merges a copy from someone else into ours. Returns true if ours changed.
function T:Merge(r)
    local all = self:All()
    local t = all[r.id]
    if not t then
        all[r.id] = r
        return true
    end
    local changed = false
    if r.hrev > t.hrev then
        t.name, t.hrev, t.start, t.seeds, t.wo, t.cancel = r.name, r.hrev, r.start, r.seeds, r.wo, r.cancel
        changed = true
    end
    for key, j in pairs(r.joins) do
        local mine = t.joins[key]
        if not mine or j.t > mine.t then
            t.joins[key] = j
            changed = true
        end
    end
    for mid, list in pairs(r.games) do
        for _, g in ipairs(list) do
            if AddGame(t, mid, g) then changed = true end
        end
    end
    for mid, theirs in pairs(r.pots) do
        local pot = PotFor(t, mid)
        for key, stake in pairs(theirs.stakes) do
            local mine = pot.stakes[key]
            if not mine then
                pot.stakes[key] = stake
                changed = true
            elseif stake.cancel and not mine.cancel then
                mine.cancel = stake.cancel
                changed = true
            end
        end
        for k in pairs(theirs.paid) do
            if not pot.paid[k] then
                pot.paid[k] = true
                changed = true
            end
        end
    end
    return changed
end

local FORMAT_VERSION = "1"

-- 1;id;host;name;created;hrev;start;cancel;names;seeds;walkovers;joins;games;stakes;paid
-- Every name is listed once (sorted) and everything else refers to it by number:
--   seeds:     n,n,...                      walkovers: match:n:time,...
--   joins:     n:time:0|1 (1 = left),...    games:     match:end:start:winner:loser,...
--   stakes:    pot:n:side:copper:time:cancelTime (0 = not cancelled),...
--   paid:      pot:from:to,...
function T.Serialize(t)
    local set = {}
    local function Add(key) set[key] = true end
    for _, key in ipairs(t.seeds) do Add(key) end
    for _, x in pairs(t.wo) do Add(x.w) end
    for key in pairs(t.joins) do Add(key) end
    for _, list in pairs(t.games) do
        for _, g in ipairs(list) do Add(g.w); Add(g.o) end
    end
    for _, pot in pairs(t.pots) do
        for key, s in pairs(pot.stakes) do Add(key); Add(s.side) end
        for k in pairs(pot.paid) do
            local from, to = k:match("^(.-)>(.+)$")
            Add(from); Add(to)
        end
    end
    local names, ref = {}, {}
    for key in pairs(set) do names[#names + 1] = key end
    table.sort(names)
    for i, key in ipairs(names) do ref[key] = i end

    local seeds, wo, joins, games, stakes, paid = {}, {}, {}, {}, {}, {}
    for i, key in ipairs(t.seeds) do seeds[i] = ref[key] end
    for mid, x in pairs(t.wo) do wo[#wo + 1] = ("%s:%d:%d"):format(mid, ref[x.w], x.t) end
    for key, j in pairs(t.joins) do joins[#joins + 1] = ("%d:%d:%d"):format(ref[key], j.t, j.out and 1 or 0) end
    for mid, list in pairs(t.games) do
        for _, g in ipairs(list) do
            games[#games + 1] = ("%s:%d:%d:%d:%d"):format(mid, g.t, g.s, ref[g.w], ref[g.o])
        end
    end
    for mid, pot in pairs(t.pots) do
        for key, s in pairs(pot.stakes) do
            stakes[#stakes + 1] = ("%s:%d:%d:%d:%d:%d"):format(mid, ref[key], ref[s.side], s.amt, s.t, s.cancel or 0)
        end
        for k in pairs(pot.paid) do
            local from, to = k:match("^(.-)>(.+)$")
            paid[#paid + 1] = ("%s:%d:%d"):format(mid, ref[from], ref[to])
        end
    end
    for _, list in ipairs({ wo, joins, games, stakes, paid }) do table.sort(list) end
    return table.concat({
        FORMAT_VERSION, t.id, t.host, Clean(t.name), t.t, t.hrev, t.start, t.cancel or 0,
        table.concat(names, ","), table.concat(seeds, ","), table.concat(wo, ","), table.concat(joins, ","),
        table.concat(games, ","), table.concat(stakes, ","), table.concat(paid, ","),
    }, ";")
end

function T.Deserialize(s)
    local f = {}
    for field in (s .. ";"):gmatch("([^;]*);") do f[#f + 1] = field end
    if f[1] ~= FORMAT_VERSION or #f ~= 15 then return nil end
    local t = {
        id = f[2], host = f[3], name = f[4], t = tonumber(f[5]), hrev = tonumber(f[6]),
        start = tonumber(f[7]), cancel = tonumber(f[8]),
        seeds = {}, wo = {}, joins = {}, games = {}, pots = {},
    }
    if t.id == "" or t.host == "" or not t.t or not t.hrev or not t.start or not t.cancel then return nil end
    if t.cancel == 0 then t.cancel = nil end
    local names = {}
    for key in f[9]:gmatch("[^,]+") do names[#names + 1] = key end
    local function Name(i) return names[tonumber(i)] end

    for i in f[10]:gmatch("%d+") do
        local key = Name(i)
        if not key then return nil end
        t.seeds[#t.seeds + 1] = key
    end
    if #t.seeds > T.MAX_PLAYERS or (t.start > 0 and #t.seeds < 2) then return nil end
    for mid, w, time in f[11]:gmatch("([%w%.]+):(%d+):(%d+)") do
        if Name(w) then t.wo[mid] = { w = Name(w), t = tonumber(time) } end
    end
    for k, time, out in f[12]:gmatch("(%d+):(%d+):([01])") do
        if Name(k) then t.joins[Name(k)] = { t = tonumber(time), out = out == "1" } end
    end
    for mid, et, st, w, o in f[13]:gmatch("([%w%.]+):(%d+):(%d+):(%d+):(%d+)") do
        if Name(w) and Name(o) then AddGame(t, mid, { t = tonumber(et), s = tonumber(st), w = Name(w), o = Name(o) }) end
    end
    for mid, k, side, amt, time, cancel in f[14]:gmatch("([%w%.]+):(%d+):(%d+):(%d+):(%d+):(%d+)") do
        if Name(k) and Name(side) then
            cancel = tonumber(cancel)
            PotFor(t, mid).stakes[Name(k)] = { side = Name(side), amt = tonumber(amt), t = tonumber(time), cancel = cancel > 0 and cancel or nil }
        end
    end
    for mid, from, to in f[15]:gmatch("([%w%.]+):(%d+):(%d+)") do
        if Name(from) and Name(to) then PotFor(t, mid).paid[Name(from) .. ">" .. Name(to)] = true end
    end
    return t
end

-- A small checksum, so we can tell whether someone just sent the same thing.
function T.Hash(t)
    local s, h = T.Serialize(t), 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    return h
end

ns:On("GUILD_READY", function()
    T:Prune()
    T:Update()
end)

ns:On("DATA_CHANGED", function()
    if Data.guild then T:Update() end
end)

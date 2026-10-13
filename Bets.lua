local _, ns = ...
local Compat, Data = ns.Compat, ns.Data

-- Betting on duels with gold and silver, as pots ("pools"). All amounts are copper.
--
-- A pool is one upcoming duel between two guild members. There are two kinds:
--   * public pots: anyone can put money on either fighter (fighters only on themselves)
--   * challenges: one fighter challenges the other for an amount; only those two are in it.
--     The challenged player accepts (matching the amount) or declines.
-- Both kinds can exist for the same duel. The next duel between the two that STARTS after
-- the pool opened (and within OPEN_DAYS of it) decides it. The winners get their own gold
-- back plus a share of the losers' gold, split by how much each winner bet. If nobody bet on
-- one side, nobody owes anything.
--
-- DuelLadder never moves gold. When a pool is decided it works out who pays whom
-- ("Erik pays Anna 15g"); the payer uses Pay (fills in a trade or mail) and the receiver
-- confirms with "Got it". Confirmed payments are kept as amounts, so if a bet turns up late
-- (its owner went offline before it synced) the remaining payments are worked out again
-- around what has already been paid.
--
-- You can cancel your bet (or your challenge) until the duel starts. A cancel (or a new bet) made after the
-- duel started doesn't count, so nobody can back out mid-fight.
--
-- You can't promise more gold than you have: new bets must fit in your gold minus what's
-- already riding on undecided duels and what you still owe.
--
-- Each bet in a pool belongs to the person who placed it, so copies from different people
-- are merged: stakes are added, cancels and payment confirmations are kept.
local Bets = {}
ns.Bets = Bets

Bets.MIN_COPPER = 100              -- 1 silver
Bets.MAX_COPPER = 10000 * 10000     -- 10,000 gold
Bets.OPEN_DAYS = 7        -- a pool without a duel is void after this
Bets.KEEP_DAYS = 30       -- finished pools are forgotten after this

local COPPER = 10000
local DAY = 86400
local counter = 0

local function Me() return Compat.PlayerKey() end

function Bets:All()
    return Data.guild and Data.guild.pools or {}
end

function Bets.Other(pool, fighter)
    return fighter == pool.a and pool.b or pool.a
end

local function SamePair(pool, a, b)
    return (pool.a == a and pool.b == b) or (pool.a == b and pool.b == a)
end

-- Only a duel that starts by this time decides the pool; after it the pool has expired.
local function Deadline(pool)
    return pool.t + Bets.OPEN_DAYS * DAY
end

------------------------------------------------------------------------
-- Deciding duel, stakes and payouts
------------------------------------------------------------------------

-- The first duel between the fighters that started after `since`: winner, start time.
local function DecidingDuel(a, b, since)
    local entries = Data:Entries()
    local bestStart, winner
    for _, pair in ipairs({ { a, b }, { b, a } }) do
        local e = entries[pair[1]]
        if e then
            for _, r in ipairs(e.recent) do
                local start = Data.DuelStart(r)
                if r.o == pair[2] and start > since and (not bestStart or start < bestStart) then
                    bestStart = start
                    winner = r.r == "W" and pair[1] or pair[2]
                end
            end
        end
    end
    return winner, bestStart
end

-- Does this stake count? Placed before the deciding duel started (or before now if
-- undecided), and not cancelled before that.
local function StakeCounts(stake, cutoff)
    if stake.t >= cutoff then return false end
    return not stake.cancel or stake.cancel >= cutoff
end

-- Stakes that count, as a sorted list of { key, side, amt }.
function Bets.ValidStakes(pool)
    local cutoff = pool.rs or math.huge
    local list = {}
    for key, stake in pairs(pool.stakes) do
        if StakeCounts(stake, cutoff) then
            list[#list + 1] = { key = key, side = stake.side, amt = stake.amt }
        end
    end
    table.sort(list, function(x, y) return x.key < y.key end)
    return list
end

-- Copper on each fighter right now: totalA, countA, totalB, countB.
function Bets.Pot(pool)
    local ta, ca, tb, cb = 0, 0, 0, 0
    for _, s in ipairs(Bets.ValidStakes(pool)) do
        if s.side == pool.a then ta, ca = ta + s.amt, ca + 1 else tb, cb = tb + s.amt, cb + 1 end
    end
    return ta, ca, tb, cb
end

-- What you'd get back in total if `side` wins and you add `copper` to it.
function Bets.PreviewReturn(pool, side, copper)
    local ta, _, tb = Bets.Pot(pool)
    local mine, theirs = side == pool.a and ta or tb, side == pool.a and tb or ta
    local winners = mine + copper
    if theirs == 0 or winners == 0 then return copper end
    return copper + math.floor(theirs * copper / winners)
end

-- Net result per person in copper once decided (winners +, losers -), or nil if the pool
-- isn't decided or is void (one side had no bets).
function Bets.Payouts(pool)
    if not pool.res then return nil end
    local winners, losers, W, L = {}, {}, 0, 0
    for _, s in ipairs(Bets.ValidStakes(pool)) do
        if s.side == pool.res then
            winners[#winners + 1] = s
            W = W + s.amt
        else
            losers[#losers + 1] = s
            L = L + s.amt
        end
    end
    if W == 0 or L == 0 then return nil end

    local net, pot, handed = {}, L, 0
    for _, s in ipairs(losers) do net[s.key] = -s.amt end
    for _, s in ipairs(winners) do
        local share = math.floor(pot * s.amt / W)
        net[s.key] = share
        handed = handed + share
    end
    -- Leftover copper from rounding goes to the biggest winners, one each.
    table.sort(winners, function(x, y)
        if x.amt ~= y.amt then return x.amt > y.amt end
        return x.key < y.key
    end)
    local i = 1
    while handed < pot do
        local s = winners[(i - 1) % #winners + 1]
        net[s.key] = net[s.key] + 1
        handed, i = handed + 1, i + 1
    end
    return net
end

-- Pairs up who owes (net < 0) with who's owed (net > 0), biggest first, into a short list
-- of { from, to, copper }. Every client gets the same list from the same numbers.
local function Settle(net)
    local creditors, debtors = {}, {}
    for key, amount in pairs(net) do
        if amount > 0 then creditors[#creditors + 1] = { key = key, left = amount } end
        if amount < 0 then debtors[#debtors + 1] = { key = key, left = -amount } end
    end
    local function Biggest(x, y)
        if x.left ~= y.left then return x.left > y.left end
        return x.key < y.key
    end
    table.sort(creditors, Biggest)
    table.sort(debtors, Biggest)

    local out, i, j = {}, 1, 1
    while i <= #debtors and j <= #creditors do
        local d, c = debtors[i], creditors[j]
        local amount = math.min(d.left, c.left)
        out[#out + 1] = { from = d.key, to = c.key, copper = amount }
        d.left, c.left = d.left - amount, c.left - amount
        if d.left == 0 then i = i + 1 end
        if c.left == 0 then j = j + 1 end
    end
    return out
end

-- The payments that settle a decided pool: list of { from, to, copper, paid }. Confirmed
-- payments (pool.paid["From>To"] = copper) come first; what's still owed is worked out
-- around them, so a bet that turns up late only changes what hasn't been paid yet.
function Bets.Transfers(pool)
    local net = Bets.Payouts(pool)
    if not net then return {} end
    local out, left, done = {}, {}, {}
    for key, amount in pairs(net) do left[key] = amount end
    for k in pairs(pool.paid) do done[#done + 1] = k end
    table.sort(done)
    for _, k in ipairs(done) do
        local from, to = k:match("^(.-)>(.+)$")
        local copper = pool.paid[k]
        if from and type(copper) == "number" and copper > 0 then
            left[from] = (left[from] or 0) + copper
            left[to] = (left[to] or 0) - copper
            out[#out + 1] = { from = from, to = to, copper = copper, paid = true }
        end
    end
    for _, t in ipairs(Settle(left)) do
        t.paid = false
        out[#out + 1] = t
    end
    return out
end

-- DuelLadder 0.4 and older stored a confirmed payment as just "From>To" = true, meaning
-- that whole payment as it was worked out then. Turns those into amounts.
local function NormalizePaid(pool)
    local legacy, net
    for k, v in pairs(pool.paid) do
        if v == true then
            if not legacy then
                legacy, net = {}, Bets.Payouts(pool) or {}
                for _, t in ipairs(Settle(net)) do legacy[t.from .. ">" .. t.to] = t.copper end
            end
            local amount = legacy[k]
            if not amount then
                -- The bets changed since it was confirmed: count what that payment could have been.
                local from, to = k:match("^(.-)>(.+)$")
                local owed, due = from and -(net[from] or 0) or 0, to and (net[to] or 0) or 0
                if owed > 0 and due > 0 then amount = math.min(owed, due) end
            end
            pool.paid[k] = amount
        end
    end
end

-- "open", "settled" (payments outstanding), "paid", "void" (one-sided) or "expired" (no duel).
function Bets.State(pool)
    if pool.res then
        local transfers = Bets.Transfers(pool)
        if #transfers == 0 then return "void" end
        for _, t in ipairs(transfers) do
            if not t.paid then return "settled" end
        end
        return "paid"
    end
    if Compat.Now() > Deadline(pool) then return "expired" end
    return "open"
end

-- Old finished pools nobody needs any more (anything with payments outstanding is kept).
function Bets.Forgettable(pool)
    if pool.t >= Compat.Now() - Bets.KEEP_DAYS * DAY then return false end
    local state = Bets.State(pool)
    return state ~= "open" and state ~= "settled"
end

function Bets.MyStake(pool)
    local stake = pool.stakes[Me()]
    if stake and not stake.cancel then return stake end
    return nil
end

-- The challenger in a challenge, or nil for a public pot.
function Bets.Challenger(pool)
    return pool.challenge and Bets.Other(pool, pool.challenge)
end

-- Did the challenged player decline? (Stored as a cancelled empty bet, so it syncs.)
function Bets.Declined(pool)
    local stake = pool.challenge and pool.stakes[pool.challenge]
    return stake ~= nil and stake.amt == 0 and stake.cancel ~= nil
end

-- The open public pot for these two fighters, if there is one (the newest).
function Bets:OpenPool(a, b)
    local best
    for _, pool in pairs(self:All()) do
        if not pool.challenge and SamePair(pool, a, b) and Bets.State(pool) == "open" and (not best or pool.t > best.t) then
            best = pool
        end
    end
    return best
end

------------------------------------------------------------------------
-- Actions (our own)
------------------------------------------------------------------------

local function Changed(id)
    ns.Sync:SendPool(id)
    ns:Fire("BETS_CHANGED")
end

-- Copper we've promised but not handed over: our bets on duels that haven't happened yet,
-- plus what we still owe from decided ones.
function Bets:Committed()
    local me, total = Me(), 0
    for _, pool in pairs(self:All()) do
        if pool.res then
            for _, t in ipairs(Bets.Transfers(pool)) do
                if t.from == me and not t.paid then total = total + t.copper end
            end
        else
            local stake = Bets.MyStake(pool)
            if stake and Bets.State(pool) == "open" then total = total + stake.amt end
        end
    end
    return total
end

-- Copper we can still put on a new bet.
function Bets:Available()
    return math.max(0, GetMoney() - self:Committed())
end

-- Can we put `copper` on top of everything we've already promised? verb: "bet" or "match".
local function CheckFunds(copper, verb)
    local committed = Bets:Committed()
    if Compat.CanAfford(copper + committed) then return true end
    if committed == 0 then
        return nil, ("You only have %s, so you can't %s %s."):format(Compat.MoneyText(GetMoney()), verb, Compat.MoneyText(copper))
    end
    return nil, ("You only have %s free to bet, so you can't %s %s: %s of your %s is already riding on other bets or owed."):format(
        Compat.MoneyText(Bets:Available()), verb, Compat.MoneyText(copper), Compat.MoneyText(committed), Compat.MoneyText(GetMoney()))
end

local function CheckAmount(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper < Bets.MIN_COPPER or copper > Bets.MAX_COPPER then
        return nil, ("Bets must be between %s and %s."):format(Compat.MoneyText(Bets.MIN_COPPER), Compat.MoneyText(Bets.MAX_COPPER))
    end
    local ok, err = CheckFunds(copper, "bet")
    if not ok then return nil, err end
    return copper
end
Bets.CheckAmount = CheckAmount

local function NewPool(a, b, extra)
    counter = counter + 1
    local me, now = Me(), Compat.Now()
    local pool = { id = ("%s#%d#%d"):format(me, now, counter), a = a, b = b, t = now, by = me, stakes = {}, paid = {}, v = 2 }
    for k, v in pairs(extra or {}) do pool[k] = v end
    Bets:All()[pool.id] = pool
    return pool
end

-- Puts money on `side` in the next duel between a and b, in the public pot for that duel
-- (opened if there isn't one). Returns the pool id, or nil plus an error message.
function Bets:Place(a, b, side, copper)
    if not Data.guild then return nil, "You're not in a guild." end
    local me = Me()
    if not a or not b or a == b then return nil, "Pick two different fighters." end
    if side ~= a and side ~= b then return nil, "Pick who you're backing." end
    if (me == a or me == b) and side ~= me then return nil, "You can't bet against yourself." end

    local pool = self:OpenPool(a, b)
    if pool and pool.stakes[me] then
        return nil, pool.stakes[me].cancel and "You cancelled your bet on this duel, so you can't bet on it again."
            or "You already have a bet on this duel. Cancel it first if you want to change it."
    end
    local amount, err = CheckAmount(copper)
    if not amount then return nil, err end

    pool = pool or NewPool(a, b)
    pool.stakes[me] = { side = side, amt = amount, t = Compat.Now() }
    Changed(pool.id)
    return pool.id
end

-- Challenge someone to a one-on-one duel for an amount. Only the two of you are in it;
-- they accept (matching it) or decline. Returns the pool id, or nil plus an error message.
function Bets:Challenge(opponent, copper)
    if not Data.guild then return nil, "You're not in a guild." end
    local me = Me()
    if not opponent or opponent == me then return nil, "Pick someone to challenge." end
    for _, pool in pairs(self:All()) do
        if pool.challenge == opponent and Bets.Challenger(pool) == me and Bets.State(pool) == "open" and Bets.MyStake(pool) then
            return nil, ("You've already challenged %s. Cancel that challenge first to make a new one."):format(Compat.DisplayName(opponent))
        end
    end
    local amount, err = CheckAmount(copper)
    if not amount then return nil, err end
    local pool = NewPool(me, opponent, { challenge = opponent })
    pool.stakes[me] = { side = me, amt = amount, t = Compat.Now() }
    Changed(pool.id)
    return pool.id
end

-- Accept a challenge made to us: we put in the same amount on ourselves.
function Bets:Accept(id)
    local pool = self:All()[id]
    local me = Me()
    if not pool or pool.challenge ~= me then return nil, "That challenge isn't for you." end
    if Bets.State(pool) ~= "open" then return nil, "That challenge is over." end
    if pool.stakes[me] then return nil, "You've already answered that challenge." end
    local theirs = pool.stakes[Bets.Challenger(pool)]
    if not theirs or theirs.cancel then return nil, "They cancelled that challenge." end
    local ok, err = CheckFunds(theirs.amt, "match")
    if not ok then return nil, err end
    pool.stakes[me] = { side = me, amt = theirs.amt, t = Compat.Now() }
    Changed(id)
    return id
end

-- Decline a challenge made to us.
function Bets:Decline(id)
    local pool = self:All()[id]
    local me = Me()
    if not pool or pool.challenge ~= me then return false, "That challenge isn't for you." end
    if pool.stakes[me] then return false, "You've already answered that challenge." end
    local now = Compat.Now()
    pool.stakes[me] = { side = me, amt = 0, t = now, cancel = now }
    Changed(id)
    return true
end

-- Withdraws our bet from a pool that hasn't been decided.
function Bets:Cancel(id)
    local pool = self:All()[id]
    local stake = pool and Bets.MyStake(pool)
    if not stake then return false, "You don't have a bet there to cancel." end
    if Bets.State(pool) ~= "open" then return false, "That duel has already happened, so your bet stands." end
    stake.cancel = Compat.Now()
    Changed(id)
    return true
end

-- The receiver confirms they got a payment.
function Bets:MarkPaid(id, from)
    local pool = self:All()[id]
    if not pool then return false, "Unknown bet." end
    for _, t in ipairs(Bets.Transfers(pool)) do
        if t.from == from and t.to == Me() and not t.paid then
            local k = from .. ">" .. t.to
            pool.paid[k] = (pool.paid[k] or 0) + t.copper
            Changed(id)
            return true
        end
    end
    return false, "Only the person being paid can confirm a payment."
end

-- What we owe someone in a pool, in copper.
local function OwedTo(pool, to)
    for _, t in ipairs(Bets.Transfers(pool)) do
        if t.from == Me() and t.to == to and not t.paid then return t.copper end
    end
    return nil
end

-- A trade we opened to pay: fill in the gold once the trade window shows.
local pendingTrade -- { to, copper, expires }
local TRADE_WAIT = 10 -- seconds to wait for the trade window

local function FillTrade(to, copper)
    if not Compat.CanAfford(copper) then
        ns.Print(("|cffff4040You only have %s|r, so the trade won't go through until you have %s."):format(
            Compat.MoneyText(GetMoney()), Compat.MoneyText(copper)))
    end
    if Compat.PrefillTrade(copper) then
        ns.Print(("Trading with %s: %s filled in. Check it and click Trade."):format(
            Compat.DisplayName(to), Compat.MoneyText(copper)))
    else
        ns.Print(("Trading with %s: put in %s and click Trade."):format(
            Compat.DisplayName(to), Compat.MoneyText(copper)))
    end
end

ns:Listen("TRADE_SHOW", function()
    local p = pendingTrade
    if not p then return end
    if GetTime() > p.expires then
        pendingTrade = nil
        return
    end
    -- The trade window clears its money fields as it opens, so fill in a moment later. That
    -- also gives the window time to show, so we can see who the trade is with. A trade with
    -- someone else leaves the payment waiting.
    C_Timer.After(0.2, function()
        if pendingTrade ~= p or Compat.TradePartner() ~= p.to then return end
        pendingTrade = nil
        FillTrade(p.to, p.copper)
    end)
end)

-- Pays what we owe `to` in a pool.
function Bets:Pay(id, to)
    local pool = self:All()[id]
    local copper = pool and OwedTo(pool, to)
    if copper then self:SendMoney(to, copper, "DuelLadder bet") end
end

-- Pays `to`: fills in an open trade or mail, or opens a trade if they're close by. The player
-- always confirms the trade or mail themselves.
function Bets:SendMoney(to, copper, subject)
    local name = Compat.DisplayName(to)

    if Compat.TradePartner() == to then
        FillTrade(to, copper)
        return
    end
    if Compat.PrefillMail(Compat.MailName(to), copper, subject) then
        ns.Print(("Mail to %s filled in with %s. Check it and press Send."):format(name, Compat.MoneyText(copper)))
        return
    end

    local unit = Compat.FindUnit(to)
    if not unit then
        ns.Print(("Can't see %s. Target them and press Pay again to trade, or open a mailbox."):format(name))
    elseif not Compat.InTradeRange(unit) then
        ns.Print(("%s is too far away to trade. Get closer and press Pay again, or use a mailbox."):format(name))
    elseif Compat.OpenTrade(unit) then
        pendingTrade = { to = to, copper = copper, expires = GetTime() + TRADE_WAIT }
        ns.Print(("Opening a trade with %s..."):format(name))
    else
        ns.Print(("Couldn't open a trade with %s. Try trading them yourself, or use a mailbox."):format(name))
    end
end

------------------------------------------------------------------------
-- Deciding pools, news and totals
------------------------------------------------------------------------

-- Decides every pool whose duel has happened (before it expired). Returns true if anything changed.
function Bets:Resolve()
    local changed = false
    for id, pool in pairs(self:All()) do
        if not pool.res then
            local winner, start = DecidingDuel(pool.a, pool.b, pool.t)
            if winner and start <= Deadline(pool) then
                pool.res, pool.rs = winner, start
                -- Everyone online works this out from the same duel, so don't all send it.
                ns.Sync:SharePool(id)
                changed = true
            end
        end
    end
    if changed then ns:Fire("BETS_CHANGED") end
    self:Notify()
    return changed
end

-- Resolve soon. Stats arrive in bursts (a sync, a roster update), so they share one run.
local resolveQueued = false
function Bets:RequestResolve()
    if resolveQueued then return end
    resolveQueued = true
    C_Timer.After(0.5, function()
        resolveQueued = false
        if Data.guild then Bets:Resolve() end
    end)
end

-- High Roller counts pools where we won 50+ gold. Counting (instead of adding one per
-- notification) means a wiped SavedVariables can't award it twice.
local function UpdateHighRoller()
    local e = Data:MyEntry()
    if not e then return end
    local me, won = Me(), 0
    local badge = ns.Badges.BY_ID.hr
    for _, pool in pairs(Bets:All()) do
        local net = Bets.Payouts(pool)
        if net and net[me] and badge.check(e, { betWon = net[me] / COPPER }) then
            won = won + 1
        end
    end
    if won > (e.badges.hr or 0) then
        e.badges.hr = won
        e.rev = e.rev + 1
        ns.Sync:SendOwn()
        ns.Badges.Announce({ badge })
    end
end

local NEWS_SECONDS = 2 * 86400 -- don't replay old news (e.g. after a reinstall)

-- Tells us about pools that concern us, once each: challenges, people joining our duels or
-- bets, and results. What we've been told is kept per character, not synced.
function Bets:Notify()
    if not Data.guild then return end
    local me, now = Me(), Compat.Now()
    local seenAll = Data.guild.betSeen
    UpdateHighRoller()
    for id, pool in pairs(self:All()) do
        local seen = seenAll[id]
        if not seen then
            seen = { joined = {} }
            seenAll[id] = seen
        end
        seen.joined = seen.joined or {}
        local state = Bets.State(pool)
        local fresh = now - pool.t < NEWS_SECONDS
        local versus = Compat.DisplayName(pool.a) .. " vs " .. Compat.DisplayName(pool.b)

        if state == "open" and pool.challenge == me and not pool.stakes[me] and not seen.offer then
            seen.offer = true
            local challenger = Bets.Challenger(pool)
            local stake = pool.stakes[challenger]
            if fresh and stake and not stake.cancel then
                ns.Print(("|cffffd100%s challenges you to a duel for %s!|r Open |cffffffff/duels|r > Bets to accept or decline."):format(
                    Compat.DisplayName(challenger), Compat.MoneyText(stake.amt)))
                Compat.PlaySound("READY_CHECK")
            end
        end

        -- Someone joined a duel we're fighting in or have money on.
        if state == "open" and Bets.MyStake(pool) then
            for key, stake in pairs(pool.stakes) do
                if key ~= me and not seen.joined[key] then
                    seen.joined[key] = true
                    if fresh and pool.challenge == key then
                        if Bets.Declined(pool) then
                            ns.Print(("%s declined your challenge."):format(Compat.DisplayName(key)))
                        elseif not stake.cancel then
                            ns.Print(("|cffffd100%s accepted your challenge for %s!|r The next duel between you decides it."):format(
                                Compat.DisplayName(key), Compat.MoneyText(stake.amt)))
                        end
                    elseif not stake.cancel and fresh then
                        ns.Print(("%s put %s on %s in %s."):format(Compat.DisplayName(key), Compat.MoneyText(stake.amt),
                            Compat.DisplayName(stake.side), versus))
                    end
                end
            end
        end

        if pool.res and not seen.res then
            seen.res = true
            local net = Bets.Payouts(pool)
            local mine = net and net[me]
            if mine and now - pool.rs < NEWS_SECONDS then
                if mine > 0 then
                    ns.Print(("|cff20ff20You won %s|r on %s! Open |cffffffff/duels|r > Bets to see who pays you."):format(
                        Compat.MoneyText(mine), versus))
                else
                    ns.Print(("|cffff4040You lost %s|r on %s. Pay with the Pay button in |cffffffff/duels|r > Bets."):format(
                        Compat.MoneyText(-mine), versus))
                end
            elseif not net and pool.stakes[me] and now - pool.rs < NEWS_SECONDS then
                ns.Print(("Nobody took the other side of %s, so nobody owes anything."):format(versus))
            end
        end
    end
end

-- Totals for us in copper: net won across decided pools, owed to us, we owe.
function Bets:Balance()
    local me = Me()
    local total, owedToMe, iOwe = 0, 0, 0
    for _, pool in pairs(self:All()) do
        local net = Bets.Payouts(pool)
        if net and net[me] then total = total + net[me] end
        for _, t in ipairs(Bets.Transfers(pool)) do
            if not t.paid then
                if t.to == me then owedToMe = owedToMe + t.copper end
                if t.from == me then iOwe = iOwe + t.copper end
            end
        end
    end
    return total, owedToMe, iOwe
end

-- Forgets old finished pools, and redirects to them that now lead nowhere.
function Bets:Prune()
    local pools, alias = self:All(), Data.guild.poolAlias
    for id, pool in pairs(pools) do
        if Bets.Forgettable(pool) then
            pools[id] = nil
            Data.guild.betSeen[id] = nil
        end
    end
    for from, to in pairs(alias) do
        if not pools[to] then alias[from] = nil end
    end
end

-- Fixes pools saved by DuelLadder 0.4 and older: payments confirmed without an amount, and
-- pools that were decided by a duel after they had expired (those were void all along).
function Bets:Repair()
    for _, pool in pairs(self:All()) do
        if pool.res and pool.rs > Deadline(pool) then pool.res, pool.rs = nil, nil end
        NormalizePaid(pool)
    end
end

-- Bets from DuelLadder 0.2 (one person against one other) become pools with two stakes.
function Bets:MigrateOldBets()
    local guild = Data.guild
    if not guild or not guild.bets then return end
    for id, b in pairs(guild.bets) do
        if not guild.pools[id] then
            local other = b.pick == b.a and b.b or b.a
            local pool = {
                id = id, a = b.a, b = b.b, t = b.t, by = b.by,
                challenge = (b.only and b.by == b.pick) and b.only or nil,
                stakes = { [b.by] = { side = b.pick, amt = b.amt * COPPER, t = b.t, cancel = b.cancel and b.t or nil } },
                paid = {}, v = 2,
            }
            if b.taker then pool.stakes[b.taker] = { side = other, amt = b.amt * COPPER, t = b.tt or b.t } end
            if b.res then
                pool.res, pool.rs = b.res, (b.rt or b.t) - 1
                if b.paid and b.taker then
                    local winner = b.res == b.pick and b.by or b.taker
                    local loser = winner == b.by and b.taker or b.by
                    pool.paid[loser .. ">" .. winner] = true
                end
            end
            guild.pools[id] = pool
        end
    end
    guild.bets = nil
end

-- Pools from 0.3.0 stored whole gold; now everything is copper.
function Bets:MigrateUnits()
    for _, pool in pairs(self:All()) do
        if not pool.v then
            for _, stake in pairs(pool.stakes) do stake.amt = stake.amt * COPPER end
            pool.v = 2
        end
    end
end

------------------------------------------------------------------------
-- Merging and wire format
------------------------------------------------------------------------

-- Two copies of one person's bet that differ (they bet in two pots that were later joined):
-- everyone keeps the earlier one, so every copy of the pool ends up the same.
local function Earlier(x, y)
    if x.t ~= y.t then return x.t < y.t end
    if x.amt ~= y.amt then return x.amt < y.amt end
    return x.side < y.side
end

-- Folds pool `from` into pool `into` (same duel). Returns true if `into` changed.
-- Merging in either order gives the same pool, so copies that met once stay equal.
local function Absorb(into, from)
    local changed = false
    for key, stake in pairs(from.stakes) do
        local mine = into.stakes[key]
        if not mine then
            into.stakes[key] = { side = stake.side, amt = stake.amt, t = stake.t, cancel = stake.cancel }
            changed = true
        else
            if (stake.t ~= mine.t or stake.amt ~= mine.amt or stake.side ~= mine.side) and Earlier(stake, mine) then
                mine.side, mine.amt, mine.t = stake.side, stake.amt, stake.t
                changed = true
            end
            if stake.cancel and (not mine.cancel or stake.cancel < mine.cancel) then
                mine.cancel = stake.cancel
                changed = true
            end
        end
    end
    -- Only the receiver confirms a payment, and amounts only grow, so the bigger one is newer.
    for k, copper in pairs(from.paid) do
        if (into.paid[k] or 0) < copper then
            into.paid[k] = copper
            changed = true
        end
    end
    -- The earliest deciding duel wins (ties: the same pick everywhere), as long as it started
    -- before the pool expired.
    if from.res and from.rs <= Deadline(into)
        and (not into.res or from.rs < into.rs or (from.rs == into.rs and from.res < into.res)) then
        into.res, into.rs = from.res, from.rs
        changed = true
    end
    -- A merged pot is open from the earliest of its parts; a challenge stays a challenge.
    if from.t < into.t then
        into.t = from.t
        changed = true
    end
    if from.challenge and not into.challenge then
        into.challenge = from.challenge
        changed = true
    end
    return changed
end

-- Merges a copy from someone else into ours. Returns true if ours changed.
-- If two people opened a pot for the same duel at the same moment, everyone ends up
-- keeping the one with the smaller id and moves the other's bets into it. Only two OPEN
-- pots are joined like that: an old expired pot is a different duel and stays apart.
function Bets:Merge(r)
    local pools = self:All()
    local alias = Data.guild.poolAlias
    local targetId = alias[r.id] or r.id
    local p = pools[targetId]
    if p then return Absorb(p, r) end
    if Bets.Forgettable(r) then return false end -- we pruned it (or would have)

    if Bets.State(r) == "open" then
        for id, other in pairs(pools) do
            if not other.res and not other.challenge and not r.challenge and id ~= r.id
                and SamePair(other, r.a, r.b) and Bets.State(other) == "open" then
                if r.id < id then
                    pools[r.id] = r
                    Absorb(r, other)
                    pools[id] = nil
                    alias[id] = r.id
                    ns.Sync:SendPool(r.id) -- our bets now live in this pot
                else
                    Absorb(other, r)
                    alias[r.id] = id
                    ns.Sync:SendPool(id)
                end
                return true
            end
        end
    end
    pools[r.id] = r
    return true
end

local FORMAT_VERSION = "2"

-- 2;id;a;b;t;by;challenge;res;rs;stakes;paid
--   stakes: Name-Realm=A|B:copper:time:cancelTime(0 = not cancelled),...
--   (version 1, from 0.3.0, had whole gold instead of copper)
--   paid:   From-Realm>To-Realm=copper,...
--   Each payment is also listed as plain From-Realm>To-Realm, which is how DuelLadder 0.4 and
--   older say "paid in full" (they ignore the entries with an amount).
function Bets.Serialize(p)
    local stakes = {}
    for key, s in pairs(p.stakes) do
        stakes[#stakes + 1] = ("%s=%s:%d:%d:%d"):format(key, s.side == p.a and "A" or "B", s.amt, s.t, s.cancel or 0)
    end
    table.sort(stakes)
    local paid = {}
    for k, copper in pairs(p.paid) do
        paid[#paid + 1] = k
        paid[#paid + 1] = ("%s=%d"):format(k, copper)
    end
    table.sort(paid)
    return table.concat({
        FORMAT_VERSION, p.id, p.a, p.b, p.t, p.by, p.challenge or "", p.res or "", p.rs or 0,
        table.concat(stakes, ","), table.concat(paid, ","),
    }, ";")
end

function Bets.Deserialize(s)
    local f = {}
    for field in (s .. ";"):gmatch("([^;]*);") do f[#f + 1] = field end
    local version = f[1]
    if (version ~= FORMAT_VERSION and version ~= "1") or #f ~= 11 then return nil end
    local unit = version == "1" and COPPER or 1
    local p = {
        id = f[2], a = f[3], b = f[4], t = tonumber(f[5]), by = f[6],
        challenge = f[7] ~= "" and f[7] or nil,
        res = f[8] ~= "" and f[8] or nil, rs = tonumber(f[9]),
        stakes = {}, paid = {}, v = 2,
    }
    if not p.t or not p.rs or p.id == "" or p.a == p.b then return nil end
    if p.res and p.res ~= p.a and p.res ~= p.b then return nil end
    -- No result, or one from a duel after the pool expired (older versions accepted those).
    if not p.res or p.rs > Deadline(p) then p.res, p.rs = nil, nil end
    for key, side, amt, t, cancel in f[10]:gmatch("([^,=]+)=([AB]):(%d+):(%d+):(%d+)") do
        cancel = tonumber(cancel)
        p.stakes[key] = { side = side == "A" and p.a or p.b, amt = tonumber(amt) * unit, t = tonumber(t), cancel = cancel > 0 and cancel or nil }
    end
    local plain = {}
    for item in f[11]:gmatch("([^,]+)") do
        local k, copper = item:match("^([^=]+)=(%d+)$")
        if k then p.paid[k] = tonumber(copper) else plain[item] = true end
    end
    for k in pairs(plain) do
        if not p.paid[k] then p.paid[k] = true end -- from 0.4 or older: amount worked out below
    end
    NormalizePaid(p)
    return p
end

-- A small checksum of a pool's state, so we can tell whether someone just sent the same thing.
function Bets.Hash(p)
    local s, h = Bets.Serialize(p), 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    return h
end

ns:On("GUILD_READY", function()
    Bets:MigrateUnits()
    Bets:MigrateOldBets()
    Bets:Repair()
    Bets:Prune()
    Bets:Resolve()
end)

ns:On("DATA_CHANGED", function()
    if Data.guild then Bets:RequestResolve() end
end)

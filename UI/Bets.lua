local _, ns = ...
local Compat, Data, UI = ns.Compat, ns.Data, ns.UI
local Bets = ns.Bets

-- Bets tab: payments and challenges waiting on you first, then every challenge and public pot:
-- who's on whom, how much, and what you have riding on it. Cancel until the duel starts;
-- pay or confirm payments once it's decided.

local ROWS = 15
local ROW_HEIGHT = 22
local SHOW_FINISHED_DAYS = 3 -- finished pots and challenges stay in the list this long

local COLUMNS = {
    { key = "status", label = "Status", width = 62 },
    { key = "what",   label = "",       width = 250 },
    { key = "pot",    label = "Pot",    width = 196 },
    { key = "you",    label = "You",    width = 110 },
    { key = "action", label = "",       width = 84 },
}

local STATUS = {
    pay = "|cffff8000To pay|r",
    incoming = "|cff20ff20Incoming|r",
    challenge = "|cffffd100Challenge|r",
    accepted = "|cff3fc6eaAccepted|r",
    declined = "|cff888888Declined|r",
    cancelled = "|cff888888Cancelled|r",
    open = "|cffffd100Open|r",
    settled = "|cffff8000Unpaid|r",
    paid = "|cff20ff20Paid|r",
    void = "|cff888888Void|r",
    expired = "|cff888888Expired|r",
}

local tbl, summary, footer

local function Name(key) return UI.Name(key, true) end
local Money = Compat.MoneyText

local function Versus(pool)
    return ("%s vs %s"):format(Name(pool.a), Name(pool.b))
end

local function PotText(pool)
    local ta, ca, tb, cb = Bets.Pot(pool)
    if ca + cb == 0 then return "|cff888888nothing in it|r" end
    if pool.challenge then return Money(ta + tb) .. " total" end
    return ("%s %s (%d)  -  %s %s (%d)"):format(Compat.DisplayName(pool.a), Money(ta), ca, Compat.DisplayName(pool.b), Money(tb), cb)
end

-- An open challenge as seen by us.
local function DescribeChallenge(pool, item, me)
    local challenger, challenged = Bets.Challenger(pool), pool.challenge
    local theirs = pool.stakes[challenger]
    local amount = theirs and Money(theirs.amt) or "?"
    item.what = ("%s challenges %s for %s"):format(Name(challenger), Name(challenged), amount)
    item.status = "challenge"
    local answer = pool.stakes[challenged]

    if theirs and theirs.cancel then
        item.status, item.priority = "cancelled", 6
    elseif Bets.Declined(pool) or (answer and answer.cancel) then -- declined, or accepted then withdrew
        item.status, item.priority = "declined", 5
        if challenger == me then item.action = "Cancel" end
    elseif answer and not answer.cancel then
        item.status = "accepted"
        if me == challenger or me == challenged then item.action = "Cancel" end
    elseif challenged == me then
        item.what = ("%s challenges you for %s"):format(Name(challenger), amount)
        item.action, item.action2, item.priority = "Accept", "Decline", 1
    elseif challenger == me then
        item.action = "Cancel"
    end
    local mine = Bets.MyStake(pool)
    item.you = mine and Money(mine.amt) or "-"
end

-- The rows for one pool: its own row, plus a row per payment that involves us.
local function Describe(pool, items)
    local me = Compat.PlayerKey()
    local state = Bets.State(pool)
    local stake = pool.stakes[me]
    local mine = Bets.MyStake(pool)
    local item = { pool = pool, state = state, priority = 6, pot = PotText(pool) }

    if state == "open" then
        item.priority = 3
        if pool.challenge then
            DescribeChallenge(pool, item, me)
        else
            item.what = Versus(pool)
            item.you = mine and ("%s on %s"):format(Money(mine.amt), Compat.DisplayName(mine.side))
                or (stake and "|cff888888cancelled|r" or "-")
            if mine then
                item.action = "Cancel"
            elseif not stake then
                item.action = "Bet"
            end
        end
    else
        local net = Bets.Payouts(pool)
        local kind = pool.challenge and "challenge" or "pot"
        if state == "expired" then
            item.what = Versus(pool) .. " |cff888888- no duel|r"
        elseif state == "void" then
            local why = pool.challenge and "not accepted" or "one-sided"
            item.what = ("%s beat %s |cff888888- %s, no payout|r"):format(Name(pool.res), Name(Bets.Other(pool, pool.res)), why)
        else
            item.what = ("%s beat %s |cff888888(%s)|r"):format(Name(pool.res), Name(Bets.Other(pool, pool.res)), kind)
            item.priority = state == "settled" and 4 or 5
        end
        local result = net and net[me]
        if result and result > 0 then
            item.you = "|cff20ff20+" .. Money(result) .. "|r"
        elseif result and result < 0 then
            item.you = "|cffff4040-" .. Money(-result) .. "|r"
        else
            item.you = "-"
        end

        for _, t in ipairs(Bets.Transfers(pool)) do
            if not t.paid and (t.from == me or t.to == me) then
                local payer = t.from == me
                items[#items + 1] = {
                    pool = pool, transfer = t, priority = 1,
                    status = payer and "pay" or "incoming",
                    what = payer and ("You owe %s"):format(Name(t.to)) or ("%s owes you"):format(Name(t.from)),
                    pot = ("%s beat %s"):format(Compat.DisplayName(pool.res), Compat.DisplayName(Bets.Other(pool, pool.res))),
                    you = Money(t.copper),
                    action = payer and "Pay" or "Got it",
                }
            end
        end
    end
    item.status = item.status or state
    items[#items + 1] = item
end

local function DoAction(item, which)
    local pool = item.pool
    local action = which == 2 and item.action2 or item.action
    if action == "Bet" then
        UI:OpenBetPopup(pool.a, pool.b)
    elseif action == "Accept" then
        local theirs = pool.stakes[Bets.Challenger(pool)]
        UI.Confirm(("Accept %s's challenge for %s?\n\nYou put in the same amount, and whoever wins your next duel takes it all. You can cancel until the duel starts."):format(
            Compat.DisplayName(Bets.Challenger(pool)), Money(theirs.amt)), function()
            UI.Report(Bets:Accept(pool.id))
        end)
    elseif action == "Decline" then
        UI.Report(Bets:Decline(pool.id))
    elseif action == "Cancel" then
        local mine = Bets.MyStake(pool)
        local text = pool.challenge and ("Cancel your %s challenge?"):format(Money(mine.amt))
            or ("Cancel your %s bet on %s?"):format(Money(mine.amt), Compat.DisplayName(mine.side))
        UI.Confirm(text, function() UI.Report(Bets:Cancel(pool.id)) end)
    elseif action == "Pay" then
        Bets:Pay(pool.id, item.transfer.to)
    elseif action == "Got it" then
        local t = item.transfer
        UI.Confirm(("Did %s pay you %s?"):format(Compat.DisplayName(t.from), Money(t.copper)), function()
            UI.Report(Bets:MarkPaid(pool.id, t.from))
        end)
    end
end

local function Build(content)
    summary = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    summary:SetPoint("TOPLEFT", 0, 0)
    summary:SetJustifyH("LEFT")

    tbl = UI.CreateTable(content, COLUMNS, ROWS, {
        top = 24, rowHeight = ROW_HEIGHT,
        onScroll = function() UI:RequestRefresh() end,
    })
    local actionCol, youCol = COLUMNS[#COLUMNS], COLUMNS[#COLUMNS - 1]
    for _, row in ipairs(tbl.rows) do
        row.button = UI.Button(row, "", actionCol.width, function(self)
            if self:GetParent().item then DoAction(self:GetParent().item, 1) end
        end)
        row.button:SetHeight(20)
        row.button:SetPoint("LEFT", row, "LEFT", actionCol.x, 0)
        -- Second button (Decline) sits in the "You" column, which is empty for those rows.
        row.button2 = UI.Button(row, "", youCol.width - 10, function(self)
            if self:GetParent().item then DoAction(self:GetParent().item, 2) end
        end)
        row.button2:SetHeight(20)
        row.button2:SetPoint("LEFT", row, "LEFT", youCol.x, 0)
    end

    footer = UI.CreateFooter(content, 2)
    footer:SetText("Challenges are one-on-one. Public pots are shared: the winners split the losers' money by how much they bet. "
        .. "Cancel any time before the duel starts. DuelLadder never moves money - Pay fills in a trade or mail, and the winner clicks Got it.")
    footer:SetWordWrap(true)
end

local function Refresh()
    local items = {}
    local cutoff = Compat.Now() - SHOW_FINISHED_DAYS * 86400
    for _, pool in pairs(Bets:All()) do
        local state = Bets.State(pool)
        local finished = state == "paid" or state == "void" or state == "expired"
        if not finished or (pool.rs or pool.t) > cutoff then Describe(pool, items) end
    end
    table.sort(items, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return a.pool.t > b.pool.t
    end)

    tbl:Fill(items, function(row, item)
        local c = row.cells
        c.status:SetText(STATUS[item.status] or item.status)
        c.what:SetText(item.what)
        c.pot:SetText("|cffaaaaaa" .. item.pot .. "|r")
        c.you:SetText(item.action2 and "" or item.you)
        row.button:SetShown(item.action ~= nil)
        if item.action then row.button:SetText(item.action) end
        row.button2:SetShown(item.action2 ~= nil)
        if item.action2 then row.button2:SetText(item.action2) end
        row.selectedTex:SetShown(item.priority == 1)
    end)

    if not Data.guild then
        summary:SetText("You need to be in a guild to bet.")
        return
    end
    local total, owedToMe, iOwe = Bets:Balance()
    local totalText = total >= 0 and ("|cff20ff20+%s|r"):format(Money(total)) or ("|cffff4040-%s|r"):format(Money(-total))
    local parts = { "Your betting total: " .. totalText }
    if owedToMe > 0 then parts[#parts + 1] = "people owe you " .. Money(owedToMe) end
    if iOwe > 0 then parts[#parts + 1] = "|cffff4040you owe " .. Money(iOwe) .. "|r" end
    if #items == 0 then parts[#parts + 1] = "|cff888888nothing yet - bet from Matchups, challenge from Members|r" end
    summary:SetText(table.concat(parts, "   -   "))
end

UI:AddTab("Bets", Build, Refresh)

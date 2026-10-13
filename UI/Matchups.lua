local _, ns = ...
local Compat, Data, UI = ns.Compat, ns.Data, ns.UI

-- Matchups tab: every rivalry in the guild as one line, read like a scoreboard:
--   Anna  3 [=======---] 1  Bo     4 duels, 2 h ago     [Bet]
-- Most-played first. "Bet" puts gold on the pair's next duel; the picker at the bottom
-- does the same for two people who haven't fought yet.

local ROWS = 11
local ROW_HEIGHT = 28
local TOP = 40            -- below the explanation
local BAR_WIDTH = 140

-- x positions inside a row (the content area is 736 wide)
local X = {
    nameA = 0,    nameW = 150,
    scoreA = 156, scoreW = 24,
    bar = 186,                       -- BAR_WIDTH wide
    scoreB = 332,
    nameB = 362,  nameBW = 140,
    info = 508,   infoW = 150,
    bet = 664,                       -- 70 wide
}

local rows = {}
local offset = 0
local intro, empty, footer
local pickA, pickB
local popup

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- a's record against b, from whichever copy has it.
local function RecordBetween(a, b)
    local entries = Data:Entries()
    local ea, eb = entries[a], entries[b]
    local r = ea and ea.h2h[b]
    if r then return r.w, r.l end
    r = eb and eb.h2h[a]
    if r then return r.l, r.w end
    return 0, 0
end

-- When a and b last fought, from either side's recent duels.
local function LastDuel(a, b)
    local entries, last = Data:Entries(), nil
    for _, pair in ipairs({ { a, b }, { b, a } }) do
        local e = entries[pair[1]]
        if e then
            for _, r in ipairs(e.recent) do
                if r.o == pair[2] and (not last or r.t > last) then last = r.t end
            end
        end
    end
    return last
end

-- Gold in the open betting pool on this pair (0 if none).
local function OpenPot(a, b)
    local pool = ns.Bets:OpenPool(a, b)
    if not pool then return 0 end
    local ta, _, tb = ns.Bets.Pot(pool)
    return ta + tb
end

local function ClassRGB(key)
    local colors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
    local c = colors and colors[Data:ClassOf(key)]
    if c then return c.r, c.g, c.b end
    return 0.6, 0.6, 0.6
end

local function LeaderText(a, b, wa, wb)
    if wa == wb then return ("All square at %d - %d"):format(wa, wb) end
    local leader = wa > wb and a or b
    return ("%s leads %d - %d"):format(Compat.DisplayName(leader), math.max(wa, wb), math.min(wa, wb))
end

-- Every pair of current guild members who have dueled, most duels first.
-- The player with the better record goes on the left.
local function BuildPairs()
    local seen, list = {}, {}
    local entries = Data:Entries()
    for _, key in ipairs(Data:Members()) do
        for opp in pairs(entries[key].h2h) do
            local a, b = key, opp
            if b < a then a, b = b, a end
            local id = a .. "|" .. b
            if not seen[id] and Data:IsGuildMember(opp) then
                seen[id] = true
                local wa, wb = RecordBetween(a, b)
                if wa + wb > 0 then
                    if wb > wa then a, b, wa, wb = b, a, wb, wa end
                    list[#list + 1] = { a = a, b = b, wa = wa, wb = wb, last = LastDuel(a, b) or 0 }
                end
            end
        end
    end
    table.sort(list, function(x, y)
        if x.wa + x.wb ~= y.wa + y.wb then return x.wa + x.wb > y.wa + y.wb end
        return x.last > y.last
    end)
    return list
end

------------------------------------------------------------------------
-- Bet popup
------------------------------------------------------------------------

local function PotLine(pool)
    local ta, ca, tb, cb = 0, 0, 0, 0
    if pool then ta, ca, tb, cb = ns.Bets.Pot(pool) end
    if ca + cb == 0 then return "No bets on their next duel yet. Be the first!" end
    local function Side(key, total, count)
        return ("%s %s (%d bet%s)"):format(Compat.DisplayName(key), Compat.MoneyText(total), count, count == 1 and "" or "s")
    end
    return "Pot:  " .. Side(pool.a, ta, ca) .. "    " .. Side(pool.b, tb, cb)
end

local function UpdatePreview()
    if not popup or not popup.pick then return end
    local copper = popup.money:GetCopper()
    if copper < ns.Bets.MIN_COPPER then
        popup.preview:SetText("")
        return
    end
    local free = ns.Bets:Available()
    if copper > free then
        local committed = ns.Bets:Committed()
        popup.preview:SetText(committed > 0
            and ("|cffff4040You only have %s free to bet|r - %s is already riding on other bets or owed."):format(
                Compat.MoneyText(free), Compat.MoneyText(committed))
            or ("|cffff4040You only have %s.|r"):format(Compat.MoneyText(free)))
        return
    end
    local pool = ns.Bets:OpenPool(popup.a, popup.b)
    local back = pool and ns.Bets.PreviewReturn(pool, popup.pick, copper) or copper
    local profit = back - copper
    if profit > 0 then
        popup.preview:SetText(("If %s wins (with the pot as it is now) you get your %s back |cff20ff20+ %s|r"):format(
            Compat.DisplayName(popup.pick), Compat.MoneyText(copper), Compat.MoneyText(profit)))
    else
        popup.preview:SetText(("Nobody is on %s yet - you only win something once someone bets on them."):format(
            Compat.DisplayName(ns.Bets.Other(popup, popup.pick))))
    end
end

local function SetPick(key)
    popup.pick = key
    for _, b in ipairs({ popup.backA, popup.backB }) do
        if b.key == key then b:LockHighlight() else b:UnlockHighlight() end
    end
    UpdatePreview()
end

local function PlaceBet()
    local copper = popup.money:GetCopper()
    if copper < ns.Bets.MIN_COPPER then
        ns.Print("Enter how much gold and silver to bet.")
        return
    end
    popup.money:ClearFocus()
    local a, b, pick = popup.a, popup.b, popup.pick
    local other = ns.Bets.Other(popup, pick)
    UI.Confirm(("Bet %s on %s to beat %s?\n\nAll bets on this duel go into one pot. If %s wins, the winners split the losers' money by how much they bet. You can cancel until the duel starts."):format(
        Compat.MoneyText(copper), Compat.DisplayName(pick), Compat.DisplayName(other), Compat.DisplayName(pick)), function()
        local id, err = ns.Bets:Place(a, b, pick, copper)
        if UI.Report(id, err) then
            ns.Print("Bet placed. You'll see it in the Bets tab.")
            popup:Hide()
        end
    end)
end

local function CancelBet()
    local pool = ns.Bets:OpenPool(popup.a, popup.b)
    if not pool then return end
    if UI.Report(ns.Bets:Cancel(pool.id)) then
        ns.Print("Your bet is cancelled. (If their duel had already started, it still counts.)")
        popup:Hide()
    end
end

local function CreatePopup(parent)
    local template = Compat.HasTemplate("BasicFrameTemplateWithInset")
        and "BasicFrameTemplateWithInset" or "BasicFrameTemplate"
    popup = CreateFrame("Frame", "DuelLadderBetPopup", parent, template)
    popup:SetSize(380, 230)
    popup:SetPoint("CENTER")
    popup:SetFrameStrata("DIALOG")
    popup:EnableMouse(true)
    popup:Hide()

    popup.title = popup:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    popup.title:SetPoint("TOP", 0, -5)

    local function Line(parentFrame, font, y)
        local fs = parentFrame:CreateFontString(nil, "OVERLAY", font)
        fs:SetPoint("TOP", popup, "TOP", 0, y)
        fs:SetWidth(350)
        return fs
    end
    popup.hint = Line(popup, "GameFontHighlightSmall", -32)
    popup.pot = Line(popup, "GameFontNormalSmall", -48)

    -- Placing a bet
    popup.place = CreateFrame("Frame", nil, popup)
    popup.place:SetAllPoints()
    popup.backA = UI.Button(popup.place, "", 140, function(self) if self:IsEnabled() then SetPick(self.key) end end)
    popup.backA:SetPoint("TOPRIGHT", popup, "TOP", -5, -70)
    popup.backB = UI.Button(popup.place, "", 140, function(self) if self:IsEnabled() then SetPick(self.key) end end)
    popup.backB:SetPoint("TOPLEFT", popup, "TOP", 5, -70)

    popup.money = UI.MoneyBox(popup.place)
    popup.money:SetPoint("TOP", popup, "TOP", 0, -104)
    popup.money:SetCopper(10 * 10000)
    popup.money:SetOnChange(UpdatePreview)

    popup.preview = Line(popup.place, "GameFontHighlightSmall", -132)
    popup.note = Line(popup.place, "GameFontDisableSmall", -156)

    local place = UI.Button(popup.place, "Place bet", 110, PlaceBet)
    place:SetPoint("BOTTOM", popup, "BOTTOM", 0, 12)

    -- Already bet: show it and offer to cancel
    popup.mine = CreateFrame("Frame", nil, popup)
    popup.mine:SetAllPoints()
    popup.mineText = Line(popup.mine, "GameFontHighlight", -84)
    local cancelNote = Line(popup.mine, "GameFontDisableSmall", -112)
    cancelNote:SetText("You can cancel until the duel starts. Once it has started, your bet stands.")
    popup.cancel = UI.Button(popup.mine, "Cancel my bet", 130, CancelBet)
    popup.cancel:SetPoint("BOTTOM", popup, "BOTTOM", 0, 12)
end

-- Fills the popup for popup.a vs popup.b from the current pot. keepPick keeps the fighter
-- the player picked (when the pot changes while the popup is open).
local function FillPopup(keepPick)
    local a, b = popup.a, popup.b
    popup.title:SetText(("Bet on %s vs %s"):format(Compat.DisplayName(a), Compat.DisplayName(b)))
    local wa, wb = RecordBetween(a, b)
    popup.hint:SetText(wa + wb > 0 and (LeaderText(a, b, wa, wb) .. ".") or "They haven't dueled yet.")

    local pool = ns.Bets:OpenPool(a, b)
    popup.pot:SetText(PotLine(pool))

    local stake = pool and pool.stakes[Compat.PlayerKey()]
    if stake then
        popup.place:Hide()
        popup.mine:Show()
        popup.mineText:SetText(stake.cancel and "You cancelled your bet on this duel."
            or ("You have |cffffffff%s|r on %s."):format(Compat.MoneyText(stake.amt), Compat.DisplayName(stake.side)))
        popup.cancel:SetShown(not stake.cancel)
        return
    end
    popup.mine:Hide()
    popup.place:Show()

    popup.backA.key, popup.backB.key = a, b
    popup.backA:SetText(Compat.DisplayName(a))
    popup.backB:SetText(Compat.DisplayName(b))

    -- Fighters can only back themselves.
    local me = Compat.PlayerKey()
    local fighting = me == a or me == b
    popup.backA:SetEnabled(not fighting or me == a)
    popup.backB:SetEnabled(not fighting or me == b)
    popup.note:SetText(fighting and "You're in this one, so you can only bet on yourself."
        or "All bets go into one pot; the winners split the losers' money by how much they bet.")
    local pick = keepPick and popup.pick
    if (pick ~= a and pick ~= b) or (fighting and pick ~= me) then pick = (fighting and me) or a end
    SetPick(pick)
end

-- Opens the popup for the public pot on the next duel between a and b.
function UI:OpenBetPopup(a, b)
    if not popup then CreatePopup(UI.frame) end
    popup.a, popup.b = a, b
    FillPopup(false)
    popup:Show()
end

-- Someone bet or cancelled while the popup is open: show the pot as it is now.
ns:On("BETS_CHANGED", function()
    if popup and popup:IsShown() then FillPopup(true) end
end)

------------------------------------------------------------------------
-- Rows
------------------------------------------------------------------------

local function RowEnter(self)
    local p = self.pair
    if not p then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(UI.Name(p.a, true) .. "  vs  " .. UI.Name(p.b, true))
    GameTooltip:AddLine(LeaderText(p.a, p.b, p.wa, p.wb), 1, 1, 1)
    GameTooltip:AddLine(("%s wins %d%% of their duels"):format(Compat.DisplayName(p.a),
        math.floor(p.wa / (p.wa + p.wb) * 100 + 0.5)), 0.8, 0.8, 0.8)
    if p.last > 0 then GameTooltip:AddLine("Last duel " .. UI.Ago(p.last), 0.8, 0.8, 0.8) end
    GameTooltip:AddLine("Click Bet to put gold on their next duel", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function CreateRow(content, i)
    local row = CreateFrame("Frame", nil, content)
    row:SetSize(UI.CONTENT_WIDTH, ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -TOP - (i - 1) * ROW_HEIGHT)
    row:EnableMouse(true)
    row:SetScript("OnEnter", RowEnter)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local stripe = row:CreateTexture(nil, "BACKGROUND")
    stripe:SetAllPoints()
    stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0)

    local function Text(font, x, width, justify)
        local fs = row:CreateFontString(nil, "OVERLAY", font)
        fs:SetPoint("LEFT", x, 0)
        fs:SetWidth(width)
        fs:SetJustifyH(justify)
        fs:SetWordWrap(false)
        return fs
    end
    row.nameA = Text("GameFontHighlight", X.nameA, X.nameW, "RIGHT")
    row.scoreA = Text("GameFontNormalLarge", X.scoreA, X.scoreW, "RIGHT")
    row.scoreB = Text("GameFontNormalLarge", X.scoreB, X.scoreW, "LEFT")
    row.nameB = Text("GameFontHighlight", X.nameB, X.nameBW, "LEFT")
    row.info = Text("GameFontHighlightSmall", X.info, X.infoW, "LEFT")

    row.barBg = row:CreateTexture(nil, "ARTWORK")
    row.barBg:SetColorTexture(0, 0, 0, 0.5)
    row.barBg:SetSize(BAR_WIDTH, 10)
    row.barBg:SetPoint("LEFT", X.bar, 0)
    row.barA = row:CreateTexture(nil, "OVERLAY")
    row.barA:SetHeight(10)
    row.barA:SetPoint("LEFT", row.barBg, "LEFT")
    row.barB = row:CreateTexture(nil, "OVERLAY")
    row.barB:SetHeight(10)
    row.barB:SetPoint("RIGHT", row.barBg, "RIGHT")

    row.bet = UI.Button(row, "Bet", 70, function(self)
        local p = self:GetParent().pair
        if p then UI:OpenBetPopup(p.a, p.b) end
    end)
    row.bet:SetPoint("LEFT", X.bet, 0)
    return row
end

local function FillRow(row, p)
    row.pair = p
    local dotA = Data:IsOnline(p.a) and UI.ONLINE_DOT or UI.OFFLINE_DOT
    local dotB = Data:IsOnline(p.b) and UI.ONLINE_DOT or UI.OFFLINE_DOT
    row.nameA:SetText(UI.Name(p.a) .. " " .. dotA)
    row.nameB:SetText(dotB .. " " .. UI.Name(p.b))
    row.scoreA:SetText(p.wa)
    row.scoreB:SetText(p.wb)

    local share = p.wa / (p.wa + p.wb)
    local widthA = math.floor(BAR_WIDTH * share + 0.5)
    row.barA:SetColorTexture(ClassRGB(p.a))
    row.barB:SetColorTexture(ClassRGB(p.b))
    row.barA:SetWidth(math.max(widthA, 0.01))
    row.barB:SetWidth(math.max(BAR_WIDTH - widthA, 0.01))
    row.barA:SetShown(widthA > 0)
    row.barB:SetShown(widthA < BAR_WIDTH)

    local info = ("%d duel%s"):format(p.wa + p.wb, p.wa + p.wb == 1 and "" or "s")
    if p.last > 0 then info = info .. ", " .. UI.Ago(p.last) end
    local pot = OpenPot(p.a, p.b)
    if pot > 0 then info = info .. ", |cffffd100pot|r " .. Compat.MoneyText(pot) end
    row.info:SetText(info)
end

------------------------------------------------------------------------
-- Picker: bet on any two members
------------------------------------------------------------------------

local function PickerButton(parent, onPick)
    local b = UI.Button(parent, "", 140, nil)
    b:SetScript("OnClick", function(self)
        local items = { { text = "Pick a fighter", isTitle = true } }
        for _, item in ipairs(UI:BuildList("name", false)) do
            local key = item.key
            items[#items + 1] = { text = UI.Name(key, true), func = function()
                onPick(key)
                UI:RequestRefresh()
            end }
        end
        Compat.ContextMenu(self, items)
    end)
    return b
end

------------------------------------------------------------------------
-- Tab
------------------------------------------------------------------------

local function Build(content)
    intro = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", 0, 0)
    intro:SetPoint("TOPRIGHT", 0, 0)
    intro:SetJustifyH("LEFT")
    intro:SetText("Every rivalry in the guild, most-played first. The bigger number is the player who's ahead; "
        .. "the bar shows how the wins are split. Click |cffffd100Bet|r to put gold on their next duel.")

    for i = 1, ROWS do rows[i] = CreateRow(content, i) end

    empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("TOP", 0, -TOP - 40)
    empty:SetText("No duels between guild members yet. Go challenge someone!")

    content:EnableMouseWheel(true)
    content:SetScript("OnMouseWheel", function(_, delta)
        offset = offset - delta * 3
        UI:RequestRefresh()
    end)

    -- Bottom bar: "Bet on any duel: [A] vs [B] [Bet]"
    local label = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("BOTTOMLEFT", 0, 28)
    label:SetText("Bet on any duel:")
    pickA = PickerButton(content, function(key)
        pickA.key = key
        if pickB.key == key then pickB.key = nil end
    end)
    pickA:SetPoint("LEFT", label, "RIGHT", 10, 0)
    local vs = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    vs:SetPoint("LEFT", pickA, "RIGHT", 8, 0)
    vs:SetText("vs")
    pickB = PickerButton(content, function(key)
        pickB.key = key
        if pickA.key == key then pickA.key = nil end
    end)
    pickB:SetPoint("LEFT", vs, "RIGHT", 8, 0)
    local go = UI.Button(content, "Bet", 70, function()
        if pickA.key and pickB.key then
            UI:OpenBetPopup(pickA.key, pickB.key)
        else
            ns.Print("Pick two fighters first.")
        end
    end)
    go:SetPoint("LEFT", pickB, "RIGHT", 10, 0)
    pickA.key = Compat.PlayerKey()

    footer = UI.CreateFooter(content, 2)
end

local function Refresh()
    local list = BuildPairs()
    offset = math.max(0, math.min(offset, #list - ROWS))
    for i, row in ipairs(rows) do
        local p = list[i + offset]
        if p then
            FillRow(row, p)
            row:Show()
        else
            row.pair = nil
            row:Hide()
        end
    end
    empty:SetShown(#list == 0)

    pickA:SetText(pickA.key and UI.Name(pickA.key, true) or "|cff888888choose...|r")
    pickB:SetText(pickB.key and UI.Name(pickB.key, true) or "|cff888888choose...|r")

    if #list > ROWS then
        footer:SetText(("Showing %d-%d of %d rivalries. Scroll for more."):format(offset + 1, math.min(#list, offset + ROWS), #list))
    else
        footer:SetText(UI.ONLINE_DOT .. " online   " .. UI.OFFLINE_DOT .. " offline")
    end
end

UI:AddTab("Matchups", Build, Refresh)

local _, ns = ...
local Compat, Data, UI = ns.Compat, ns.Data, ns.UI
local T, Bets = ns.Tournament, ns.Bets

-- Tournament tab. During sign-ups: who's in, in seed order (by rating), with the champion
-- pot. Once it has started: the bracket, drawn like a sports bracket with the winners moving
-- right towards the champion. "Bets" lists every pot in the tournament with what you have
-- riding on it and any payments.

local W = UI.CONTENT_WIDTH
local TOP = 50                -- below the header
local BRACKET_HEIGHT = 350
local BOX_HEIGHT = 32
local LINE = 2
local SIGNUP_ROWS = 16
local BET_ROWS = 14

local Money = Compat.MoneyText
local function Short(key) return Compat.DisplayName(key) end

local shownId                 -- tournament on screen; nil = the latest
local mode = "bracket"        -- "bracket" or "bets", once it has started
local title, sub, footer, empty
local actionButtons = {}
local signup, bracket, betsView
local signupTable, betsTable
local boxes, lines, champBox = {}, {}, nil
local popup

local function Current()
    local all = T:All()
    return (shownId and all[shownId]) or T:Latest()
end

-- "Anna 10g (2)  -  Bo 5g (1)" for a match, "40g from 4 bets" for the champion pot.
local function PotText(view)
    local sides = T.Sides(view)
    local total, count = 0, 0
    for _, x in pairs(sides) do total, count = total + x.amt, count + x.count end
    if count == 0 then return "|cff888888no bets|r" end
    local m = view.match
    if not m then return ("%s from %d bet%s"):format(Money(total), count, count == 1 and "" or "s") end
    local function Side(key)
        local x = sides[key] or { amt = 0, count = 0 }
        return ("%s %s (%d)"):format(Short(key), Money(x.amt), x.count)
    end
    return Side(m.a) .. "  -  " .. Side(m.b)
end

------------------------------------------------------------------------
-- Bet popup
------------------------------------------------------------------------

local function UpdatePreview()
    if not popup or not popup.pick then return end
    local t = T:All()[popup.tid]
    local copper = popup.money:GetCopper()
    if not t or copper < Bets.MIN_COPPER then
        popup.preview:SetText("")
        return
    end
    local profit = T.PreviewReturn(T.Pot(t, popup.mid), popup.pick, copper) - copper
    if profit > 0 then
        popup.preview:SetText(("If %s wins (with the pot as it is now) you get your %s back |cff20ff20+ %s|r"):format(
            Short(popup.pick), Money(copper), Money(profit)))
    else
        popup.preview:SetText("Nobody has bet against them yet - you only win something once someone does.")
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
    if copper < Bets.MIN_COPPER then
        ns.Print("Enter how much gold and silver to bet.")
        return
    end
    popup.money:ClearFocus()
    local tid, mid, pick = popup.tid, popup.mid, popup.pick
    local what = mid == T.CHAMPION and ("%s to win the tournament"):format(Short(pick)) or ("%s to win this match"):format(Short(pick))
    UI.Confirm(("Bet %s on %s?\n\nThe winners split the losers' money by how much they bet. You can cancel until betting closes."):format(
        Money(copper), what), function()
        if UI.Report(T:Bet(tid, mid, pick, copper)) then
            ns.Print("Bet placed. You'll see it under Tournament > Bets.")
            popup:Hide()
        end
    end)
end

local function CancelBet()
    if UI.Report(T:CancelBet(popup.tid, popup.mid)) then
        ns.Print("Your bet is cancelled.")
        popup:Hide()
    end
end

local function CreatePopup()
    popup = CreateFrame("Frame", "DuelLadderTourneyBetPopup", UI.frame, "BasicFrameTemplateWithInset")
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

    popup.place = CreateFrame("Frame", nil, popup)
    popup.place:SetAllPoints()
    popup.backA = UI.Button(popup.place, "", 140, function(self) if self:IsEnabled() then SetPick(self.key) end end)
    popup.backB = UI.Button(popup.place, "", 140, function(self) if self:IsEnabled() then SetPick(self.key) end end)
    popup.backB:SetPoint("TOPLEFT", popup, "TOP", 5, -70)
    popup.money = UI.MoneyBox(popup.place)
    popup.money:SetPoint("TOP", popup, "TOP", 0, -104)
    popup.money:SetCopper(10 * 10000)
    popup.money:SetOnChange(UpdatePreview)
    popup.preview = Line(popup.place, "GameFontHighlightSmall", -132)
    popup.note = Line(popup.place, "GameFontDisableSmall", -156)
    UI.Button(popup.place, "Place bet", 110, PlaceBet):SetPoint("BOTTOM", popup, "BOTTOM", 0, 12)

    popup.mine = CreateFrame("Frame", nil, popup)
    popup.mine:SetAllPoints()
    popup.mineText = Line(popup.mine, "GameFontHighlight", -84)
    popup.mineNote = Line(popup.mine, "GameFontDisableSmall", -112)
    popup.cancel = UI.Button(popup.mine, "Cancel my bet", 130, CancelBet)
    popup.cancel:SetPoint("BOTTOM", popup, "BOTTOM", 0, 12)
end

-- Opens the popup for a pot. For the champion pot, `side` is who you'd be backing.
local function OpenPopup(t, mid, side)
    if not popup then CreatePopup() end
    local me = Compat.PlayerKey()
    local view = T.Pot(t, mid)
    popup.tid, popup.mid = t.id, mid
    popup.pot:SetText("Pot:  " .. PotText(view))

    local a, b
    if mid == T.CHAMPION then
        popup.title:SetText("Bet on the champion of " .. t.name)
        popup.hint:SetText("Who wins it all? Betting closes when the host presses Start.")
        a = side
    else
        local m = view.match
        local rounds = T.Bracket(t).rounds
        popup.title:SetText(("Bet on %s vs %s"):format(Short(m.a), Short(m.b)))
        popup.hint:SetText(T.RoundName(m.r, rounds) .. (m.need > 1 and " - best of three. Betting closes when the first duel starts."
            or " - their next duel decides it. Betting closes when it starts."))
        a, b = m.a, m.b
    end

    local stake = t.pots[mid] and t.pots[mid].stakes[me]
    if stake then
        popup.place:Hide()
        popup.mine:Show()
        popup.mineText:SetText(stake.cancel and "You cancelled your bet on this."
            or ("You have |cffffffff%s|r on %s."):format(Money(stake.amt), Short(stake.side)))
        local open = view.state == "open"
        popup.cancel:SetShown(open and not stake.cancel)
        popup.mineNote:SetText(open and "You can cancel until betting closes." or "Betting has closed, so your bet stands.")
        popup:Show()
        return
    end
    popup.mine:Hide()
    popup.place:Show()

    popup.backA.key, popup.backB.key = a, b
    popup.backA:SetText(Short(a))
    popup.backA:ClearAllPoints()
    if b then
        popup.backA:SetPoint("TOPRIGHT", popup, "TOP", -5, -70)
        popup.backB:SetText(Short(b))
        popup.backB:Show()
    else
        popup.backA:SetPoint("TOP", popup, "TOP", 0, -70)
        popup.backB:Hide()
    end
    local playing = me == a or me == b or (mid == T.CHAMPION and T.IsIn(t, me))
    popup.backA:SetEnabled(not playing or me == a)
    popup.backB:SetEnabled(not playing or me == b)
    popup.note:SetText(playing and "You're playing, so you can only bet on yourself."
        or "All bets go into one pot; the winners split the losers' money by how much they bet.")
    SetPick((playing and me) or a)
    popup:Show()
end

------------------------------------------------------------------------
-- Header actions
------------------------------------------------------------------------

StaticPopupDialogs["DUELLADDER_NEW_TOURNAMENT"] = {
    text = "Name your tournament:",
    button1 = "Create",
    button2 = CANCEL or "Cancel",
    hasEditBox = 1,
    maxLetters = 32,
    OnAccept = function(self)
        local box = self.editBox or self.EditBox
        local id, err = T:Create(box and box:GetText() or "")
        if UI.Report(id, err) then
            shownId = id
            ns.Print("Tournament created. Guild members can join from the Tournament tab; press Start when everyone's in.")
        end
    end,
    EditBoxOnEnterPressed = function(self)
        local dialog = self:GetParent()
        StaticPopupDialogs.DUELLADDER_NEW_TOURNAMENT.OnAccept(dialog)
        dialog:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function New()
    StaticPopup_Show("DUELLADDER_NEW_TOURNAMENT")
end

local function ShowList(owner)
    local list = {}
    for _, t in pairs(T:All()) do list[#list + 1] = t end
    table.sort(list, function(x, y) return x.t > y.t end)
    local items = { { text = "Tournaments", isTitle = true } }
    for _, t in ipairs(list) do
        local status = T.Status(t)
        items[#items + 1] = { text = ("%s |cff888888(%s, %s)|r"):format(t.name, status, UI.Ago(t.t)), func = function()
            shownId = t.id
            UI:RequestRefresh()
        end }
    end
    Compat.ContextMenu(owner, items)
end

-- The buttons in the top right for this tournament, right to left.
local function Actions(t, status)
    local me = Compat.PlayerKey()
    local list = {}
    local count = 0
    for _ in pairs(T:All()) do count = count + 1 end
    if count > 1 then list[#list + 1] = { text = "Tournaments", width = 100, fn = ShowList } end
    local latest = T:Latest()
    local latestStatus = latest and T.Status(latest)
    if latestStatus ~= "signup" and latestStatus ~= "running" then
        list[#list + 1] = { text = "New tournament", width = 120, fn = New }
    end
    if not t then return list end
    if T.Started(t) then
        list[#list + 1] = { text = mode == "bets" and "Bracket" or "Bets", width = 80, fn = function()
            mode = mode == "bets" and "bracket" or "bets"
            UI:RequestRefresh()
        end }
    end
    if t.host == me and (status == "signup" or status == "running") then
        list[#list + 1] = { text = "Cancel", width = 70, fn = function()
            UI.Confirm(("Cancel %s?\n\nBets on matches that haven't been decided are void."):format(t.name), function()
                UI.Report(T:Cancel(t.id))
            end)
        end }
    end
    if status == "signup" then
        if t.host == me then
            list[#list + 1] = { text = "Start", width = 70, fn = function()
                local n = #T.Entrants(t)
                UI.Confirm(("Start %s with %d players?\n\nSign-ups close, the bracket is seeded by ladder rating and bets on the champion are locked."):format(
                    t.name, n), function() UI.Report(T:Start(t.id)) end)
            end }
        end
        local j = t.joins[me]
        if j and not j.out then
            list[#list + 1] = { text = "Leave", width = 70, fn = function() UI.Report(T:Leave(t.id)) end }
        else
            list[#list + 1] = { text = "Join", width = 70, fn = function() UI.Report(T:Join(t.id)) end }
        end
    end
    return list
end

local function LayoutActions(list)
    local x = 0
    for i, button in ipairs(actionButtons) do
        local spec = list[i]
        if spec then
            button.fn = spec.fn
            button:SetText(spec.text)
            button:SetWidth(spec.width)
            button:ClearAllPoints()
            button:SetPoint("TOPRIGHT", -x, 0)
            button:Show()
            x = x + spec.width + 4
        else
            button:Hide()
        end
    end
end

------------------------------------------------------------------------
-- Sign-ups
------------------------------------------------------------------------

local SIGNUP_COLUMNS = {
    { key = "seed",   label = "#",            width = 22, align = "RIGHT" },
    { key = "name",   label = "Player",       width = 180 },
    { key = "rating", label = "Rating",       width = 50, align = "RIGHT" },
    { key = "joined", label = "Joined",       width = 90 },
    { key = "pot",    label = "Champion pot", width = 150 },
    { key = "you",    label = "Your bet",     width = 110 },
    { key = "action", label = "",             width = 80 },
}

local function SignupAction(item)
    local t = Current()
    if t then OpenPopup(t, T.CHAMPION, item.key) end
end

local function RefreshSignup(t)
    local me = Compat.PlayerKey()
    local entrants, waiting = T.Entrants(t)
    local view = T.Pot(t, T.CHAMPION)
    local sides = T.Sides(view)
    local stake = t.pots[T.CHAMPION] and t.pots[T.CHAMPION].stakes[me]
    local items = {}
    for _, key in ipairs(entrants) do items[#items + 1] = { key = key } end
    table.sort(items, function(x, y)
        local rx, ry = T.Rating(x.key), T.Rating(y.key)
        if rx ~= ry then return rx > ry end
        return x.key < y.key
    end)
    for i, item in ipairs(items) do item.seed = i end
    for _, key in ipairs(waiting) do items[#items + 1] = { key = key, waiting = true } end

    signupTable:Fill(items, function(row, item)
        local c = row.cells
        local side = sides[item.key]
        c.seed:SetText(item.seed or "-")
        c.name:SetText(item.waiting and ("|cff888888%s (waiting list)|r"):format(Short(item.key)) or UI.Name(item.key))
        c.rating:SetText(T.Rating(item.key))
        c.joined:SetText("|cffaaaaaa" .. UI.Ago(t.joins[item.key] and t.joins[item.key].t) .. "|r")
        c.pot:SetText(side and ("%s (%d)"):format(Money(side.amt), side.count) or "|cff888888-|r")
        local mine = stake and not stake.cancel and stake.side == item.key
        c.you:SetText(mine and Money(stake.amt) or "")
        local canBet = not item.waiting and not stake and (not T.IsIn(t, me) or item.key == me)
        row.button:SetShown(canBet or mine)
        row.button:SetText(mine and "Cancel" or "Bet")
    end)
    empty:SetShown(#items == 0)
    empty:SetText("Nobody has joined yet. Click Join to be the first.")
    footer:SetText("When the host presses Start, the bracket is seeded by ladder rating (the top seeds get the byes). Only duels "
        .. "after that count. Bet on the champion until then; players can only back themselves.")
end

------------------------------------------------------------------------
-- The bracket
------------------------------------------------------------------------

local LIT, DIM = { 0.85, 0.68, 0.2, 0.9 }, { 0.35, 0.35, 0.35, 0.8 }

local nextLine
local function Line(x, y, w, h, color)
    local tex = lines[nextLine]
    if not tex then
        tex = bracket:CreateTexture(nil, "ARTWORK")
        lines[nextLine] = tex
    end
    nextLine = nextLine + 1
    tex:ClearAllPoints()
    tex:SetPoint("TOPLEFT", x, -y)
    tex:SetSize(math.max(w, LINE), math.max(h, LINE))
    tex:SetColorTexture(unpack(color))
    tex:Show()
end

local function BoxEnter(self)
    local t, m = Current(), self.match
    if not t or not m then return end
    local b = T.Bracket(t)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(T.RoundName(m.r, b.rounds))
    if m.bye then
        GameTooltip:AddLine(("Bye: %s goes straight through."):format(Short(m.winner)), 1, 1, 1)
    elseif not m.open then
        GameTooltip:AddLine("Waiting for the earlier matches.", 1, 1, 1)
    else
        GameTooltip:AddLine(UI.Name(m.a, true) .. "  vs  " .. UI.Name(m.b, true))
        if m.winner then
            local how = m.walkover and " (walkover)" or (m.need > 1 and (" %d - %d"):format(math.max(m.wa, m.wb), math.min(m.wa, m.wb)) or "")
            GameTooltip:AddLine(("%s won%s"):format(Short(m.winner), how), 0.2, 1, 0.2)
        elseif m.need > 1 then
            GameTooltip:AddLine(("Best of three, first to two wins. %d - %d so far."):format(m.wa, m.wb), 1, 1, 1)
        else
            GameTooltip:AddLine("Their next duel decides it.", 1, 1, 1)
        end
        if not m.winner then GameTooltip:AddLine("Only duels after " .. UI.Ago(m.open) .. " count.", 0.8, 0.8, 0.8) end
        local view = T.Pot(t, m.id, b)
        GameTooltip:AddLine("Pot: " .. PotText(view), 0.8, 0.8, 0.8)
        local stake = t.pots[m.id] and t.pots[m.id].stakes[Compat.PlayerKey()]
        if stake and not stake.cancel then
            GameTooltip:AddLine(("You have %s on %s"):format(Money(stake.amt), Short(stake.side)), 1, 0.82, 0)
        end
        if view.state == "open" then GameTooltip:AddLine("Click to bet", 0.6, 0.6, 0.6) end
        if m.live and t.host == Compat.PlayerKey() then GameTooltip:AddLine("Right-click to award a walkover", 0.6, 0.6, 0.6) end
    end
    GameTooltip:Show()
end

local function BoxClick(self, button)
    local t, m = Current(), self.match
    if not t or not m or not m.open then return end
    if button == "RightButton" then
        if not m.live or t.host ~= Compat.PlayerKey() then return end
        local items = { { text = "Walkover: who goes through?", isTitle = true } }
        for _, key in ipairs({ m.a, m.b }) do
            items[#items + 1] = { text = Short(key), func = function()
                UI.Confirm(("Give %s a walkover? %s is out without a duel, and bets on this match are void."):format(
                    Short(key), Short(key == m.a and m.b or m.a)), function()
                    UI.Report(T:Walkover(t.id, m.id, key))
                end)
            end }
        end
        Compat.ContextMenu(self, items)
        return
    end
    local view = T.Pot(t, m.id)
    local stake = t.pots[m.id] and t.pots[m.id].stakes[Compat.PlayerKey()]
    if view.state == "open" or stake then OpenPopup(t, m.id) end
end

local function CreateBox()
    local box = CreateFrame("Button", nil, bracket)
    box:SetHeight(BOX_HEIGHT)
    box:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    box.border = box:CreateTexture(nil, "BACKGROUND")
    box.border:SetAllPoints()
    box.bg = box:CreateTexture(nil, "BORDER")
    box.bg:SetPoint("TOPLEFT", 1, -1)
    box.bg:SetPoint("BOTTOMRIGHT", -1, 1)
    box.bg:SetColorTexture(0.06, 0.06, 0.06, 0.92)
    box:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    box.names, box.scores = {}, {}
    for i = 1, 2 do
        local name = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("TOPLEFT", 5, -4 - (i - 1) * 13)
        name:SetJustifyH("LEFT")
        name:SetWordWrap(false)
        box.names[i] = name
        local score = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        score:SetPoint("TOPRIGHT", -5, -4 - (i - 1) * 13)
        score:SetJustifyH("RIGHT")
        box.scores[i] = score
    end
    box:SetScript("OnEnter", BoxEnter)
    box:SetScript("OnLeave", function() GameTooltip:Hide() end)
    box:SetScript("OnClick", BoxClick)
    return box
end

-- One player's line in a match box: seed, name and wins.
local function PlayerLine(box, i, m, key, seed, wins)
    local me = Compat.PlayerKey()
    if not key then
        box.names[i]:SetText(m.bye and "|cff555555bye|r" or "|cff555555-|r")
        box.scores[i]:SetText("")
        return
    end
    local name = Short(key)
    local seedText = ("|cff888888%d|r "):format(seed or 0)
    if m.winner and m.winner ~= key then
        box.names[i]:SetText(seedText .. "|cff777777" .. name .. "|r")
    else
        box.names[i]:SetText(seedText .. UI.Name(key, true) .. (key == me and " |cffffd100*|r" or ""))
    end
    local score = ""
    if m.walkover then
        score = m.winner == key and "|cff20ff20wo|r" or ""
    elseif m.open and not m.bye and (m.winner or m.wa + m.wb > 0) then
        score = (m.winner == key and "|cffffffff%d|r" or "|cff777777%d|r"):format(wins)
    end
    box.scores[i]:SetText(score)
end

local function FillBox(box, m, x, y, width)
    box.match = m
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", x, -(y - BOX_HEIGHT / 2))
    box:SetWidth(width)
    for i = 1, 2 do box.names[i]:SetWidth(width - 28) end
    local me = Compat.PlayerKey()
    if m.live then
        local mine = m.a == me or m.b == me
        box.border:SetColorTexture(1, mine and 0.95 or 0.82, mine and 0.5 or 0, 1)
    elseif m.winner and not m.bye then
        box.border:SetColorTexture(0.4, 0.4, 0.4, 1)
    else
        box.border:SetColorTexture(0.2, 0.2, 0.2, 1)
    end
    PlayerLine(box, 1, m, m.a, m.seedA, m.wa)
    PlayerLine(box, 2, m, m.b, m.seedB, m.wb)
    box:Show()
end

local function RefreshBracket(t)
    local b = T.Bracket(t)
    local cols = b.rounds + 1
    local colW = math.floor(W / cols)
    local boxW = math.min(170, colW - 28)
    local slot = BRACKET_HEIGHT / (b.size / 2)
    local function X(r) return (r - 1) * colW end
    local function Y(r, i) return 16 + slot * 2 ^ (r - 1) * (i - 0.5) end

    nextLine = 1
    local n = 0
    for r = 1, b.rounds do
        local label = bracket.labels[r]
        label:ClearAllPoints()
        label:SetPoint("TOPLEFT", X(r), 0)
        label:SetText(T.RoundName(r, b.rounds))
        label:Show()
        for i, m in ipairs(b.rows[r]) do
            n = n + 1
            boxes[n] = boxes[n] or CreateBox()
            FillBox(boxes[n], m, X(r), Y(r, i), boxW)
            if r > 1 then
                local x1, x2 = X(r - 1) + boxW, X(r) - math.floor((colW - boxW) / 2)
                local y1, y2 = Y(r - 1, 2 * i - 1), Y(r - 1, 2 * i)
                Line(x1, y1, x2 - x1, LINE, m.a and LIT or DIM)
                Line(x1, y2, x2 - x1, LINE, m.b and LIT or DIM)
                Line(x2, y1, LINE, y2 - y1 + LINE, DIM)
                Line(x2, Y(r, i), X(r) - x2, LINE, (m.a and m.b) and LIT or DIM)
            end
        end
    end
    for i = n + 1, #boxes do boxes[i]:Hide() end
    for r = b.rounds + 1, #bracket.labels do bracket.labels[r]:Hide() end

    -- Champion
    local cx, cy = X(b.rounds + 1), Y(b.rounds, 1)
    Line(X(b.rounds) + boxW, cy, cx - X(b.rounds) - boxW, LINE, b.champion and LIT or DIM)
    champBox:ClearAllPoints()
    champBox:SetPoint("TOPLEFT", cx, -(cy - BOX_HEIGHT / 2))
    champBox:SetWidth(boxW)
    champBox.border:SetColorTexture(b.champion and 1 or 0.2, b.champion and 0.82 or 0.2, b.champion and 0 or 0.2, 1)
    champBox.names[1]:SetText(UI.CROWN .. " |cffffd100Champion|r")
    champBox.names[2]:SetText(b.champion and UI.Name(b.champion, true) or "|cff555555?|r")
    for i = nextLine, #lines do lines[i]:Hide() end

    local status = T.Status(t, b)
    if status == "cancelled" then
        footer:SetText("|cffff4040This tournament was cancelled.|r Bets on matches that weren't decided are void.")
    elseif status == "finished" then
        footer:SetText(("%s won it. Hover over a match for the details; Bets shows who pays whom."):format(Short(b.champion)))
    else
        footer:SetText("A match is decided by the first duel between its two players after it opens (the final is best of three). "
            .. "Hover over a match for details, click it to bet.")
    end
end

------------------------------------------------------------------------
-- Bets
------------------------------------------------------------------------

local BET_COLUMNS = {
    { key = "status", label = "Status", width = 62 },
    { key = "what",   label = "",       width = 250 },
    { key = "pot",    label = "Pot",    width = 196 },
    { key = "you",    label = "You",    width = 110 },
    { key = "action", label = "",       width = 84 },
}

local STATUS = {
    pay = "|cffff8000To pay|r",
    incoming = "|cff20ff20Incoming|r",
    open = "|cffffd100Open|r",
    locked = "|cff3fc6eaLive|r",
    waiting = "|cff888888Waiting|r",
    settled = "|cffff8000Unpaid|r",
    paid = "|cff20ff20Paid|r",
    void = "|cff888888Void|r",
}

local function BetAction(item)
    local t = Current()
    if not t then return end
    if item.action == "Bet" or item.action == "Cancel" then
        OpenPopup(t, item.view.mid)
    elseif item.action == "Pay" then
        T:Pay(t.id, item.view.mid, item.transfer.to)
    elseif item.action == "Got it" then
        local x = item.transfer
        UI.Confirm(("Did %s pay you %s?"):format(Short(x.from), Money(x.copper)), function()
            UI.Report(T:MarkPaid(t.id, item.view.mid, x.from))
        end)
    end
end

local function RefreshBets(t)
    local me = Compat.PlayerKey()
    local b = T.Bracket(t)
    local items = {}
    for _, view in ipairs(T.Pots(t)) do
        local m = view.match
        local what = m and ("%s: %s vs %s"):format(T.RoundName(m.r, b.rounds), UI.Name(m.a, true), UI.Name(m.b, true))
            or "Champion of " .. t.name
        local raw = t.pots[view.mid]
        local stake = raw and raw.stakes[me]
        local item = { view = view, what = what, pot = PotText(view), status = view.state, priority = 4 }
        if view.state == "open" then
            item.priority = 2
            if stake and not stake.cancel then
                item.action = "Cancel"
            elseif not stake then
                item.action = "Bet"
            end
        end
        if stake and not stake.cancel then
            item.you = ("%s on %s"):format(Money(stake.amt), Short(stake.side))
        end
        local net = Bets.Payouts(view)
        if net and net[me] then
            item.you = net[me] > 0 and ("|cff20ff20+%s|r"):format(Money(net[me])) or ("|cffff4040-%s|r"):format(Money(-net[me]))
        end
        for _, x in ipairs(Bets.Transfers(view)) do
            if not x.paid and (x.from == me or x.to == me) then
                local payer = x.from == me
                items[#items + 1] = {
                    view = view, transfer = x, priority = 1, status = payer and "pay" or "incoming",
                    what = payer and ("You owe %s"):format(UI.Name(x.to, true)) or ("%s owes you"):format(UI.Name(x.from, true)),
                    pot = what, you = Money(x.copper), action = payer and "Pay" or "Got it",
                }
            end
        end
        if view.state ~= "waiting" and (raw and next(raw.stakes) or view.state == "open") then
            items[#items + 1] = item
        end
    end
    table.sort(items, function(x, y)
        if x.priority ~= y.priority then return x.priority < y.priority end
        return x.what < y.what
    end)
    betsTable:Fill(items, function(row, item)
        local c = row.cells
        c.status:SetText(STATUS[item.status] or item.status)
        c.what:SetText(item.what)
        c.pot:SetText("|cffaaaaaa" .. item.pot .. "|r")
        c.you:SetText(item.you or "-")
        row.button:SetShown(item.action ~= nil)
        if item.action then row.button:SetText(item.action) end
        row.selectedTex:SetShown(item.priority == 1)
    end)
    empty:SetShown(#items == 0)
    empty:SetText("No bets in this tournament yet. Click a match in the bracket to bet on it.")
    footer:SetText("Each match has its own pot, open until its first duel starts; a walkover voids it. The champion pot closed at the start. "
        .. "DuelLadder never moves money - Pay fills in a trade or mail, and the winner clicks Got it.")
end

------------------------------------------------------------------------
-- Tab
------------------------------------------------------------------------

local function RowButton(tbl, onClick)
    local col = tbl.columns[#tbl.columns]
    for _, row in ipairs(tbl.rows) do
        row.button = UI.Button(row, "", col.width, function(self)
            if self:GetParent().item then onClick(self:GetParent().item) end
        end)
        row.button:SetHeight(20)
        row.button:SetPoint("LEFT", row, "LEFT", col.x, 0)
    end
end

local function Build(content)
    title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 0, -2)
    title:SetJustifyH("LEFT")
    sub = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", 0, -26)
    sub:SetWidth(W - 260)
    sub:SetJustifyH("LEFT")
    sub:SetWordWrap(false)
    for i = 1, 6 do
        actionButtons[i] = UI.Button(content, "", 80, function(self) if self.fn then self.fn(self) end end)
    end

    local function Body()
        local f = CreateFrame("Frame", nil, content)
        f:SetPoint("TOPLEFT", 0, -TOP)
        f:SetPoint("BOTTOMRIGHT", 0, 24)
        return f
    end
    signup = Body()
    signupTable = UI.CreateTable(signup, SIGNUP_COLUMNS, SIGNUP_ROWS, {
        rowHeight = 19, onScroll = function() UI:RequestRefresh() end,
        onEnter = function(row, item)
            GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
            GameTooltip:AddLine(UI.Name(item.key, true))
            GameTooltip:AddLine(item.waiting and "On the waiting list: the tournament is full." or "Signed up", 1, 1, 1)
            GameTooltip:Show()
        end,
    })
    RowButton(signupTable, SignupAction)

    bracket = Body()
    bracket.labels = {}
    for r = 1, 4 do
        local label = bracket:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetJustifyH("LEFT")
        bracket.labels[r] = label
    end
    champBox = CreateBox()
    champBox:SetScript("OnEnter", nil)
    champBox:SetScript("OnClick", nil)

    betsView = Body()
    betsTable = UI.CreateTable(betsView, BET_COLUMNS, BET_ROWS, {
        rowHeight = 22, onScroll = function() UI:RequestRefresh() end,
    })
    RowButton(betsTable, BetAction)

    empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("TOP", 0, -TOP - 60)
    empty:SetWidth(W - 100)
    footer = UI.CreateFooter(content, 2)
    footer:SetWordWrap(true)
end

local function Refresh()
    local t = Current()
    local status = t and T.Status(t)
    LayoutActions(Actions(t, status))
    signup:Hide()
    bracket:Hide()
    betsView:Hide()
    empty:Hide()

    if not Data.guild then
        title:SetText("Tournament")
        sub:SetText("You need to be in a guild to play in tournaments.")
        footer:SetText("")
        return
    end
    if not t then
        title:SetText("Tournament")
        sub:SetText("No tournament yet.")
        empty:SetText("Host one with New tournament. Guild members join, you press Start, and the bracket fills in by "
            .. "itself as people duel. The winner of each match meets the winner of the next one, until one champion is left.")
        empty:Show()
        footer:SetText("")
        return
    end

    title:SetText(t.name)
    local parts = { "Hosted by " .. UI.Name(t.host, true) }
    if status == "signup" then
        parts[#parts + 1] = ("sign-ups open: %d / %d players"):format(#T.Entrants(t), T.MAX_PLAYERS)
        local total = 0
        for _, x in pairs(T.Sides(T.Pot(t, T.CHAMPION))) do total = total + x.amt end
        if total > 0 then parts[#parts + 1] = "champion pot " .. Money(total) end
        mode = "bracket"
        signup:Show()
        RefreshSignup(t)
    else
        local b = T.Bracket(t)
        parts[#parts + 1] = #t.seeds .. " players"
        if status == "cancelled" then
            parts[#parts + 1] = "|cffff4040cancelled|r"
        elseif status == "finished" then
            parts[#parts + 1] = "champion: " .. UI.Name(b.champion, true)
        else
            local m = T.CurrentMatch(b, Compat.PlayerKey())
            if m then
                local opp = m.a == Compat.PlayerKey() and m.b or m.a
                parts[#parts + 1] = ("|cffffd100your %s: vs %s|r"):format(T.RoundName(m.r, b.rounds):lower(), Short(opp))
            end
        end
        if mode == "bets" then
            betsView:Show()
            RefreshBets(t)
        else
            bracket:Show()
            RefreshBracket(t)
        end
    end
    sub:SetText(table.concat(parts, "  -  "))
end

UI:AddTab("Tournament", Build, Refresh)

ns:On("TOURNEY_CHANGED", function() UI:RequestRefresh() end)

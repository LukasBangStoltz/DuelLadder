local _, ns = ...
local Compat, Data, UI = ns.Compat, ns.Data, ns.UI

-- Members tab: everyone with the addon on the left, the selected member's full profile on
-- the right: rating, title, crown, record, nemesis, badges and their record against every
-- other member. You can challenge them to a gold duel from here.

local LIST_ROWS = 22
local PANEL_X = 200
local VS_LINES = 10
local BADGE_SIZE = 21

local selected
local list
local w = {} -- widgets

function UI:ShowProfile(key)
    selected = key
    UI:ShowTab("Members")
end

local function Line(parent, font, x, y, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", x, y)
    if width then fs:SetWidth(width) end
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    return fs
end

local function Header(parent, text, x, y)
    local fs = Line(parent, "GameFontNormal", x, y)
    fs:SetText(text)
    return fs
end

local function ChallengeClicked()
    local copper = w.money:GetCopper()
    if not selected or copper < ns.Bets.MIN_COPPER then
        ns.Print("Enter how much gold and silver the duel is for.")
        return
    end
    w.money:ClearFocus()
    local opponent = selected
    UI.Confirm(("Challenge %s to a duel for %s?\n\nIt's just the two of you: if they accept, they put in the same amount and the winner of your next duel takes it all. You can cancel until the duel starts."):format(
        Compat.DisplayName(opponent), Compat.MoneyText(copper)), function()
        local id, err = ns.Bets:Challenge(opponent, copper)
        if UI.Report(id, err) then
            ns.Print(("Challenge sent to %s. You can see it in the Bets tab."):format(Compat.DisplayName(opponent)))
        end
    end)
end

local function Build(content)
    -- 172 + gap + scrollbar ends just left of the divider.
    list = UI.CreateTable(content, { { key = "name", label = "Members with DuelLadder", width = 172 } }, LIST_ROWS, {
        onClick = function(key) -- the list's items are the member keys themselves
            selected = key
            UI:RefreshNow()
        end,
    })

    local divider = content:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.12)
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", PANEL_X - 10, 0)
    divider:SetPoint("BOTTOMLEFT", PANEL_X - 10, 0)

    local x, width = PANEL_X, UI.CONTENT_WIDTH - PANEL_X
    w.name = Line(content, "GameFontNormalLarge", x, 0, width)
    w.sub = Line(content, "GameFontHighlightSmall", x, -24, width)
    w.crown = Line(content, "GameFontNormalSmall", x, -40, width)

    Header(content, "Record", x, -62)
    w.record = Line(content, "GameFontHighlightSmall", x, -78, 250)
    w.record:SetSpacing(3)
    Header(content, "Rivals", x + 270, -62)
    w.rivals = Line(content, "GameFontHighlightSmall", x + 270, -78, width - 270)
    w.rivals:SetSpacing(3)

    Header(content, "Badges", x, -136)
    w.badges = {}
    for i = 1, #ns.Badges.LIST do
        local b = CreateFrame("Button", nil, content)
        b:SetSize(BADGE_SIZE, BADGE_SIZE)
        b:SetPoint("TOPLEFT", x + (i - 1) * (BADGE_SIZE + 4), -154)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        b.count:SetPoint("BOTTOMRIGHT", 2, -2)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.badge.name)
            GameTooltip:AddLine(self.badge.desc, 1, 1, 1, true)
            if self.n and self.n > 1 then GameTooltip:AddLine(("Earned %d times"):format(self.n), 0.6, 0.6, 0.6) end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        w.badges[i] = b
    end
    w.noBadges = Line(content, "GameFontDisableSmall", x, -160)
    w.noBadges:SetText("No badges yet.")

    w.vsHeader = Header(content, "Against other members", x, -192)
    w.vs1 = Line(content, "GameFontHighlightSmall", x, -210, 255)
    w.vs2 = Line(content, "GameFontHighlightSmall", x + 270, -210, 255)
    w.vs1:SetSpacing(3)
    w.vs2:SetSpacing(3)

    -- Challenge bar
    w.challenge = CreateFrame("Frame", nil, content)
    w.challenge:SetPoint("BOTTOMLEFT", x, 2)
    w.challenge:SetSize(width, 24)
    w.challengeText = w.challenge:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    w.challengeText:SetPoint("LEFT", 0, 0)
    w.money = UI.MoneyBox(w.challenge)
    w.money:SetPoint("LEFT", w.challengeText, "RIGHT", 4, 0)
    w.money:SetCopper(10 * 10000)
    local button = UI.Button(w.challenge, "Challenge", 90, ChallengeClicked)
    button:SetPoint("LEFT", w.money, "RIGHT", 6, 0)
    UI.SetTooltip(button, "Challenge", "If they accept, they put in the same amount and the winner of your next duel "
        .. "takes it all. You can cancel until the duel starts. Find it in the Bets tab.")
end

-- Everyone this member has a record against, members first, most duels first.
local function Opponents(key, e)
    local out, seen = {}, {}
    local entries = Data:Entries()
    local function Add(opp, wins, losses)
        if opp == key or seen[opp] then return end
        seen[opp] = true
        out[#out + 1] = { key = opp, w = wins, l = losses, member = entries[opp] ~= nil }
    end
    for opp, r in pairs(e.h2h) do Add(opp, r.w, r.l) end
    -- Members who recorded duels against them, in case this member's own copy is behind.
    for _, other in ipairs(Data:Members()) do
        local r = entries[other].h2h[key]
        if r then Add(other, r.l, r.w) else Add(other, 0, 0) end
    end
    table.sort(out, function(a, b)
        if a.member ~= b.member then return a.member end
        if a.w + a.l ~= b.w + b.l then return a.w + a.l > b.w + b.l end
        return a.key < b.key
    end)
    return out
end

local function RefreshProfile()
    local e = selected and Data:Entries()[selected]
    for _, b in ipairs(w.badges) do b:Hide() end
    if not e then
        w.name:SetText("")
        w.sub:SetText("|cff888888Pick a member on the left.|r")
        for _, k in ipairs({ "crown", "record", "rivals", "vs1", "vs2" }) do w[k]:SetText("") end
        w.noBadges:Hide()
        w.challenge:Hide()
        return
    end

    local _, title = Data.Title(e)
    w.name:SetText(UI.Name(selected) .. "  " .. title)
    local online = Data:IsOnline(selected) and (UI.ONLINE_DOT .. " Online") or (UI.OFFLINE_DOT .. " Offline")
    w.sub:SetText(("Level %d %s  -  Rating |cffffffff%d|r  -  %s  -  DuelLadder %s"):format(
        e.level or 0, Compat.ClassName(e.class), e.rating, online, e.ver ~= "" and e.ver or "?"))

    local king, since = Data:King()
    if king == selected then
        w.crown:SetText(("%s King of the Hill since %s, %d successful defenses"):format(UI.CROWN, UI.Ago(since), e.defenses))
    else
        w.crown:SetText("")
    end

    w.record:SetText(table.concat({
        ("Wins - losses: %s  (%s)"):format(UI.Record(e.w, e.l), UI.PctText(e)),
        ("Streak: %s   Best streak: |cffffffff%d|r"):format(UI.StreakText(e.streak), e.best),
        ("Times fled: |cffffffff%d|r   Last duel: |cffffffff%s|r"):format(e.fled, UI.Ago(e.last)),
    }, "\n"))

    local nemesis, victim, rival = UI.Rivals(e)
    local function RivalLine(label, item, hint)
        if not item then return ("%s: |cff888888%s|r"):format(label, hint) end
        return ("%s: %s  %s"):format(label, UI.Name(item.key, true), UI.Record(item.w, item.l))
    end
    w.rivals:SetText(table.concat({
        RivalLine("Nemesis", nemesis, "nobody has beaten them"),
        RivalLine("Favourite victim", victim, "no wins yet"),
        RivalLine("Biggest rival", rival, "no duels yet"),
    }, "\n"))

    local shown = 0
    for _, badge in ipairs(ns.Badges.LIST) do
        local n = e.badges[badge.id]
        if n then
            shown = shown + 1
            local b = w.badges[shown]
            b.badge, b.n = badge, n
            b.icon:SetTexture(badge.texture)
            b.count:SetText(n > 1 and n or "")
            b:Show()
        end
    end
    w.noBadges:SetShown(shown == 0)

    local opponents = Opponents(selected, e)
    local cols = { {}, {} }
    for i, o in ipairs(opponents) do
        if i > VS_LINES * 2 then break end
        local text
        if o.w + o.l == 0 then
            text = ("%s  |cff888888no duels|r"):format(UI.Name(o.key, true))
        else
            text = ("%s  %s"):format(UI.Name(o.key, true), UI.Record(o.w, o.l))
        end
        if not o.member then text = text .. " |cff888888(no addon)|r" end
        table.insert(cols[i <= VS_LINES and 1 or 2], text)
    end
    if #opponents > VS_LINES * 2 then
        cols[2][VS_LINES] = ("|cff888888...and %d more|r"):format(#opponents - VS_LINES * 2 + 1)
    end
    w.vs1:SetText(#cols[1] > 0 and table.concat(cols[1], "\n") or "|cff888888Nobody else has DuelLadder yet.|r")
    w.vs2:SetText(table.concat(cols[2], "\n"))

    local canChallenge = Data.guild and selected ~= Compat.PlayerKey()
    w.challenge:SetShown(canChallenge and true or false)
    if canChallenge then
        w.challengeText:SetText("Challenge " .. Compat.DisplayName(selected) .. " for")
    end
end

local function Refresh()
    local members = Data:Members()
    table.sort(members, function(a, b)
        local oa, ob = Data:IsOnline(a), Data:IsOnline(b)
        if oa ~= ob then return oa end
        return Compat.DisplayName(a) < Compat.DisplayName(b)
    end)
    if not selected or not Data:Entries()[selected] then selected = Compat.PlayerKey() end

    list:Fill(members, function(row, key)
        local dot = Data:IsOnline(key) and UI.ONLINE_DOT or UI.OFFLINE_DOT
        row.cells.name:SetText(dot .. " " .. UI.Name(key))
        row.selectedTex:SetShown(key == selected)
    end)
    RefreshProfile()
end

UI:AddTab("Members", Build, Refresh)

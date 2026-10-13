local _, ns = ...
local Compat, Data, UI = ns.Compat, ns.Data, ns.UI

-- Ladder tab: everyone with the addon, ranked. Click a column to sort, a row to open the profile.

local ROWS = 20

local COLUMNS = {
    { key = "rank",   label = "#",      width = 22,  align = "RIGHT", sortable = false },
    { key = "name",   label = "Name",   width = 150 },
    { key = "title",  label = "Title",  width = 72,  sortKey = "rating" },
    { key = "rating", label = "Rating", width = 46,  align = "RIGHT" },
    { key = "w",      label = "Wins",   width = 40,  align = "RIGHT" },
    { key = "l",      label = "Losses", width = 44,  align = "RIGHT" },
    { key = "pct",    label = "Win %",  width = 42,  align = "RIGHT" },
    { key = "streak", label = "Streak", width = 44,  align = "RIGHT" },
    { key = "best",   label = "Best",   width = 34,  align = "RIGHT" },
    { key = "fled",   label = "Fled",   width = 32,  align = "RIGHT" },
    { key = "badges", label = "Badges", width = 44,  align = "RIGHT" },
}

local tbl, status, guildOnlyBox, announceBox

local function SortBy(key)
    local s = Data.settings
    if s.sortKey == key then
        s.sortDesc = not s.sortDesc
    else
        s.sortKey = key
        s.sortDesc = key ~= "name"
    end
    tbl.offset = 0
    UI:RefreshNow()
end

-- Quick look when hovering a row.
local function ShowTooltip(row, item)
    local e = item.e
    local _, title = Data.Title(e)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(UI.Name(item.key))
    GameTooltip:AddDoubleLine(title, ("Rating %d"):format(e.rating), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Record", UI.Record(e.w, e.l) .. "  (" .. UI.PctText(e) .. ")", 1, 0.82, 0)
    local nemesis = UI.Rivals(e)
    if nemesis then
        GameTooltip:AddDoubleLine("Nemesis", UI.Name(nemesis.key, true) .. "  " .. UI.Record(nemesis.w, nemesis.l), 1, 0.82, 0)
    end
    if Data:King() == item.key then
        GameTooltip:AddLine(UI.CROWN .. " King of the Hill", 1, 0.82, 0)
    end
    GameTooltip:AddLine("Click to open profile", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function Build(content)
    tbl = UI.CreateTable(content, COLUMNS, ROWS, {
        top = 0,
        onHeaderClick = SortBy,
        onClick = function(item) UI:ShowProfile(item.key) end,
        onEnter = ShowTooltip,
    })

    status = UI.CreateFooter(content, 30)

    guildOnlyBox = UI.CheckBox(content, "Guild duels only",
        function() return Data.settings.guildOnly end,
        function(v) Data.settings.guildOnly = v end,
        "Only count duels against members of your guild. Duels against anyone else don't change your stats.")
    guildOnlyBox:SetPoint("BOTTOMLEFT", 0, 2)

    announceBox = UI.CheckBox(content, "Announce my wins in guild chat",
        function() return Data.settings.announce end,
        function(v) Data.settings.announce = v end,
        "Post a line in guild chat when you win a duel or take the crown.")
    announceBox:SetPoint("LEFT", guildOnlyBox.label, "RIGHT", 14, -1)

    local sync = UI.Button(content, "Sync", 80, function(self)
        ns.Sync:Request()
        self:Disable()
        C_Timer.After(15, function() self:Enable() end)
    end)
    sync:SetPoint("BOTTOMRIGHT", 0, 2)
    UI.SetTooltip(sync, "Sync", "Ask the guild for fresh stats. This normally happens by itself.")
end

local function Refresh()
    local list = UI:BuildList()
    tbl:Fill(list, function(row, item, index)
        local e, c = item.e, row.cells
        local _, title = Data.Title(e)
        c.rank:SetText(index)
        c.name:SetText(UI.Name(item.key))
        c.title:SetText(title)
        c.rating:SetText(e.rating)
        c.w:SetText(e.w)
        c.l:SetText(e.l)
        c.pct:SetText(UI.PctText(e))
        c.streak:SetText(UI.StreakText(e.streak))
        c.best:SetText(e.best)
        c.fled:SetText(e.fled)
        c.badges:SetText(ns.Badges.Count(e))
        row:SetAlpha(e.w + e.l > 0 and 1 or 0.55)
    end)

    for i, col in ipairs(COLUMNS) do
        local active = (col.sortKey or col.key) == Data.settings.sortKey and col.key ~= "title"
        tbl.headers[i].text:SetText(active and ("|cffffffff%s|r"):format(col.label) or col.label)
    end

    if Data.guild then
        status:SetText(("%d duelists     %s King of the Hill     |cffffd100*|r Your characters"):format(#list, UI.CROWN))
    else
        status:SetText("You need to be in a guild to use DuelLadder.")
    end
    guildOnlyBox:Update()
    announceBox:Update()
end

UI:AddTab("Ladder", Build, Refresh)

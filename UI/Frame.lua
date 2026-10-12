local _, ns = ...
local Compat, Data = ns.Compat, ns.Data

-- The main window: Blizzard style, one frame with tabs along the bottom. Each tab file
-- registers itself with UI:AddTab.
local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 760, 480
local TAB_WIDTH = 80          -- minimum; wider if a tab's text doesn't fit
local TAB_TEXT_MARGIN = 8
local TAB_INSET = 10          -- space between the window's edges and the outer tabs
local tabSpacing = 0          -- set from the tab template when the window is made
UI.CONTENT_WIDTH = WIDTH - 24
UI.CONTENT_HEIGHT = HEIGHT - 40
local tabs = {}               -- { label, build = fn(content), refresh = fn(content), content }
local frame
local currentTab
local FitTabs

------------------------------------------------------------------------
-- Shared helpers for the tabs
------------------------------------------------------------------------

UI.CROWN = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:0|t"

local function Dot(r, g, b)
    return ("|TInterface\\Buttons\\WHITE8X8:8:8:0:0:8:8:0:8:0:8:%d:%d:%d|t"):format(r, g, b)
end
UI.ONLINE_DOT = Dot(40, 230, 40)
UI.OFFLINE_DOT = Dot(100, 100, 100)

-- Class-coloured name, with the crown for the King of the Hill and a star for our own characters.
function UI.Name(key, plain)
    local text = Compat.ClassColorCode(Data:ClassOf(key)) .. Compat.DisplayName(key) .. "|r"
    if plain then return text end
    if Data:King() == key then text = UI.CROWN .. text end
    if Data.db.myChars[key] then text = text .. " |cffffd100*|r" end
    return text
end

function UI.Record(w, l)
    return ("|cff20ff20%d|r - |cffff4040%d|r"):format(w, l)
end

function UI.WinPct(e)
    local total = e.w + e.l
    return total > 0 and e.w / total or 0
end

function UI.PctText(e)
    if e.w + e.l == 0 then return "-" end
    return ("%d%%"):format(math.floor(UI.WinPct(e) * 100 + 0.5))
end

function UI.StreakText(streak)
    if streak > 0 then return ("|cff20ff20W%d|r"):format(streak) end
    if streak < 0 then return ("|cffff4040L%d|r"):format(-streak) end
    return "-"
end

function UI.Ago(t)
    if not t or t == 0 then return "never" end
    local s = math.max(0, Compat.Now() - t)
    if s < 60 then return "just now" end
    if s < 3600 then return ("%d min ago"):format(math.floor(s / 60)) end
    if s < 86400 then return ("%d h ago"):format(math.floor(s / 3600)) end
    return ("%d days ago"):format(math.floor(s / 86400))
end

-- Nemesis (beats you most), victim (you beat most) and rival (fought most), as
-- { key, w, l } or nil.
function UI.Rivals(e)
    local nemesis, victim, rival
    for opp, r in pairs(e.h2h) do
        local item = { key = opp, w = r.w, l = r.l }
        if r.l > 0 and (not nemesis or r.l > nemesis.l or (r.l == nemesis.l and r.w < nemesis.w)) then nemesis = item end
        if r.w > 0 and (not victim or r.w > victim.w or (r.w == victim.w and r.l < victim.l)) then victim = item end
        if not rival or r.w + r.l > rival.w + rival.l then rival = item end
    end
    return nemesis, victim, rival
end

local function SortValue(item, sortKey)
    local e = item.e
    if sortKey == "pct" then return UI.WinPct(e) end
    if sortKey == "name" then return item.key end
    if sortKey == "badges" then return ns.Badges.Count(e) end
    return e[sortKey] or 0
end

-- Members with the addon, sorted. Uses the ladder's sort unless one is given.
function UI:BuildList(sortKey, desc)
    local list = {}
    local entries = Data:Entries()
    for _, key in ipairs(Data:Members()) do
        list[#list + 1] = { key = key, e = entries[key] }
    end
    if not sortKey then
        sortKey, desc = Data.settings.sortKey, Data.settings.sortDesc
    end
    table.sort(list, function(a, b)
        local va, vb = SortValue(a, sortKey), SortValue(b, sortKey)
        if va ~= vb then
            if desc then return va > vb end
            return va < vb
        end
        if a.e.rating ~= b.e.rating then return a.e.rating > b.e.rating end
        if a.e.w ~= b.e.w then return a.e.w > b.e.w end
        return a.key < b.key
    end)
    return list
end

-- Grey status line at the bottom of a tab.
function UI.CreateFooter(content, y)
    local footer = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", 4, y or 2)
    footer:SetPoint("BOTTOMRIGHT", -4, y or 2)
    footer:SetJustifyH("LEFT")
    return footer
end

function UI.Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

function UI.CheckBox(parent, label, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    local text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
    text:SetText(label)
    cb.label = text
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    cb.Update = function(self) self:SetChecked(get()) end
    return cb
end

local function NumberBox(parent, width, maxLetters)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(maxLetters)
    box:SetScript("OnEscapePressed", box.ClearFocus)
    box:SetScript("OnEnterPressed", box.ClearFocus)
    return box
end

-- "[ 10 ] g [ 50 ] s" input. :GetCopper(), :SetCopper(copper), :SetOnChange(fn).
-- Amounts are whole silver; copper isn't worth betting.
function UI.MoneyBox(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(150, 20)
    f.gold = NumberBox(f, 56, 5)
    f.gold:SetPoint("LEFT", 6, 0)
    local g = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    g:SetPoint("LEFT", f.gold, "RIGHT", 2, 0)
    g:SetText("|TInterface\\MoneyFrame\\UI-GoldIcon:0|t")
    f.silver = NumberBox(f, 30, 2)
    f.silver:SetPoint("LEFT", g, "RIGHT", 10, 0)
    local s = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    s:SetPoint("LEFT", f.silver, "RIGHT", 2, 0)
    s:SetText("|TInterface\\MoneyFrame\\UI-SilverIcon:0|t")

    function f:GetCopper()
        local gold = tonumber(self.gold:GetText()) or 0
        local silver = math.min(tonumber(self.silver:GetText()) or 0, 99)
        return gold * 10000 + silver * 100
    end
    function f:SetCopper(copper)
        copper = math.floor((copper or 0) / 100) * 100
        local gold, silver = math.floor(copper / 10000), math.floor(copper / 100) % 100
        self.gold:SetText(tostring(gold))
        self.silver:SetText(silver > 0 and tostring(silver) or "")
    end
    function f:SetOnChange(fn)
        self.gold:SetScript("OnTextChanged", fn)
        self.silver:SetScript("OnTextChanged", fn)
    end
    function f:ClearFocus()
        self.gold:ClearFocus()
        self.silver:ClearFocus()
    end
    -- Tab jumps from gold to silver and back.
    f.gold:SetScript("OnTabPressed", function() f.silver:SetFocus() end)
    f.silver:SetScript("OnTabPressed", function() f.gold:SetFocus() end)
    return f
end

-- Yes/No confirmation using Blizzard's popup.
StaticPopupDialogs["DUELLADDER_CONFIRM"] = {
    text = "%s",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, data) data() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function UI.Confirm(text, onYes)
    local dialog = StaticPopup_Show("DUELLADDER_CONFIRM", text)
    if dialog then dialog.data = onYes end
end

-- Shows the result of an action: errors in chat.
function UI.Report(ok, err)
    if not ok and err then ns.Print("|cffff4040" .. err .. "|r") end
    return ok
end

-- A simple scrolling table: column headers plus a fixed number of rows. Scroll with the
-- mouse wheel. opts = { top, left, rowHeight, onClick(item, button), onEnter(row, item),
-- onHeaderClick(key), onScroll() }
function UI.CreateTable(parent, columns, numRows, opts)
    opts = opts or {}
    local left, top, rowHeight = opts.left or 0, opts.top or 0, opts.rowHeight or 18
    local t = { rows = {}, headers = {}, offset = 0, columns = columns }

    local x = 0
    for _, col in ipairs(columns) do
        col.x = x
        x = x + col.width + 6
    end
    t.width = x

    for i, col in ipairs(columns) do
        local h = CreateFrame("Button", nil, parent)
        h:SetSize(col.width, 18)
        h:SetPoint("TOPLEFT", left + col.x, -top)
        local text = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetAllPoints()
        text:SetJustifyH(col.align or "LEFT")
        text:SetText(col.label)
        h.text = text
        if opts.onHeaderClick and col.sortable ~= false then
            h:SetScript("OnClick", function() opts.onHeaderClick(col.sortKey or col.key) end)
        end
        t.headers[i] = h
    end

    for i = 1, numRows do
        local row = CreateFrame("Button", nil, parent)
        row:SetSize(x, rowHeight)
        row:SetPoint("TOPLEFT", left, -(top + 20 + (i - 1) * rowHeight))
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local selected = row:CreateTexture(nil, "BACKGROUND")
        selected:SetAllPoints()
        selected:SetColorTexture(1, 0.82, 0, 0.15)
        selected:Hide()
        row.selectedTex = selected
        row.cells = {}
        for _, col in ipairs(columns) do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
            fs:SetWidth(col.width)
            fs:SetJustifyH(col.align or "LEFT")
            fs:SetWordWrap(false)
            row.cells[col.key] = fs
        end
        if opts.onClick then
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnClick", function(self, button)
                if self.item then opts.onClick(self.item, button) end
            end)
        end
        if opts.onEnter then
            row:SetScript("OnEnter", function(self) if self.item then opts.onEnter(self, self.item) end end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        t.rows[i] = row
    end

    parent:EnableMouseWheel(true)
    parent:SetScript("OnMouseWheel", function(_, delta)
        t.offset = t.offset - delta * 3
        if opts.onScroll then opts.onScroll() end
    end)

    -- fillRow(row, item, index) sets the cells of one visible row.
    function t:Fill(items, fillRow)
        self.offset = math.max(0, math.min(self.offset, #items - numRows))
        for i, row in ipairs(self.rows) do
            local item = items[i + self.offset]
            row.item = item
            if item then
                fillRow(row, item, i + self.offset)
                row:Show()
            else
                row:Hide()
            end
        end
    end

    return t
end

------------------------------------------------------------------------
-- Window and tabs
------------------------------------------------------------------------

function UI:AddTab(label, build, refresh)
    table.insert(tabs, { label = label, build = build, refresh = refresh })
end

local function SavePosition()
    local point, _, relPoint, x, y = frame:GetPoint()
    Data.settings.window = { point = point, relPoint = relPoint, x = x, y = y }
end

local function RestorePosition()
    local pos = Data.settings.window
    frame:ClearAllPoints()
    if pos then
        frame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    else
        frame:SetPoint("CENTER")
    end
end

function UI:SelectTab(index)
    currentTab = index
    Data.settings.lastTab = index
    PanelTemplates_SetTab(frame, index)
    FitTabs()
    for i, tab in ipairs(tabs) do
        if i == index then
            if not tab.content then
                tab.content = CreateFrame("Frame", nil, frame)
                tab.content:SetPoint("TOPLEFT", 12, -30)
                tab.content:SetPoint("BOTTOMRIGHT", -12, 10)
                tab.build(tab.content)
            end
            tab.content:Show()
            if tab.refresh then tab.refresh(tab.content) end
        elseif tab.content then
            tab.content:Hide()
        end
    end
end

-- Same width for all tabs, wide enough for the longest text but never so wide that the
-- row of tabs runs past the window's right edge (see GuildCrafters' notes: the template
-- resizes on show, so this runs again then).
FitTabs = function()
    local buttons = {}
    for i = 1, #tabs do buttons[i] = _G["DuelLadderFrameTab" .. i] end
    if #buttons == 0 or not PanelTemplates_TabResize then return end
    local width = TAB_WIDTH
    for _, button in ipairs(buttons) do
        local text = button:GetFontString()
        local name = button:GetName()
        local left = button.Left or (name and _G[name .. "Left"])
        if text then
            text:SetWidth(0)
            local sides = left and left:GetWidth() * 2 or 40
            width = math.max(width, math.ceil(text:GetStringWidth() + sides) + TAB_TEXT_MARGIN)
        end
    end
    local fits = math.floor((WIDTH - 2 * TAB_INSET - tabSpacing * (#buttons - 1)) / #buttons)
    width = math.min(width, fits)
    for _, button in ipairs(buttons) do
        PanelTemplates_TabResize(button, 0, width)
        local text = button:GetFontString()
        if text and text.IsTruncated and text:IsTruncated() then text:SetWidth(0) end
    end
end

local function CreateMainFrame()
    local template = Compat.HasTemplate("BasicFrameTemplateWithInset")
        and "BasicFrameTemplateWithInset" or "BasicFrameTemplate"
    frame = CreateFrame("Frame", "DuelLadderFrame", UIParent, template)
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    frame:HookScript("OnShow", function() Compat.RequestGuildRoster() end)
    RestorePosition()
    UI.frame = frame

    local title = frame.TitleText
    if not title then
        title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", 0, -5)
    end
    UI.title = title

    table.insert(UISpecialFrames, "DuelLadderFrame") -- Escape closes it

    local tabTemplate, spacing = Compat.TabTemplate()
    tabSpacing = spacing
    for i, tab in ipairs(tabs) do
        local button = CreateFrame("Button", "DuelLadderFrameTab" .. i, frame, tabTemplate)
        button:SetID(i)
        button:SetText(tab.label)
        if i == 1 then
            button:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", TAB_INSET, 2)
        else
            button:SetPoint("LEFT", _G["DuelLadderFrameTab" .. (i - 1)], "RIGHT", spacing, 0)
        end
        button:SetScript("OnClick", function(self)
            Compat.PlaySound("IG_CHARACTER_INFO_TAB")
            UI:SelectTab(self:GetID())
        end)
        button:HookScript("OnShow", FitTabs)
    end
    PanelTemplates_SetNumTabs(frame, #tabs)
    FitTabs()

    frame:Hide()
    UI:SelectTab(math.min(Data.settings.lastTab or 1, #tabs))
end

local function UpdateTitle()
    if not UI.title then return end
    local guildName = Data.guildKey and Data.guildKey:match("/(.+)$")
    UI.title:SetText(guildName and ("DuelLadder - " .. guildName) or "DuelLadder")
end

function UI:Toggle()
    if not Data.db then return end
    if not frame then CreateMainFrame() end
    if frame:IsShown() then
        frame:Hide()
    else
        UpdateTitle()
        frame:Show()
        UI:SelectTab(currentTab)
    end
end

-- Opens the window on the tab with this label.
function UI:ShowTab(label)
    if not Data.db then return end
    if not frame then CreateMainFrame() end
    UpdateTitle()
    frame:Show()
    for i, tab in ipairs(tabs) do
        if tab.label == label then
            UI:SelectTab(i)
            return tab.content
        end
    end
end

-- Refreshes the visible tab when data changes. Bursts of changes become one refresh.
local refreshPending = false
function UI:RequestRefresh()
    if not frame or not frame:IsShown() or refreshPending then return end
    refreshPending = true
    C_Timer.After(0.3, function()
        refreshPending = false
        UpdateTitle()
        local tab = tabs[currentTab]
        if frame:IsShown() and tab and tab.refresh and tab.content then
            tab.refresh(tab.content)
        end
    end)
end

ns:On("DATA_CHANGED", function() UI:RequestRefresh() end)
ns:On("BETS_CHANGED", function() UI:RequestRefresh() end)

local _, ns = ...
local Compat, Data, UI = ns.Compat, ns.Data, ns.UI

-- Badges tab: your own badge collection. Earned badges in colour with how many times,
-- the rest greyed out with how to earn them (and your progress where it can be counted).
-- Other people's badges are on their profile in the Members tab.

local COLS = 2
local CELL_W, CELL_H = 360, 34
local TOP = 22
local cells = {}
local header, footer

local function Build(content)
    header = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetJustifyH("LEFT")

    for i, badge in ipairs(ns.Badges.LIST) do
        local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
        local c = CreateFrame("Frame", nil, content)
        c:SetSize(CELL_W, CELL_H)
        c:SetPoint("TOPLEFT", col * (CELL_W + 16), -TOP - row * (CELL_H + 2))

        c.icon = c:CreateTexture(nil, "ARTWORK")
        c.icon:SetSize(30, 30)
        c.icon:SetPoint("TOPLEFT", 0, -2)
        c.icon:SetTexture(badge.texture)

        c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        c.name:SetPoint("TOPLEFT", 38, -2)

        c.desc = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.desc:SetPoint("LEFT", c.name, "RIGHT", 6, 0)
        c.desc:SetPoint("RIGHT", c, "RIGHT", 0, 0)
        c.desc:SetJustifyH("LEFT")
        c.desc:SetWordWrap(false)
        c.desc:SetText("|cffaaaaaa" .. badge.desc .. "|r")

        c.status = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.status:SetPoint("TOPLEFT", 38, -18)
        c.status:SetWidth(CELL_W - 38)
        c.status:SetJustifyH("LEFT")
        c.status:SetWordWrap(false)

        c.badge = badge
        cells[i] = c
    end
    footer = UI.CreateFooter(content, 2)
    footer:SetText("Other members' badges are on their profile in Members.")
end

local function Refresh()
    local e = Data:MyEntry()
    local earned = 0
    for _, c in ipairs(cells) do
        local badge = c.badge
        local n = e and e.badges[badge.id]
        if n then
            earned = earned + 1
            c.name:SetText(badge.name)
            c.status:SetText(n > 1 and ("|cff20ff20Earned %d times|r"):format(n) or "|cff20ff20Earned|r")
            c.icon:SetDesaturated(false)
            c.icon:SetAlpha(1)
        else
            c.name:SetText("|cff808080" .. badge.name .. "|r")
            local status = "|cff666666Not earned yet|r"
            if e and badge.progress then
                local cur, goal, unit = badge.progress(e)
                status = ("|cff999999Progress: %d / %d %s|r"):format(math.min(cur, goal), goal, unit)
            end
            c.status:SetText(status)
            c.icon:SetDesaturated(true)
            c.icon:SetAlpha(0.5)
        end
    end

    if e then
        header:SetText(("Your badges: %s has earned |cffffffff%d|r of %d"):format(
            UI.Name(Compat.PlayerKey(), true), earned, #cells))
    else
        header:SetText("You need to be in a guild to earn badges.")
    end
end

UI:AddTab("Badges", Build, Refresh)

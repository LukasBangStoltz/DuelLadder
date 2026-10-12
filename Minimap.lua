local _, ns = ...
local Compat, Data = ns.Compat, ns.Data

-- Minimap button (drag it around the minimap; LibDBIcon saves the position).

local ICON = "Interface\\Icons\\Ability_DualWield"
local LDBIcon = LibStub("LibDBIcon-1.0")

local Button = {}
ns.Minimap = Button

local function ShowTooltip(tooltip)
    local UI = ns.UI
    tooltip:AddLine("DuelLadder")
    local mine = Data.guild and Data:MyEntry()
    if mine then
        local _, title = Data.Title(mine)
        tooltip:AddDoubleLine("You", ("%s  %d  %s"):format(title, mine.rating, UI.Record(mine.w, mine.l)), 1, 0.82, 0)
        local king = Data:King()
        if king then
            tooltip:AddDoubleLine("King of the Hill", UI.CROWN .. UI.Name(king, true), 1, 0.82, 0)
        end
        local leaders = UI:BuildList("rating", true)
        local shown = 0
        for _, item in ipairs(leaders) do
            if shown == 3 then break end
            if item.e.w + item.e.l > 0 then
                shown = shown + 1
                tooltip:AddDoubleLine(("%d. %s"):format(shown, UI.Name(item.key, true)),
                    ("%d  %s"):format(item.e.rating, UI.Record(item.e.w, item.e.l)), 1, 1, 1)
            end
        end
        local _, owedToMe, iOwe = ns.Bets:Balance()
        if iOwe > 0 then tooltip:AddLine("You owe " .. Compat.MoneyText(iOwe) .. " in bets", 1, 0.25, 0.25) end
        if owedToMe > 0 then tooltip:AddLine("You're owed " .. Compat.MoneyText(owedToMe) .. " in bets", 0.25, 1, 0.25) end
    end
    tooltip:AddLine(" ")
    tooltip:AddLine("Click to open DuelLadder", 0.6, 0.6, 0.6)
end

function Button:Toggle()
    local settings = Data.settings.minimap
    settings.hide = not settings.hide
    if settings.hide then
        LDBIcon:Hide("DuelLadder")
        ns.Print("Minimap button hidden. |cffffffff/duels minimap|r shows it again.")
    else
        LDBIcon:Show("DuelLadder")
    end
end

ns:Listen("PLAYER_LOGIN", function()
    local launcher = LibStub("LibDataBroker-1.1"):NewDataObject("DuelLadder", {
        type = "launcher",
        icon = ICON,
        OnClick = function() ns.UI:Toggle() end,
        OnTooltipShow = ShowTooltip,
    })
    LDBIcon:Register("DuelLadder", launcher, Data.settings.minimap)
end)

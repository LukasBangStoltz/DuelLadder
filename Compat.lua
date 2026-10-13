local _, ns = ...

-- Every API call that can differ between clients (TBC Anniversary, Retail, and WoW Forever later)
-- lives here. The rest of the addon only talks to Compat.
local Compat = {}
ns.Compat = Compat

Compat.GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
Compat.Now = GetServerTime or time

-- Global strings are localized, so duel detection works in any client language.
Compat.DUEL_KNOCKOUT = DUEL_WINNER_KNOCKOUT or "%1$s has defeated %2$s in a duel"
Compat.DUEL_RETREAT = DUEL_WINNER_RETREAT or "%2$s has fled from %1$s in a duel"

-- Midnight-style clients (Forever) can hand addons "secret" values that can't be inspected.
function Compat.IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end

------------------------------------------------------------------------
-- Names
------------------------------------------------------------------------

function Compat.RealmName()
    return (GetNormalizedRealmName and GetNormalizedRealmName())
        or (GetRealmName():gsub("[%s%-]", ""))
end

function Compat.PlayerKey()
    return UnitName("player") .. "-" .. Compat.RealmName()
end

-- Names from chat, the roster and addon messages may lack a realm. Turn them into "Name-Realm".
function Compat.FullName(name)
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then return name end
    return name .. "-" .. Compat.RealmName()
end

function Compat.ShortName(key)
    return (key:match("^([^%-]+)")) or key
end

-- Short name for characters on our own realm, full "Name-Realm" for everyone else.
function Compat.DisplayName(key)
    local name, realm = key:match("^([^%-]+)%-(.+)$")
    if not name or realm == Compat.RealmName() then return Compat.ShortName(key) end
    return key
end

function Compat.ClassColorCode(classFile)
    local colors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
    local c = classFile and colors and colors[classFile]
    if not c then return "|cffffffff" end
    return ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)
end

function Compat.ClassName(classFile)
    return (classFile and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile])
        or classFile or "Unknown"
end

------------------------------------------------------------------------
-- Guild
------------------------------------------------------------------------

-- "Realm/Guild name", or nil if we're not in a guild (or it hasn't loaded yet).
function Compat.GuildKey()
    if not IsInGuild() then return nil end
    local guildName = GetGuildInfo("player")
    if not guildName then return nil end
    return Compat.RealmName() .. "/" .. guildName
end

function Compat.RequestGuildRoster()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

-- Returns a map of "Name-Realm" -> { level, class, online }, plus whether the roster
-- covered every member (it can be partial right after login).
function Compat.GetGuildRoster()
    local roster, count = {}, 0
    if not IsInGuild() then return roster, false end
    local total = GetNumGuildMembers() or 0
    for i = 1, total do
        local name, _, _, level, _, _, _, _, online, _, classFile = GetGuildRosterInfo(i)
        local key = Compat.FullName(name)
        if key then
            roster[key] = { level = level, class = classFile, online = online and true or false }
            count = count + 1
        end
    end
    return roster, total > 0 and count == total
end

-- Names in mail: just "Name" on our own realm.
function Compat.MailName(key)
    return Compat.DisplayName(key)
end

------------------------------------------------------------------------
-- Player state at the end of a duel
------------------------------------------------------------------------

-- 0..1, or nil if the client hides it (Forever may hand addons secret values).
function Compat.HealthPct()
    local hp, max = UnitHealth("player"), UnitHealthMax("player")
    if Compat.IsSecret(hp) or Compat.IsSecret(max) or not max or max == 0 then return nil end
    return hp / max
end

function Compat.ZoneName()
    local sub = GetSubZoneText and GetSubZoneText() or ""
    if sub ~= "" then return sub end
    return GetZoneText and GetZoneText() or ""
end

------------------------------------------------------------------------
-- Gold
------------------------------------------------------------------------

-- Bets are placed in whole gold, but a share of a pot can be silver and copper too.
function Compat.MoneyText(copper)
    copper = math.floor(copper + 0.5)
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local text = g > 0 and (g .. "g") or ""
    if s > 0 then text = text .. (text ~= "" and " " or "") .. s .. "s" end
    if c > 0 or text == "" then text = text .. (text ~= "" and " " or "") .. c .. "c" end
    return text
end

function Compat.CanAfford(copper)
    return GetMoney() >= copper
end

------------------------------------------------------------------------
-- Trading
------------------------------------------------------------------------

-- "Name-Realm" of a unit, or nil.
function Compat.UnitKey(unit)
    if not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
    local name, realm = UnitName(unit)
    if not name or Compat.IsSecret(name) then return nil end
    if realm and realm ~= "" then return name .. "-" .. realm:gsub("[%s%-]", "") end
    return name .. "-" .. Compat.RealmName()
end

-- Addons can't target a player by name, so look for them among the units we can see:
-- target, mouseover, focus, party/raid members and nameplates.
function Compat.FindUnit(key)
    local units = { "target", "mouseover", "focus" }
    for i = 1, 4 do units[#units + 1] = "party" .. i end
    for i = 1, 40 do units[#units + 1] = "raid" .. i end
    for i = 1, 40 do units[#units + 1] = "nameplate" .. i end
    for _, unit in ipairs(units) do
        if Compat.UnitKey(unit) == key then return unit end
    end
    return nil
end

-- Close enough to trade (about 10 yards)?
function Compat.InTradeRange(unit)
    if not CheckInteractDistance then return true end -- let the server decide
    local ok, inRange = pcall(CheckInteractDistance, unit, 2)
    return not ok or inRange == true
end

function Compat.OpenTrade(unit)
    if not InitiateTrade then return false end
    return (pcall(InitiateTrade, unit))
end

-- Who we're trading with right now ("Name-Realm"), or nil.
function Compat.TradePartner()
    if not (TradeFrame and TradeFrame:IsShown()) then return nil end
    return Compat.UnitKey("NPC") -- the trade partner's unit token
end

-- Puts gold in our side of the open trade window. Never clicks Trade: the player checks the
-- trade and accepts it themselves.
function Compat.PrefillTrade(copper)
    if TradePlayerInputMoneyFrame and MoneyInputFrame_SetCopper then
        -- Type it into the gold box, so the window shows it like the player typed it.
        MoneyInputFrame_SetCopper(TradePlayerInputMoneyFrame, copper)
        -- The box normally hands the amount to the trade. If the trade didn't pick it up,
        -- set it directly.
        C_Timer.After(0.3, function()
            if not (TradeFrame and TradeFrame:IsShown()) then return end
            if GetPlayerTradeMoney and SetTradeMoney and GetPlayerTradeMoney() ~= copper then
                pcall(SetTradeMoney, copper)
            end
        end)
        return true
    elseif SetTradeMoney then
        return (pcall(SetTradeMoney, copper))
    end
    return false
end

-- Fills in the mailbox's Send Mail form. The player still presses Send themselves.
-- Returns false if no mailbox is open.
function Compat.PrefillMail(recipient, copper, subject)
    if not (MailFrame and MailFrame:IsShown()) then return false end
    if MailFrameTab_OnClick then MailFrameTab_OnClick(nil, 2) end
    if SendMailNameEditBox then SendMailNameEditBox:SetText(recipient) end
    if SendMailSubjectEditBox then SendMailSubjectEditBox:SetText(subject) end
    if SendMailMoney and MoneyInputFrame_SetCopper then
        MoneyInputFrame_SetCopper(SendMailMoney, copper)
    end
    return true
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------

function Compat.HasTemplate(name)
    if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
        return C_XMLUtil.GetTemplateInfo(name) ~= nil
    end
    return true
end

-- Tab template and the spacing between tabs for that template.
function Compat.TabTemplate()
    if C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo("PanelTabButtonTemplate") then
        return "PanelTabButtonTemplate", 3
    end
    return "CharacterFrameTabButtonTemplate", -16
end

-- Pop-up menu at the cursor. items = { { text = "...", func = fn } | { text = "...", isTitle = true } }
-- Uses the newer Menu API where it exists, otherwise UIDropDownMenu.
local dropdown
function Compat.ContextMenu(owner, items)
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(owner, function(_, root)
            for _, item in ipairs(items) do
                if item.isTitle then
                    root:CreateTitle(item.text)
                else
                    root:CreateButton(item.text, item.func)
                end
            end
        end)
        return
    end

    dropdown = dropdown or CreateFrame("Frame", "DuelLadderContextMenu", UIParent, "UIDropDownMenuTemplate")
    UIDropDownMenu_Initialize(dropdown, function(_, level)
        for _, item in ipairs(items) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = item.text
            info.isTitle = item.isTitle
            info.notCheckable = true
            info.func = item.func
            UIDropDownMenu_AddButton(info, level)
        end
    end, "MENU")
    ToggleDropDownMenu(1, nil, dropdown, "cursor", 0, 0)
end

-- PlaySound by SOUNDKIT name, with the numeric id as a fallback for clients that name it differently.
local SOUND_IDS = { LEVEL_UP = 888, READY_CHECK = 8960, IG_CHARACTER_INFO_TAB = 841 }
function Compat.PlaySound(name)
    local id = (SOUNDKIT and SOUNDKIT[name]) or SOUND_IDS[name]
    if id then pcall(PlaySound, id) end
end

------------------------------------------------------------------------
-- Chat and addon messages
------------------------------------------------------------------------

-- Retail moved SendChatMessage into C_ChatInfo; older clients only have the global.
function Compat.SendChatMessage(text, channel)
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    send(text, channel)
end

function Compat.RegisterPrefix(prefix)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(prefix)
    elseif RegisterAddonMessagePrefix then
        RegisterAddonMessagePrefix(prefix)
    end
end

-- Returns "ok", "throttled" or "failed". Older clients return a boolean,
-- newer ones an Enum.SendAddonMessageResult value.
function Compat.SendAddonMessage(prefix, text, channel)
    local send = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
    local result = send(prefix, text, channel)
    if result == nil or result == true or result == 0 then return "ok" end
    if result == false then return "throttled" end
    local enum = Enum and Enum.SendAddonMessageResult
    if enum and (result == enum.AddonMessageThrottle or result == enum.ChannelThrottle) then
        return "throttled"
    end
    return "failed"
end

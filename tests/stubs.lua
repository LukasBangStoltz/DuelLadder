-- Minimal WoW API stubs. PLAYER = { name, realm, class, level, guild }
local P = PLAYER
NOW = 1000
SERVER_TIME = 1700000000
OUT = {}      -- addon messages sent: { prefix, text, channel }
PRINTS = {}
CHAT = {}

function GetTime() return NOW end
function GetServerTime() return math.floor(SERVER_TIME + NOW) end
time = GetServerTime
UNITS = {}
function UnitName(u) if UNITS[u] then return UNITS[u][1], UNITS[u][2] end if u == "player" then return P.name end return nil end
function UnitExists(u) return u == "player" or UNITS[u] ~= nil end
function UnitIsPlayer(u) return UnitExists(u) end
IN_RANGE = true
function CheckInteractDistance(u, i) assert(i == 2); return IN_RANGE end
TRADES_OPENED = {}
function InitiateTrade(u) TRADES_OPENED[#TRADES_OPENED+1] = u end
function UnitClass(u) return P.class, P.class end
function UnitLevel(u) return P.level end
function GetNormalizedRealmName() return P.realm end
function GetRealmName() return P.realm end
function IsInGuild() return P.guild ~= nil end
function GetGuildInfo() return P.guild end
ROSTER = {}
function GetNumGuildMembers() return #ROSTER end
function GetGuildRosterInfo(i) local r = ROSTER[i]; return r[1], "", 0, r[3], "", "", "", "", true, 0, r[2] end
C_GuildInfo = { GuildRoster = function() end }
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function tinsert(t, v) table.insert(t, v) end
UISpecialFrames = {}
RAID_CLASS_COLORS = { WARRIOR = { r = 0.78, g = 0.61, b = 0.43 }, MAGE = { r = 0.25, g = 0.78, b = 0.92 } }
LOCALIZED_CLASS_NAMES_MALE = { WARRIOR = "Warrior", MAGE = "Mage" }
DUEL_WINNER_KNOCKOUT = "%1$s has defeated %2$s in a duel"
DUEL_WINNER_RETREAT = "%2$s has fled from %1$s in a duel"
SlashCmdList = {}
Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, ChannelThrottle = 8 } }
C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
function print(...) local t = {} for i = 1, select("#", ...) do t[#t+1] = tostring((select(i, ...))) end PRINTS[#PRINTS+1] = table.concat(t, " ") end
function SendChatMessage(msg, ch) CHAT[#CHAT+1] = ch .. ": " .. msg end
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() end,
    SendAddonMessage = function(prefix, text, channel)
        assert(#text <= 255, "message too long: " .. #text)
        OUT[#OUT+1] = { prefix, text, channel }
        return 0
    end,
}

-- Timers on a virtual clock
local timers = {}
C_Timer = {}
function C_Timer.After(d, fn) timers[#timers+1] = { at = NOW + d, fn = fn } end
function C_Timer.NewTicker(d, fn)
    local t = { cancelled = false }
    local function step()
        if t.cancelled then return end
        fn()
        if not t.cancelled then C_Timer.After(d, step) end
    end
    C_Timer.After(d, step)
    function t:Cancel() self.cancelled = true end
    return t
end
function ADVANCE(dt)
    local target = NOW + dt
    while true do
        local best, bi
        for i, t in ipairs(timers) do if t.at <= target and (not best or t.at < best.at) then best, bi = t, i end end
        if not best then break end
        table.remove(timers, bi)
        if best.at > NOW then NOW = best.at end
        best.fn()
    end
    NOW = target
end

-- Frames: a mock that accepts any method call
local events = {}
local Mock = {}
local function NewMock()
    local m = setmetatable({ scripts = {}, shown = false, checked = false }, Mock)
    return m
end
Mock.__index = function(self, k)
    local special = {
        SetScript = function(s, name, fn) s.scripts[name] = fn end,
        RegisterEvent = function(s, e) events[e] = s end,
        CreateFontString = function(s) local m = NewMock(); m.parent = s; s.children = s.children or {}; table.insert(s.children, m); return m end,
        CreateTexture = function(s) local m = NewMock(); m.parent = s; s.children = s.children or {}; table.insert(s.children, m); return m end,
        CreateAnimationGroup = function(s) local m = NewMock(); m.parent = s; return m end,
        CreateAnimation = function(s) local m = NewMock(); m.parent = s; return m end,
        GetParent = function(s) return s.parent end,
        GetStringWidth = function() return 50 end,
        IsEnabled = function(s) return s.enabled ~= false end,
        SetEnabled = function(s, v) s.enabled = v and true or false end,
        Enable = function(s) s.enabled = true end,
        Disable = function(s) s.enabled = false end,
        SetParent = function(s, p) s.parent = p end,
        IsShown = function(s) return s.shown end,
        Show = function(s) s.shown = true; if s.scripts.OnShow then s.scripts.OnShow(s) end end,
        Hide = function(s) s.shown = false end,
        SetShown = function(s, v) if v then s:Show() else s:Hide() end end,
        SetText = function(s, t) s.text = t end,
        GetText = function(s) return s.text end,
        SetChecked = function(s, v) s.checked = v end,
        GetChecked = function(s) return s.checked end,
    }
    if special[k] then return special[k] end
    if k == "TitleText" or k == "Left" then return nil end
    if type(k) == "string" and k:match("^%u") then return function() end end
    return nil
end
function CreateFrame(_, name, parent) local m = NewMock(); m.parent = parent; if parent then rawset(parent, 'children', rawget(parent, 'children') or {}); table.insert(parent.children, m) end; if name then _G[name] = m end; return m end
function FIRE(event, ...)
    local f = events[event]
    if f and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
end

Minimap = CreateFrame(); Minimap.GetWidth = nil
GameTooltip = CreateFrame()
function GetCursorPosition() return 0, 0 end
function GetMinimapShape() return "ROUND" end
function Minimap:GetWidth() return 140 end
function Minimap:GetHeight() return 140 end

-- More API for v0.2
HEALTH, MAXHEALTH = 100, 100
function UnitHealth() return HEALTH end
function UnitHealthMax() return MAXHEALTH end
ZONE = "Goldshire"
function GetSubZoneText() return ZONE end
function GetZoneText() return "Elwynn Forest" end
MONEY = 1000 * 10000
function GetMoney() return MONEY end
function GetCoinTextureString(c)
  local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local out = {}
  if g > 0 then out[#out+1] = g .. "g" end
  if s > 0 then out[#out+1] = s .. "s" end
  if cc > 0 or #out == 0 then out[#out+1] = cc .. "c" end
  return table.concat(out, " ")
end
SOUNDKIT = { LEVEL_UP = 888, READY_CHECK = 8960, IG_CHARACTER_INFO_TAB = 841 }
SOUNDS = {}
function PlaySound(id) SOUNDS[#SOUNDS+1] = id end
function PanelTemplates_SetNumTabs() end
function PanelTemplates_SetTab() end
function PanelTemplates_TabResize() end
StaticPopupDialogs = {}
POPUPS = {}
function StaticPopup_Show(name, text) local d = { name = name, text = text }; POPUPS[#POPUPS+1] = d; return d end
function ACCEPT_POPUP() local d = table.remove(POPUPS); StaticPopupDialogs[d.name].OnAccept(d, d.data) end
MailFrame = CreateFrame(); SendMailNameEditBox = CreateFrame(); SendMailSubjectEditBox = CreateFrame(); SendMailMoney = CreateFrame()
MAIL_COPPER = nil
TRADE_MONEY, BOX_PROPAGATES, SET_TRADE_CALLS, ACCEPTED = 0, true, 0, 0
function MoneyInputFrame_SetCopper(f, c) if f == TradePlayerInputMoneyFrame then TRADE_COPPER = c; if BOX_PROPAGATES then TRADE_MONEY = c end else MAIL_COPPER = c end end
function GetPlayerTradeMoney() return TRADE_MONEY end
function SetTradeMoney(c) SET_TRADE_CALLS = SET_TRADE_CALLS + 1; TRADE_MONEY = c end
function AcceptTrade() ACCEPTED = ACCEPTED + 1 end
function MailFrameTab_OnClick() end
TradeFrame = CreateFrame(); TradePlayerInputMoneyFrame = CreateFrame()
MENU_ITEMS = {}
function UIDropDownMenu_Initialize(f, init) MENU_ITEMS = {}; init(f, 1) end
function UIDropDownMenu_CreateInfo() return {} end
function UIDropDownMenu_AddButton(info) MENU_ITEMS[#MENU_ITEMS+1] = info end
function ToggleDropDownMenu() end

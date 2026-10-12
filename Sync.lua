local _, ns = ...
local Compat, Data = ns.Compat, ns.Data

-- Guild sync over hidden addon messages.
--
--   Q^<version>                          "I just came online, send me what you have"
--   E^<key>^<rev>^<part>^<parts>^...     a character's stats, split into chunks
--   P^<id>^<hash>^<part>^<parts>^...     a betting pool, split into chunks
-- (B^ was a one-on-one bet in 0.2; ignored now.)
--
-- When someone asks, everyone waits a random moment and then sends what they know,
-- skipping anything someone else just sent. That way offline members' stats (including
-- your alts) and betting pools still reach new people without everyone repeating them.
local Sync = {}
ns.Sync = Sync

local PREFIX = "DuelLadder"
ns.PREFIX = PREFIX

local CHUNK_SIZE = 170      -- payload bytes per message (the limit is 255 including the header)
local BURST, REGEN = 8, 1   -- our own throttle: messages in a burst, messages regained per second
local HEARD_WINDOW = 30     -- seconds something someone else sent counts as "already sent"
local BUFFER_TTL = 60       -- seconds to keep half-received items

-- What we can send. version(item) is a rev for stats and a checksum for pools.
local KINDS = {
    E = {
        get = function(id) return Data:Entries()[id] end,
        serialize = function(e) return Data.Serialize(e) end,
        version = function(e) return e.rev end,
        -- We have nothing to add if what we heard is the same or newer.
        covered = function(heardVer, e) return heardVer >= e.rev end,
    },
    P = {
        get = function(id) return ns.Bets:All()[id] end,
        serialize = function(b) return ns.Bets.Serialize(b) end,
        version = function(b) return ns.Bets.Hash(b) end,
        covered = function(heardVer, b) return heardVer == ns.Bets.Hash(b) end,
    },
}

local outbox = {}           -- raw messages ready to send
local pending = {}          -- pending["E:key"] = { kind, id, force }
local pendingOrder = {}
local heard = {}            -- heard["E:key"] = { ver, t }, copies other people just sent
local buffers = {}          -- chunks of items being received
local tokens, lastTick = BURST, 0
local ticker
local gossipScheduled = false

-- Splits a string into chunks without cutting a UTF-8 character (names like "Ørn") in half.
local function Chunks(s, size)
    local out, i = {}, 1
    while i <= #s do
        local j = math.min(i + size - 1, #s)
        while j < #s and j > i do
            local b = s:byte(j + 1)
            if b < 0x80 or b >= 0xC0 then break end -- next byte starts a new character
            j = j - 1
        end
        out[#out + 1] = s:sub(i, j)
        i = j + 1
    end
    if #out == 0 then out[1] = "" end
    return out
end

local function HeardRecently(kind, id, item)
    local h = heard[kind .. ":" .. id]
    return h ~= nil and (GetTime() - h.t) < HEARD_WINDOW and KINDS[kind].covered(h.ver, item)
end

local function Pack(kind, id)
    local k = KINDS[kind]
    local item = k.get(id)
    if not item then return end
    local parts = Chunks(k.serialize(item), CHUNK_SIZE)
    for i, chunk in ipairs(parts) do
        outbox[#outbox + 1] = ("%s^%s^%d^%d^%d^%s"):format(kind, id, k.version(item), i, #parts, chunk)
    end
end

local function Tick()
    local now = GetTime()
    tokens = math.min(BURST, tokens + (now - lastTick) * REGEN)
    lastTick = now

    -- Pack the next item once the previous one has gone out.
    while #outbox == 0 and #pendingOrder > 0 do
        local p = pending[table.remove(pendingOrder, 1)]
        pending[p.kind .. ":" .. p.id] = nil
        local item = KINDS[p.kind].get(p.id)
        if item and (p.force or not HeardRecently(p.kind, p.id, item)) then
            Pack(p.kind, p.id)
        end
    end

    while #outbox > 0 and tokens >= 1 do
        if not IsInGuild() then
            wipe(outbox)
            break
        end
        local result = Compat.SendAddonMessage(PREFIX, outbox[1], "GUILD")
        if result == "throttled" then
            tokens = 0 -- the server said slow down; try again in a bit
            break
        end
        table.remove(outbox, 1) -- sent, or failed for good
        tokens = tokens - 1
    end

    if #outbox == 0 and #pendingOrder == 0 and ticker then
        ticker:Cancel()
        ticker = nil
    end
end

function Sync:Kick()
    if ticker then return end
    ticker = C_Timer.NewTicker(0.2, Tick)
    Tick()
end

local function Queue(kind, id, force)
    local slot = kind .. ":" .. id
    local p = pending[slot]
    if p then
        p.force = p.force or force
        return
    end
    pending[slot] = { kind = kind, id = id, force = force }
    if force then
        table.insert(pendingOrder, 1, slot)
    else
        pendingOrder[#pendingOrder + 1] = slot
    end
    Sync:Kick()
end

-- Sends our own stats right away (after a duel, level up, or login).
function Sync:SendOwn()
    if not Data.guild then return end
    Queue("E", Compat.PlayerKey(), true)
end

-- Sends a betting pool we just changed.
function Sync:SendPool(id)
    if not Data.guild then return end
    Queue("P", id, true)
end

-- Asks the guild for everything they know.
function Sync:Request()
    if not Data.guild or not IsInGuild() then return end
    table.insert(outbox, 1, "Q^" .. ns.VERSION)
    self:SendOwn()
    self:Kick()
end

local function OnRequest()
    if gossipScheduled then return end
    gossipScheduled = true
    C_Timer.After(1 + math.random() * 5, function()
        gossipScheduled = false
        if not Data.guild then return end
        Queue("E", Compat.PlayerKey(), true)
        for key in pairs(Data:Entries()) do Queue("E", key, false) end
        for id in pairs(ns.Bets:All()) do Queue("P", id, false) end
    end)
end

-- Something arrived in full: apply it.
local function OnComplete(kind, id, ver, payload)
    if kind == "E" then
        local e = Data.Deserialize(payload)
        if e and e.rev == ver and Data:ApplyRemote(id, e) then
            if Data:CheckCrown() then Sync:SendOwn() end
            ns:Fire("DATA_CHANGED")
        end
    else
        local b = ns.Bets.Deserialize(payload)
        if b and b.id == id and ns.Bets:Merge(b) then
            ns:Fire("BETS_CHANGED")
            ns.Bets:Resolve()
        end
    end
end

local function OnChunk(sender, kind, text)
    local id, ver, part, parts, chunk = text:match("^%a%^([^%^]+)%^(%d+)%^(%d+)%^(%d+)%^(.*)$")
    if not id then return end
    ver, part, parts = tonumber(ver), tonumber(part), tonumber(parts)
    if parts < 1 or parts > 50 or part < 1 or part > parts then return end

    -- Someone is sending this, so we don't need to repeat it.
    local slot = kind .. ":" .. id
    local h = heard[slot]
    if kind == "P" or not h or ver >= h.ver then heard[slot] = { ver = ver, t = GetTime() } end

    -- Skip what we already have.
    local cur = KINDS[kind].get(id)
    if cur and ((kind == "E" and cur.rev >= ver) or (kind == "P" and ns.Bets.Hash(cur) == ver)) then return end

    local now = GetTime()
    for bufId, buf in pairs(buffers) do
        if now - buf.t > BUFFER_TTL then buffers[bufId] = nil end
    end

    local bufId = sender .. "|" .. slot .. "|" .. ver
    local buf = buffers[bufId]
    if not buf then
        buf = { parts = parts, got = 0, chunks = {}, t = now }
        buffers[bufId] = buf
    end
    if buf.parts ~= parts then return end
    if not buf.chunks[part] then
        buf.chunks[part] = chunk
        buf.got = buf.got + 1
    end
    if buf.got < buf.parts then return end
    buffers[bufId] = nil
    OnComplete(kind, id, ver, table.concat(buf.chunks, "", 1, buf.parts))
end

ns:Listen("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
    if prefix ~= PREFIX or channel ~= "GUILD" or not Data.guild then return end
    sender = Compat.FullName(sender)
    if not sender or sender == Compat.PlayerKey() then return end

    local kind = text:sub(1, 1)
    if kind == "Q" then
        OnRequest()
    elseif KINDS[kind] then
        OnChunk(sender, kind, text)
    end
end)

ns:On("GUILD_READY", function()
    Sync:Request()
end)

ns:Listen("PLAYER_LEVEL_UP", function()
    -- UnitLevel isn't updated yet when the event fires.
    C_Timer.After(1, function()
        if Data:TouchMyEntry() then
            Sync:SendOwn()
            ns:Fire("DATA_CHANGED")
        end
    end)
end)

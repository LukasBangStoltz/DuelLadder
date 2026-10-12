local _, ns = ...
local Compat, Data, UI = ns.Compat, ns.Data, ns.UI

-- History tab: recent duels across the guild, newest first. Built from every member's last
-- few duels; a duel both players recorded is shown once.

local ROWS = 22
local SAME_DUEL_SECONDS = 10

local COLUMNS = {
    { key = "when",   label = "When",   width = 72 },
    { key = "winner", label = "Winner", width = 140 },
    { key = "verb",   label = "",       width = 60 },
    { key = "loser",  label = "Loser",  width = 140 },
    { key = "change", label = "Rating", width = 80, align = "RIGHT" },
    { key = "zone",   label = "Where",  width = 180 },
}

local tbl, footer

local function BuildFeed()
    local raw = {}
    for _, key in ipairs(Data:Members()) do
        for _, r in ipairs(Data:Entries()[key].recent) do
            local won = r.r == "W"
            raw[#raw + 1] = {
                t = r.t,
                winner = won and key or r.o,
                loser = won and r.o or key,
                fled = r.r == "F",
                winnerDelta = won and r.d or nil,
                loserDelta = not won and r.d or nil,
                zone = r.z,
            }
        end
    end
    table.sort(raw, function(a, b) return a.t > b.t end)

    -- Merge the two sides of the same duel.
    local feed = {}
    for _, item in ipairs(raw) do
        local merged = false
        for i = #feed, math.max(1, #feed - 5), -1 do
            local f = feed[i]
            if f.winner == item.winner and f.loser == item.loser and math.abs(f.t - item.t) <= SAME_DUEL_SECONDS then
                f.winnerDelta = f.winnerDelta or item.winnerDelta
                f.loserDelta = f.loserDelta or item.loserDelta
                f.fled = f.fled or item.fled
                if f.zone == "" then f.zone = item.zone end
                merged = true
                break
            end
        end
        if not merged then feed[#feed + 1] = item end
    end
    return feed
end

local function Delta(d)
    if not d then return "|cff555555?|r" end
    if d >= 0 then return ("|cff20ff20+%d|r"):format(d) end
    return ("|cffff4040%d|r"):format(d)
end

local function Build(content)
    tbl = UI.CreateTable(content, COLUMNS, ROWS, { onScroll = function() UI:RequestRefresh() end })
    footer = UI.CreateFooter(content, 2)
end

local function Refresh()
    local feed = BuildFeed()
    tbl:Fill(feed, function(row, item)
        local c = row.cells
        c.when:SetText(UI.Ago(item.t))
        c.winner:SetText(UI.Name(item.winner, true))
        c.verb:SetText(item.fled and "|cff888888scared off|r" or "|cff888888defeated|r")
        c.loser:SetText(UI.Name(item.loser, true))
        c.change:SetText(Delta(item.winnerDelta) .. " / " .. Delta(item.loserDelta))
        c.zone:SetText(item.zone ~= "" and item.zone or "|cff555555?|r")
    end)
    footer:SetText(#feed > 0 and ("The last %d duels the guild knows about. Each member shares their %d most recent."):format(#feed, Data.RECENT_MAX)
        or "No duels yet. Go hit someone!")
end

UI:AddTab("History", Build, Refresh)

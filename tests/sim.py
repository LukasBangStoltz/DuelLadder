"""Main test suite and the shared harness: runs the addon in Lua 5.1 with fake WoW APIs
and simulates several guild members dueling, syncing and betting. See README.md."""
import os, sys
from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.dirname(HERE)  # the addon folder is the parent of tests/
STUBS = open(os.path.join(HERE, "stubs.lua"), encoding="utf-8").read()
REALM, GUILD = "Spineshatter", "Fun Times"

# Load order straight from the .toc (XML includes mapped to their Lua file)
XML_TO_LUA = {
    r"Libs\CallbackHandler-1.0\CallbackHandler-1.0.xml": r"Libs\CallbackHandler-1.0\CallbackHandler-1.0.lua",
    r"Libs\LibDBIcon-1.0\lib.xml": r"Libs\LibDBIcon-1.0\LibDBIcon-1.0.lua",
}
FILES = []
for line in open(os.path.join(ADDON, "DuelLadder.toc"), encoding="utf-8"):
    line = line.strip()
    if line and not line.startswith("#"):
        FILES.append(XML_TO_LUA.get(line, line))

HELPERS = r"""
function SER(v)
  local t = type(v)
  if t == "table" then
    local out = {}
    for k, x in pairs(v) do out[#out+1] = "[" .. SER(k) .. "]=" .. SER(x) end
    return "{" .. table.concat(out, ",") .. "}"
  elseif t == "string" then return string.format("%q", v)
  else return tostring(v) end
end
-- Every text currently set on any fake widget
function ALLTEXT()
  local out, seen = {}, {}
  local function walk(o, depth)
    if depth > 14 or type(o) ~= "table" or seen[o] then return end
    seen[o] = true
    local txt = rawget(o, "text")
    if type(txt) == "string" then out[#out+1] = txt end
    for _, v in pairs(o) do if type(v) == "table" then walk(v, depth + 1) end end
  end
  walk(_G, 0)
  return table.concat(out, "\n")
end
function FINDTEXT(text)
  local found, seen = nil, {}
  local function walk(o, depth)
    if found or depth > 14 or type(o) ~= "table" or seen[o] then return end
    seen[o] = true
    if rawget(o, "text") == text and rawget(o, "scripts") then found = o return end
    for _, v in pairs(o) do walk(v, depth + 1) end
  end
  walk(_G, 0)
  return found
end
function FINDITEM(value)
  local found, seen = nil, {}
  local function walk(o, depth)
    if found or depth > 14 or type(o) ~= "table" or seen[o] then return end
    seen[o] = true
    if rawget(o, "item") == value and rawget(o, "scripts") and rawget(o, "shown") then found = o return end
    for _, v in pairs(o) do walk(v, depth + 1) end
  end
  walk(_G, 0)
  return found
end
function BETCOUNT() local n = 0 for _ in pairs(NS.Bets:All()) do n = n + 1 end return n end
"""

ROSTER = [("Anna", "WARRIOR", 70), ("Annalt", "MAGE", 20), ("Bo", "MAGE", 70), ("Carl", "WARRIOR", 70),
          ("Dina", "PRIEST", 70), ("Erik", "ROGUE", 70), ("Østen", "WARRIOR", 70)]

def K(name): return f"{name}-{REALM}"

class Client:
    def __init__(self, name, cls, level, db=None, now=1000, extra=""):
        self.name = name
        L = lua51.LuaRuntime(unpack_returned_tuples=True)
        self.L = L
        L.execute(f'PLAYER = {{ name = "{name}", realm = "{REALM}", class = "{cls}", level = {level}, guild = "{GUILD}" }}')
        L.execute(STUBS)
        L.execute(HELPERS)
        L.execute(f"NOW = {now}")
        L.execute(extra)
        L.execute("ROSTER = {" + ",".join(f'{{"{K(n)}","{c}",{l}}}' for n, c, l in ROSTER) + "}")
        if db:
            L.execute("DuelLadderDB = " + db)
        L.execute("NS = {}")
        for f in FILES:
            src = open(os.path.join(ADDON, f), encoding="utf-8").read()
            name_ = f.replace("\\", "/")
            L.eval(f"function(src) local chunk, err = loadstring(src, {name_!r}); assert(chunk, err); chunk('DuelLadder', NS) end")(src)
        L.execute('FIRE("PLAYER_LOGIN")')
        L.execute('FIRE("GUILD_ROSTER_UPDATE")')

    def key(self): return K(self.name)
    def run(self, code): return self.L.execute(code)
    def eval(self, code): return self.L.eval(code)
    def db(self): return self.L.eval("SER(DuelLadderDB)")
    def stat(self, who, field):
        return self.L.eval(f'(function() local e = NS.Data:Entries()["{K(who)}"]; return e and e.{field} end)()')
    def badge(self, who, bid):
        return self.L.eval(f'(function() local e = NS.Data:Entries()["{K(who)}"]; return e and e.badges["{bid}"] end)()')
    def king(self): return self.L.eval("(NS.Data:King())")
    def bet(self, bid, field):
        return self.L.eval(f'(function() local b = NS.Bets:All()["{bid}"]; return b and b.{field} end)()')
    def bet_state(self, bid):
        return self.L.eval(f'(function() local b = NS.Bets:All()["{bid}"]; return b and NS.Bets.State(b) end)()')
    def prints(self): return "\n".join(self.L.eval("PRINTS").values())

clients = {}
sent_log = []

def online(): return list(clients.values())

def pump(seconds, step=0.2):
    t = 0.0
    while t < seconds:
        for c in online():
            c.run(f"ADVANCE({step})")
        for c in online():
            out = c.eval("OUT")
            msgs = [(out[i][1], out[i][2], out[i][3]) for i in range(1, len(out) + 1)]
            c.run("OUT = {}")
            for prefix, text, channel in msgs:
                sent_log.append((c.name, text))
                for o in online():
                    if o is not c:
                        o.L.globals().FIRE("CHAT_MSG_ADDON", prefix, text, channel, c.key())
        t += step

def duel(winner, loser, fled=False, duration=20, winner_hp=50, others=()):
    """Combat starts, time passes, both duelists (and bystanders) get the result message."""
    involved = [clients[n] for n in (winner, loser) if n in clients]
    for c in involved:
        c.L.globals().FIRE("PLAYER_REGEN_DISABLED")
    pump(duration)
    for c in involved:
        c.run(f"HEALTH = {winner_hp if c.name == winner else 1}")
    msg = f"{loser} has fled from {winner} in a duel" if fled else f"{winner} has defeated {loser} in a duel"
    for c in involved + [clients[n] for n in others if n in clients]:
        c.L.globals().FIRE("CHAT_MSG_SYSTEM", msg)
    pump(8)

def login(name, cls, level, db=None):
    now = max([c.eval("NOW") for c in online()] or [1000])
    clients[name] = Client(name, cls, level, db, now)
    return clients[name]

def logout(name):
    return clients.pop(name).db()

failures = 0
def check(cond, label):
    global failures
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        failures += 1

def all_agree(fn, label):
    vals = [fn(c) for c in online()]
    check(len(set(map(repr, vals))) == 1, f"{label} (all clients agree: {vals[0]!r})")
    return vals[0]

# --- 1. Login and sync -------------------------------------------------------
a = login("Anna", "WARRIOR", 70)
b = login("Bo", "MAGE", 70)
c = login("Carl", "WARRIOR", 70)
d = login("Dina", "PRIEST", 70)
pump(30)
check(all(x.stat(y, "rating") == 1500 for x in online() for y in ["Anna", "Bo", "Carl", "Dina"]), "everyone starts at 1500 and is known by everyone")

# --- 2. Rating, crown, badges ---------------------------------------------
duel("Anna", "Bo", duration=10, winner_hp=95, others=["Carl"])
check(a.stat("Anna", "rating") == 1520 and a.stat("Bo", "rating") == 1480, "first duel: +20 / -20")
check(a.badge("Anna", "fb") == 1 and a.badge("Anna", "fl") == 1 and a.badge("Anna", "sp") == 1, "Anna earned First Blood, Flawless, Speedrun")
check(a.badge("Bo", "fb") is None, "loser got no First Blood")
check(all_agree(lambda x: x.king(), "king after first duel") == K("Anna"), "Anna claimed the empty crown")
check("King of the Hill" in a.prints(), "Anna was told she's king")

duel("Carl", "Anna", duration=30, winner_hp=5)
check(c.stat("Carl", "rating") == 1521, f"Carl gains 21 for beating a higher-rated player (got {c.stat('Carl', 'rating')})")
check(all_agree(lambda x: x.king(), "king") == K("Carl"), "Carl took the crown")
check(c.badge("Carl", "kr") == 1 and c.badge("Carl", "cl") == 1, "Carl earned Kingslayer and Clutch")
check(a.stat("Anna", "crown") == 0, "Anna's crown was cleared")
check(c.badge("Carl", "sb") is None, "no Streak Breaker for ending a 1-win streak")

# --- 3. Defender, Chicken, Marathon, Streak Breaker ----------------------
for i in range(5):
    duel("Carl", "Bo", fled=True, duration=5)
check(c.stat("Carl", "defenses") == 5 and c.badge("Carl", "de") == 1, "Carl defended 5 times -> Defender")
check(b.stat("Bo", "fled") == 5 and b.badge("Bo", "ch") == 1, "Bo fled 5 times -> Chicken")
check(c.stat("Carl", "streak") == 6 and c.badge("Carl", "s5") == 1, "Carl hit a 5 streak -> Rampage, now on 6")
duel("Dina", "Carl", duration=130, winner_hp=40)
check(d.badge("Dina", "sb") == 1 and d.badge("Dina", "ma") == 1, "Dina broke Carl's streak in a long duel -> Streak Breaker + Marathon")
check(c.badge("Carl", "ma") == 1, "loser also gets Marathon")
check(all_agree(lambda x: x.king(), "king") == K("Dina"), "Dina is the new king")
title = all_agree(lambda x: x.eval('(NS.Data.Title(NS.Data:Entries()["Carl-Spineshatter"]))'), "Carl's title")
check(title in ("Duelist", "Champion"), "Carl has a real title after 8 duels")
check(all_agree(lambda x: x.eval('(NS.Data.Title(NS.Data:Entries()["Dina-Spineshatter"]))'), "Dina's title") == "Recruit", "Dina is a Recruit until 5 duels")

# --- 4. A challenge (one-on-one) and a public pot on the same duel -----------
A, B, C, D, E = K("Anna"), K("Bo"), K("Carl"), K("Dina"), K("Erik")
G = 10000
cid = a.eval(f'NS.Bets:Challenge("{B}", 60 * {G})')
pump(8)
check("challenges you to a duel for" in b.prints(), "Bo was told about the challenge")
ok, err = a.eval(f'NS.Bets:Challenge("{B}", 5 * {G})')
check(ok is None and "already challenged" in err, "one open challenge per opponent")
ok, err = c.eval(f'NS.Bets:Accept("{cid}")')
check(ok is None and "isn't for you" in err, "Carl can't accept Bo's challenge")
check(b.eval(f'NS.Bets:Accept("{cid}")') == cid, "Bo accepts")
check(b.eval(f'NS.Bets:All()["{cid}"].stakes["{B}"].amt') == 60 * G, "accepting matches the 60g")
pid = c.eval(f'NS.Bets:Place("{A}", "{B}", "{A}", 20 * {G})')
check(pid is not None and pid != cid, "Carl's bet goes into a separate public pot, not the challenge")
pump(8)
check(d.eval(f'NS.Bets:Place("{B}", "{A}", "{B}", 10 * {G} + 50 * 100)') == pid, "Dina puts 10g 50s on Bo (fighters in either order)")
ok, err = c.eval(f'NS.Bets:Place("{A}", "{B}", "{B}", 5 * {G})')
check(ok is None and "already" in err, "one bet per person per pot")
ok, err = a.eval(f'NS.Bets:Place("{A}", "{B}", "{B}", 5 * {G})')
check(ok is None and "against yourself" in err, "Anna can't bet against herself")
pump(10)
check(all_agree(lambda x: x.eval("BETCOUNT()"), "pots") == 2, "everyone has the challenge and the public pot")
duel("Bo", "Anna")
transfers_lua = lambda pool_id: f'(function() local out = {{}} for _, t in ipairs(NS.Bets.Transfers(NS.Bets:All()["{pool_id}"])) do out[#out+1] = t.from .. ">" .. t.to .. ":" .. t.copper end return table.concat(out, " ") end)()'
check(all_agree(lambda x: x.eval(transfers_lua(cid)), "challenge payments") == f"{A}>{B}:600000", "challenge: Anna pays Bo 60g")
check(all_agree(lambda x: x.eval(transfers_lua(pid)), "pot payments") == f"{C}>{D}:200000", "public pot: Carl pays Dina 20g")
check(b.badge("Bo", "hr") == 1, "Bo won 60g -> High Roller")
check("You won" in d.prints() and "You lost" in c.prints(), "winners and losers are told")
check(c.eval("select(3, NS.Bets:Balance())") == 200000, "Carl owes 20g in total")

# --- 5. Paying -------------------------------------------------------------------
c.run("MailFrame:Show()")
c.eval(f'NS.Bets:Pay("{pid}", "{D}")')
check(c.eval("SendMailNameEditBox.text") == "Dina" and c.eval("MAIL_COPPER") == 200000, "Pay fills in a mail to Dina for 20g")
c.run("MailFrame:Hide()")
check(c.eval(f'NS.Bets:MarkPaid("{pid}", "{C}")')[0] is False, "you can't confirm your own payment")
check(d.eval(f'NS.Bets:MarkPaid("{pid}", "{C}")') is True, "Dina confirms Carl paid her")
check(b.eval(f'NS.Bets:MarkPaid("{cid}", "{A}")') is True, "Bo confirms Anna paid him")
pump(8)
check(all_agree(lambda x: (x.bet_state(pid), x.bet_state(cid)), "states") == ("paid", "paid"), "both are fully paid everywhere")

# --- 6. Cancelling before the duel -------------------------------------------
xid = a.eval(f'NS.Bets:Place("{C}", "{D}", "{C}", 15 * {G})')
pump(8)
check(a.eval(f'NS.Bets:Cancel("{xid}")') is True, "Anna cancels her bet before the duel")
pump(8)
check(all(x.eval(f'NS.Bets:All()["{xid}"].stakes["{A}"].cancel ~= nil') for x in online()), "everyone sees the cancel")
ok, err = a.eval(f'NS.Bets:Place("{C}", "{D}", "{D}", 15 * {G})')
check(ok is None and "cancelled" in err, "can't bet again on a duel you cancelled on")
ok, err = b.eval(f'NS.Bets:Cancel("{xid}")')
check(ok is False, "you can only cancel your own bet")

# --- 7. Latecomer gets everything -------------------------------------------
sent_log.clear()
e = login("Erik", "ROGUE", 70)
pump(60)
for who in ["Anna", "Bo", "Carl", "Dina"]:
    check(e.stat(who, "rev") == d.stat(who, "rev"), f"Erik has {who}'s latest stats")
check(e.eval("BETCOUNT()") == 3, f"Erik received all 3 pots (got {e.eval('BETCOUNT()')})")
check(e.eval(transfers_lua(pid)) == d.eval(transfers_lua(pid)) and e.bet_state(cid) == "paid", "Erik's copies match")
check(e.king() == K("Dina"), "Erik knows who the king is")
lens = [len(t.encode("utf-8")) for _, t in sent_log]
check(max(lens) <= 255, f"no addon message over 255 bytes (max {max(lens)}; {len(lens)} messages to catch Erik up)")

# --- 9. Stats survive a wiped SavedVariables --------------------------------
logout("Bo")
b = login("Bo", "MAGE", 70)
pump(40)
check(b.stat("Bo", "fled") == 5 and b.badge("Bo", "hr") == 1 and b.stat("Bo", "rating") == d.stat("Bo", "rating"), "Bo's stats and badges restored from the guild")

# --- 10. Serialization edge cases --------------------------------------------
rt = a.eval(r'''(function()
  local e = NS.Data:MyEntry()
  table.insert(e.recent, 1, { t = 5, o = "Østen-Spineshatter", r = "L", d = -17, z = "Lion's Pride Inn: Goldshire, Elwynn; ^|" })
  local s = NS.Data.Serialize(e)
  local back = NS.Data.Deserialize(s)
  table.remove(e.recent, 1)
  return back.recent[1].o .. "|" .. back.recent[1].d .. "|" .. back.recent[1].z .. "|" .. tostring(NS.Data.Serialize(back) == s)
end)()''')
check(rt == "Østen-Spineshatter|-17|Lion's Pride Inn Goldshire Elwynn |true", f"entry round-trips with UTF-8, negative delta and a messy zone ({rt})")

# --- 11. UI: every tab renders -------------------------------------------------
d.run("NS.UI:Toggle()")
for tab in ["Ladder", "Members", "Matchups", "History", "Bets", "Badges"]:
    try:
        d.run(f'NS.UI:ShowTab("{tab}")')
        d.run("ADVANCE(1)")
        check(True, f"{tab} tab renders")
    except Exception as ex:
        check(False, f"{tab} tab renders: {ex}")

d.run('NS.UI:ShowProfile("Anna-Spineshatter")'); d.run("ADVANCE(1)")
text = d.eval("ALLTEXT()")
check("Nemesis:" in text and "Favourite victim:" in text, "profile shows nemesis / victim / rival")
check("Against other members" in text, "profile shows records against other members")
check("Your badges:" in text and "Progress: " in text, "badges tab shows your own collection with progress")
check("Your betting total" in text, "bets tab shows a summary")
check("scared off" in text, "history shows fled duels")
check("Challenge Anna for" in text, "profile offers a challenge")

# Members tab: clicking another member switches the profile
d.run('NS.UI:ShowTab("Members")'); d.run("ADVANCE(1)")
d.run('''local row = FINDITEM("Carl-Spineshatter"); row.scripts.OnClick(row, "LeftButton"); ADVANCE(1)''')
text = d.eval("ALLTEXT()")
check("Challenge Carl for" in text, "clicking Carl in the member list shows Carl's profile")
d.run('''local row = FINDITEM("Bo-Spineshatter"); row.scripts.OnClick(row, "LeftButton"); ADVANCE(1)''')
check("Challenge Bo for" in d.eval("ALLTEXT()"), "clicking Bo switches to Bo's profile")

# Badges tab: only Dina's own badges
d.run('NS.UI:ShowTab("Badges")'); d.run("ADVANCE(1)")
text = d.eval("ALLTEXT()")
check("Your badges:" in text and "earned |cffffffff4|r of 18" in text, "badges tab counts Dina's 4 badges (incl. Kingslayer)")
check("Progress: 1 / 50 duels" in text, "locked badges show progress (Veteran 1/50)")

# Ladder rows: king has the crown
d.run('NS.UI:ShowTab("Ladder")'); d.run("ADVANCE(1)")
text = d.eval("ALLTEXT()")
check("UI-Group-LeaderIcon:0|t|cff" in text and "Dina" in text, "ladder shows the crown")

# Matchups: Carl vs Bo is 5-0 from Carl's row
d.run('NS.UI:ShowTab("Matchups")'); d.run("ADVANCE(1)")
text = d.eval("ALLTEXT()")
pairs_ = d.eval(r"""(function() local out, seen = {}, {}
  local function walk(o, depth)
    if depth > 14 or type(o) ~= "table" or seen[o] then return end
    seen[o] = true
    local p = rawget(o, "pair")
    if type(p) == "table" and rawget(o, "shown") then out[#out+1] = p.a .. " " .. p.wa .. "-" .. p.wb .. " " .. p.b .. " | " .. rawget(o, "info").text end
    for _, v in pairs(o) do walk(v, depth + 1) end
  end
  walk(_G, 0)
  table.sort(out)
  return table.concat(out, "|") end)()""")
print("     matchup rows:", pairs_)
check("Carl-Spineshatter 5-0 Bo-Spineshatter | 5 duels" in pairs_, "matchups list shows Carl 5 - 0 Bo, leader on the left")
check("Anna-Spineshatter 1-1 Bo-Spineshatter" in pairs_, "Anna and Bo are all square at 1 - 1")
# Bet button on the Carl-Bo row opens the popup with the record in words
d.run(r"""
  local found, seen = nil, {}
  local function walk(o, depth)
    if found or depth > 14 or type(o) ~= "table" or seen[o] then return end
    seen[o] = true
    local p = rawget(o, "pair")
    if type(p) == "table" and p.a == "Carl-Spineshatter" and p.b == "Bo-Spineshatter" then found = o return end
    for _, v in pairs(o) do walk(v, depth + 1) end
  end
  walk(_G, 0)
  found.bet.scripts.OnClick(found.bet)
""")
check(d.eval("DuelLadderBetPopup.hint.text") == "Carl leads 5 - 0.", "row Bet button opens the popup with 'Carl leads 5 - 0'")
# Picker: choose Erik as the second fighter, then Bet
d.run(r"""
  local pick = FINDTEXT("|cff888888choose...|r")
  pick.scripts.OnClick(pick)
  for _, item in ipairs(MENU_ITEMS) do if item.text and item.text:find("Erik") and item.func then item.func() end end
  ADVANCE(1)
""")
check("Erik" in d.eval("ALLTEXT()") and d.eval('FINDTEXT("|cff888888choose...|r") == nil'), "picker lets you choose a second fighter")
d.run(r"""
  local found, seen = nil, {}
  local function walk(o, depth)
    if found or depth > 14 or type(o) ~= "table" or seen[o] then return end
    seen[o] = true
    if rawget(o, "text") == "Bet" and rawget(o, "scripts") and rawget(o, "parent") and rawget(rawget(o, "parent"), "nameA") == nil then found = o return end
    for _, v in pairs(o) do walk(v, depth + 1) end
  end
  walk(_G, 0)
  found.scripts.OnClick(found)
""")
check(d.eval("DuelLadderBetPopup.title.text") == "Bet on Dina vs Erik", "picker's Bet opens a popup for Dina vs Erik")
check(d.eval("DuelLadderBetPopup.hint.text").startswith("They haven't dueled yet"), "popup says they haven't dueled yet")

# History: each duel once even though both sides recorded it
d.run('NS.UI:ShowTab("History")'); d.run("ADVANCE(1)")
n_history = d.eval("(function() local n = 0 for _ in ALLTEXT():gmatch('defeated') do n = n + 1 end for _ in ALLTEXT():gmatch('scared off') do n = n + 1 end return n end)()")
check(n_history <= 22, f"history merges both sides of a duel ({n_history} rows shown)")

# Bet popup from the matchups list, placed through the confirm dialog
before = d.eval("BETCOUNT()")
d.run(f'NS.UI:OpenBetPopup("{A}", "{C}")')
d.run('DuelLadderBetPopup.money:SetCopper(70000)')
d.run("DuelLadderBetPopup.backB.scripts.OnClick(DuelLadderBetPopup.backB)")
check("Nobody is on Anna yet" in d.eval("DuelLadderBetPopup.preview.text"), "preview explains you only win once someone bets on the other side")
d.run('local btn = FINDTEXT("Place bet"); btn.scripts.OnClick(btn); ACCEPT_POPUP()')
check(d.eval("BETCOUNT()") == before + 1, "placing a bet from the popup opens a new pot")
npid = d.eval(f'NS.Bets:OpenPool("{A}", "{C}").id')
check(d.eval(f'NS.Bets:All()["{npid}"].stakes["{D}"].side') == C, "Dina's 7g is on Carl")

# Popup when you're one of the fighters: only your own side
d.run(f'NS.UI:OpenBetPopup("{D}", "{B}")')
check(d.eval("DuelLadderBetPopup.backB:IsEnabled()") is False and d.eval("DuelLadderBetPopup.pick") == D, "fighters can only back themselves in the popup")

# Erik joins Dina's pot from the Bets tab: "Bet" opens the popup, he backs Anna
pump(8)
e.run("NS.UI:Toggle(); NS.UI:ShowTab('Bets')"); e.run("ADVANCE(1)")
e.run(f"""
  local found, seen = nil, {{}}
  local function walk(o, depth)
    if found or depth > 14 or type(o) ~= "table" or seen[o] then return end
    seen[o] = true
    local item = rawget(o, "item")
    if type(item) == "table" and item.pool and item.pool.id == "{npid}" and rawget(o, "button") then found = o.button return end
    for _, v in pairs(o) do walk(v, depth + 1) end
  end
  walk(_G, 0)
  found.scripts.OnClick(found)
""")
check(e.eval("DuelLadderBetPopup.title.text") == "Bet on Anna vs Carl", "Bets tab Bet button opens that duel's popup")
check("Carl 7g (1 bet)" in e.eval("DuelLadderBetPopup.pot.text"), "popup shows the pot so far")
e.run('DuelLadderBetPopup.money:SetCopper(140000); DuelLadderBetPopup.backA.scripts.OnClick(DuelLadderBetPopup.backA)')
check("+ 7g" in e.eval("DuelLadderBetPopup.preview.text"), f"preview: 14g on Anna would win Dina's 7g ({e.eval('DuelLadderBetPopup.preview.text')})")
e.run('local btn = FINDTEXT("Place bet"); btn.scripts.OnClick(btn); ACCEPT_POPUP()')
pump(8)
check(d.eval(f'NS.Bets:All()["{npid}"].stakes["{E}"].amt') == 140000, "Erik's 14g on Anna reached Dina")
check("Erik put" in d.prints(), "Dina is told Erik joined her pot")

# Reopening the popup with a bet in it offers Cancel
d.run(f'NS.UI:OpenBetPopup("{A}", "{C}")')
check("You have |cffffffff7g|r on Carl" in d.eval("DuelLadderBetPopup.mineText.text"), "popup shows your own bet")
d.run('local btn = FINDTEXT("Cancel my bet"); btn.scripts.OnClick(btn)')
check(d.eval(f'NS.Bets:All()["{npid}"].stakes["{D}"].cancel ~= nil'), "Cancel my bet withdraws it")

# Minimap tooltip
tip = d.eval(r"""(function() local lines = {}
  local tt = { AddLine = function(_, t) lines[#lines+1] = t end, AddDoubleLine = function(_, a, b) lines[#lines+1] = a .. ' = ' .. b end }
  LibStub('LibDataBroker-1.1'):GetDataObjectByName('DuelLadder').OnTooltipShow(tt)
  return table.concat(lines, '\n') end)()""")
print("     minimap tooltip (Dina):\n       " + tip.replace("\n", "\n       "))
check("King of the Hill" in tip and "1. " in tip, "minimap tooltip shows king and top 3")

d.run("SlashCmdList.DUELLADDER('help'); SlashCmdList.DUELLADDER('bets'); SlashCmdList.DUELLADDER('me'); SlashCmdList.DUELLADDER('minimap'); SlashCmdList.DUELLADDER('minimap')")
check(d.eval("NS.Data.settings.minimap.hide") is False, "slash commands run")

# --- 12. Localized duel strings -------------------------------------------------
g = Client("Carl", "WARRIOR", 70, extra='DUEL_WINNER_RETREAT = "%2$s ist vor %1$s aus dem Duell geflohen."')
g.run("ADVANCE(5)")
g.L.globals().FIRE("CHAT_MSG_SYSTEM", "Bo ist vor Carl aus dem Duell geflohen.")
check(g.eval('NS.Data:MyEntry().w') == 1, "German-style reordered format parsed")
g.L.globals().FIRE("CHAT_MSG_SYSTEM", "Anna has defeated Bo in a duel")
check(g.eval('NS.Data:MyEntry().w') == 1, "other people's duels ignored")

print(f"\n{failures} failure(s)")
sys.exit(1 if failures else 0)

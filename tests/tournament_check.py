"""Tournaments: sign-ups, seeding by rating, byes, old duels not counting, the best-of-three
final, walkovers, match and champion pots, badges and guild sync."""
import os
HERE = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(HERE, "sim.py"), encoding="utf-8").read().split("# --- 1. Login and sync")[0])

G = 10000
A, B, C, D, E, O = K("Anna"), K("Bo"), K("Carl"), K("Dina"), K("Erik"), K("Østen")
a = login("Anna", "WARRIOR", 70)
b = login("Bo", "MAGE", 70)
c = login("Carl", "WARRIOR", 70)
d = login("Dina", "PRIEST", 70)
e = login("Erik", "ROGUE", 70)
o = login("Østen", "WARRIOR", 70)
pump(30)

def name(key): return key.split("-")[0]

# UI helpers: find a widget whose .item / .match matches, or a button by its text inside a frame.
UI_HELPERS = r"""
function FINDWHERE(pred)
  local found, seen = nil, {}
  local function walk(o, depth)
    if found or depth > 16 or type(o) ~= "table" or seen[o] then return end
    seen[o] = true
    if rawget(o, "scripts") and pred(o) then found = o return end
    for _, v in pairs(o) do walk(v, depth + 1) end
  end
  walk(_G, 0)
  return found
end
function BUTTON_IN(frame, text)
  local found, seen = nil, {}
  local function walk(o, depth)
    if found or depth > 8 or type(o) ~= "table" or seen[o] then return end
    seen[o] = true
    if rawget(o, "text") == text and rawget(o, "scripts") and rawget(o, "scripts").OnClick then found = o return end
    for _, v in pairs(rawget(o, "children") or {}) do walk(v, depth + 1) end
  end
  walk(frame, 0)
  return found
end
function CLICK(b, button) b.scripts.OnClick(b, button or "LeftButton") end
"""
def ui(x):
    x.run(UI_HELPERS)
    x.run("NS.UI:Toggle(); NS.UI:ShowTab('Tournament'); ADVANCE(1)")
    return x.eval("ALLTEXT()")
def T(x, code): return x.eval(f"(function() local T = NS.Tournament; local t = T:All()[TID]; {code} end)()")
def tset(tid):
    for x in online():
        x.run(f'TID = "{tid}"')
def match(x, mid, field):
    return T(x, f'local m = T.Bracket(t).byId["{mid}"]; return m and m.{field}')
def pot_state(x, mid): return T(x, f'return T.Pot(t, "{mid}").state')
def transfers(x, mid):
    return T(x, f'local out = {{}} for _, p in ipairs(NS.Bets.Transfers(T.Pot(t, "{mid}"))) do out[#out+1] = p.from .. ">" .. p.to .. ":" .. p.copper end return table.concat(out, " ")')

# Ratings before the tournament, all different so the seeding is predictable:
# Anna, Bo, Carl, Dina, Erik.
for x, rating in ((a, 1600), (b, 1560), (c, 1520), (d, 1480), (e, 1440)):
    x.run(f"local me = NS.Data:MyEntry(); me.rating = {rating}; me.rev = me.rev + 1; NS.Sync:SendOwn()")
pump(15)

# --- Creating and joining ----------------------------------------------------------
tid = a.eval('NS.Tournament:Create("Friday Fights")')
check(tid is not None, "Anna hosts a tournament")
pump(10)
tset(tid)
check(all_agree(lambda x: T(x, "return t and t.name"), "tournament name") == "Friday Fights", "everyone has the tournament")
check("is hosting a duel tournament" in b.prints(), "Bo is told about it")
check(any("Sign up in /duels" in m for m in a.eval("CHAT").values()), "Anna's client tells guild chat")
ok, err = b.eval('NS.Tournament:Create("Another")')
check(ok is None and "still going" in err, "only one tournament at a time")

for x in (a, b, c, d, e):
    check(x.eval(f'NS.Tournament:Join("{tid}")') is True, f"{x.name} joins")
    pump(3)
ok, err = b.eval(f'NS.Tournament:Join("{tid}")')
check(ok is None and "already" in err, "can't join twice")
check(b.eval(f'NS.Tournament:Leave("{tid}")') is True, "Bo leaves")
pump(3)
check(b.eval(f'NS.Tournament:Join("{tid}")') is True, "and joins again (at the back of the queue)")
pump(10)
check(all_agree(lambda x: T(x, "return #T.Entrants(t)"), "entrants") == 5, "5 players signed up")
ok, err = b.eval(f'NS.Tournament:Start("{tid}")')
check(ok is None and "Only the host" in err, "only the host can start")

# --- Champion pot (before the start) --------------------------------------------------
check(o.eval(f'NS.Tournament:Bet("{tid}", "W", "{A}", 20 * {G})') is True, "Østen puts 20g on Anna to win it all")
ok, err = d.eval(f'NS.Tournament:Bet("{tid}", "W", "{A}", 5 * {G})')
check(ok is None and "only bet on yourself" in err, "players can only back themselves to win")
check(d.eval(f'NS.Tournament:Bet("{tid}", "W", "{D}", 10 * {G})') is True, "Dina backs herself for 10g")
check(c.eval(f'NS.Tournament:Bet("{tid}", "W", "{C}", 10 * {G})') is True, "Carl backs himself for 10g")
check(b.eval(f'NS.Tournament:Bet("{tid}", "W", "{B}", 10 * {G})') is True, "Bo backs himself for 10g")
ok, err = o.eval(f'NS.Tournament:Bet("{tid}", "W", "{O}", 5 * {G})')
check(ok is None and "in the tournament" in err, "can't back someone who isn't in it")
pump(10)

# The sign-up list in the Tournament tab
text = ui(o)
check("Friday Fights" in text and "sign-ups open: 5 / 16 players" in text, "Tournament tab shows the sign-ups")
check("Champion pot" in text and "20g (1)" in text, "the list shows how much is on each player to win")
# Erik backs himself through the row's Bet button and the popup
ui(e)
e.run(f"""
  local row = FINDWHERE(function(o) local it = rawget(o, "item") return type(it) == "table" and it.key == "{E}" and rawget(o, "button") end)
  CLICK(row.button)
""")
check(e.eval("DuelLadderTourneyBetPopup.title.text") == "Bet on the champion of Friday Fights", "Bet on a row opens the champion popup")
check(e.eval("DuelLadderTourneyBetPopup.backA.key") == E and e.eval("DuelLadderTourneyBetPopup.pick") == E, "backing Erik")
e.run("DuelLadderTourneyBetPopup.money:SetCopper(50000); CLICK(BUTTON_IN(DuelLadderTourneyBetPopup, 'Place bet')); ACCEPT_POPUP()")
check(e.eval(f'NS.Tournament:All()["{tid}"].pots.W.stakes["{E}"].amt') == 50000, "Erik's 5g on himself is in the champion pot")
pump(10)

# Dina and Erik (seeds 4 and 5) fight before the start: that duel mustn't count.
duel("Dina", "Erik")
pump(10)

# --- Start -----------------------------------------------------------------------------
check(a.eval(f'NS.Tournament:Start("{tid}")') is True, "Anna starts it")
pump(10)
seeds = all_agree(lambda x: T(x, "return table.concat(t.seeds, ' ')"), "seeds").split(" ")
check(seeds == [A, B, C, D, E], f"seeded by rating: {[name(k) for k in seeds]}")
s1, s2, s3, s4, s5 = seeds
check(all_agree(lambda x: T(x, "local b = T.Bracket(t) return b.size .. '/' .. b.rounds"), "bracket size") == "8/3", "5 players: bracket of 8, 3 rounds")
check(all_agree(lambda x: T(x, "local n = 0 for _, m in pairs(T.Bracket(t).byId) do if m.bye then n = n + 1 end end return n"), "byes") == 3,
      "3 byes")
check(match(a, "1.1", "bye") and match(a, "1.1", "winner") == s1, "seed 1 gets a bye")
check(match(a, "1.2", "a") == s4 and match(a, "1.2", "b") == s5 and match(a, "1.2", "live"), "seeds 4 and 5 play in round 1")
check(match(a, "1.2", "winner") is None, "their duel from before the start doesn't count")
check(match(a, "2.2", "a") == s2 and match(a, "2.2", "b") == s3 and match(a, "2.2", "live"), "seeds 2 and 3 (both byes) play their semifinal right away")
check(not match(a, "2.1", "live"), "seed 1's semifinal waits for round 1")
check("has started with 5 players" in e.prints() and "You're seed" in e.prints(), "players are told it started and their seed")
check(f"you vs {name(s5)}" in clients[name(s4)].prints(), "seed 4 is told who they play")
ok, err = o.eval(f'NS.Tournament:Bet("{tid}", "W", "{B}", 5 * {G})')
check(ok is None and "closed" in err, "no champion bets after the start")
ok, err = b.eval(f'NS.Tournament:Join("{tid}")')
check(ok is None, "no joining after the start")
check(all_agree(lambda x: pot_state(x, "W"), "champion pot") == "locked", "champion pot is locked")
text = ui(o)
check("Round 1" not in text and "Quarterfinal" in text and "Semifinal" in text and "Final" in text, "bracket shows the rounds")
check("|cff555555bye|r" in text and "Champion" in text, "bracket shows byes and the champion slot")

# --- Round 1: match pot, a casual duel that doesn't count, an upset ---------------------
p4, p5 = clients[name(s4)], clients[name(s5)]
check(o.eval(f'NS.Tournament:Bet("{tid}", "1.2", "{s4}", 10 * {G})') is True, "Østen bets 10g on seed 4")
check(clients[name(s1)].eval(f'NS.Tournament:Bet("{tid}", "1.2", "{s5}", 10 * {G})') is True, "seed 1 bets 10g on seed 5")
ok, err = p4.eval(f'NS.Tournament:Bet("{tid}", "1.2", "{s5}", 10 * {G})')
check(ok is None and "against yourself" in err, "a player can't bet against themselves")
pump(10)
duel(name(s1), name(s5))   # casual: seed 5's semifinal isn't open yet
pump(5)
check(match(a, "1.2", "winner") is None, "a duel against someone else doesn't decide the match")
duel(name(s5), name(s4))
pump(10)
check(all_agree(lambda x: match(x, "1.2", "winner"), "round 1 winner") == s5, "seed 5 wins round 1")
check(all_agree(lambda x: transfers(x, "1.2"), "match pot payments") == f"{O}>{s1}:100000", "match pot: Østen pays seed 1 10g")
ok, err = b.eval(f'NS.Tournament:Bet("{tid}", "1.2", "{s5}", 5 * {G})')
check(ok is None and "closed" in err, "no bets on a decided match")
check(all_agree(lambda x: match(x, "2.1", "live"), "semifinal 1 live") is True, "seed 1 vs seed 5 is on")
check(match(a, "2.1", "winner") is None, "the casual duel between them from earlier doesn't count")

# --- Walkover in the other semifinal ----------------------------------------------------
check(o.eval(f'NS.Tournament:Bet("{tid}", "2.2", "{s3}", 5 * {G})') is True, "Østen bets on the other semifinal")
pump(5)
ok, err = b.eval(f'NS.Tournament:Walkover("{tid}", "2.2", "{s2}")')
check(ok is None and "Only the host" in err, "only the host awards walkovers")
ui(a)
a.run(f"""
  local box = FINDWHERE(function(o) local m = rawget(o, "match") return type(m) == "table" and m.id == "2.2" end)
  CLICK(box, "RightButton")
  for _, item in ipairs(MENU_ITEMS) do if item.func and item.text == "{name(s2)}" then item.func() end end
  ACCEPT_POPUP()
""")
check(T(a, 'return t.wo["2.2"] and t.wo["2.2"].w') == s2, "Anna right-clicks the match and gives seed 2 a walkover")
pump(10)
check(all_agree(lambda x: (match(x, "2.2", "winner"), match(x, "2.2", "walkover")), "walkover") == (s2, True), "seed 2 goes through")
check(all_agree(lambda x: pot_state(x, "2.2"), "walkover pot") == "void", "a walkover voids the match pot")

# --- Semifinal 1: seed 5 knocks out seed 1 ----------------------------------------------
duel(name(s5), name(s1))
pump(10)
check(all_agree(lambda x: match(x, "2.1", "winner"), "semifinal winner") == s5, "seed 5 beats seed 1")
check(p5.badge(name(s5), "ts") == 1, "seed 5 earns Upset for knocking out the top seed")
check(all_agree(lambda x: (match(x, "3.1", "a"), match(x, "3.1", "b")), "finalists") == (s5, s2), "final: seed 5 vs seed 2")

# --- The final: best of three ------------------------------------------------------------
check(c.eval(f'NS.Tournament:Bet("{tid}", "3.1", "{s5}", 8 * {G})') is True, "Carl bets 8g on seed 5 in the final")
check(o.eval(f'NS.Tournament:Bet("{tid}", "3.1", "{s2}", 4 * {G})') is True, "Østen bets 4g on seed 2")
pump(10)
duel(name(s5), name(s2))
pump(10)
check(all_agree(lambda x: (match(x, "3.1", "winner"), match(x, "3.1", "wa"), match(x, "3.1", "wb")), "after game 1") == (None, 1, 0),
      "game 1 to seed 5: 1 - 0, not over")
check(all_agree(lambda x: pot_state(x, "3.1"), "final pot after game 1") == "locked", "final pot locks when game 1 starts")
ok, err = c.eval(f'NS.Tournament:Bet("{tid}", "3.1", "{s2}", 5 * {G})')
check(ok is None and "closed" in err, "no betting at 1 - 0")
duel(name(s2), name(s5))
duel(name(s2), name(s5))
pump(10)
check(all_agree(lambda x: (match(x, "3.1", "winner"), match(x, "3.1", "wa"), match(x, "3.1", "wb")), "final") == (s2, 1, 2),
      "seed 2 comes back to win 2 - 1")
champion = all_agree(lambda x: T(x, "return T.Bracket(t).champion"), "champion")
check(champion == s2, f"{name(s2)} is the champion")
check(all_agree(lambda x: T(x, "return T.Status(t)"), "status") == "finished", "tournament is finished")
check(f"wins Friday Fights" in a.prints(), "everyone is told who won")
chat = "\n".join(clients[name(s2)].eval("CHAT").values())
check("wins the Friday Fights tournament" in chat, "the champion's client announces it in guild chat")
check(clients[name(s2)].badge(name(s2), "tc") == 1 and clients[name(s2)].badge(name(s2), "tf") == 1, "champion gets Champion and Finalist")
check(p5.badge(name(s5), "tf") == 1 and p5.badge(name(s5), "tc") is None, "runner-up gets Finalist only")
fin = all_agree(lambda x: transfers(x, "3.1"), "final pot payments")
check(fin == f"{C}>{O}:80000", f"final pot: Carl pays Østen 8g ({fin})")

champ_tr = all_agree(lambda x: transfers(x, "W"), "champion pot payments")
check(champ_tr == f"{O}>{B}:200000 {C}>{B}:100000 {D}>{B}:100000 {E}>{B}:50000", f"champion pot: Bo backed himself and takes all 45g ({champ_tr})")

# --- Results stick even after the duels scroll out of recent history ----------------
for i in range(12):
    duel(name(s2), name(s5), duration=5)
pump(10)
check(all_agree(lambda x: (T(x, "return T.Bracket(t).champion"), match(x, "3.1", "wa"), match(x, "3.1", "wb")), "after 12 more duels")
      == (s2, 1, 2), "12 later duels between the finalists change nothing")

# --- Paying -------------------------------------------------------------------------------
ui(c)
c.run("CLICK(FINDWHERE(function(o) return rawget(o, 'fn') and rawget(o, 'text') == 'Bets' end)); ADVANCE(1)")
text = c.eval("ALLTEXT()")
check("You owe" in text and "To pay" in text, "Carl's Bets view lists what he owes")
c.run("MailFrame:Show()")
c.run("""
  local row = FINDWHERE(function(o) local it = rawget(o, "item") return type(it) == "table" and it.action == "Pay" and it.view.mid == "3.1" and rawget(o, "button") end)
  CLICK(row.button)
""")
check(c.eval("SendMailNameEditBox.text") == "Østen" and c.eval("MAIL_COPPER") == 80000, "Pay fills in a mail to Østen for 8g")
check(c.eval("SendMailSubjectEditBox.text") == "DuelLadder tournament bet", "with a tournament subject")
ok, err = c.eval(f'NS.Tournament:MarkPaid("{tid}", "3.1", "{C}")')
check(ok is None, "you can't confirm your own payment")
check(o.eval(f'NS.Tournament:MarkPaid("{tid}", "3.1", "{C}")') is True, "Østen confirms")
pump(10)
check(all_agree(lambda x: pot_state(x, "3.1"), "final pot state") == "paid", "final pot is paid everywhere")

# --- A latecomer gets the whole tournament ---------------------------------------------
sent_log.clear()
late = login("Annalt", "MAGE", 20)
pump(60)
late.run(f'TID = "{tid}"')
check(T(late, "return t and T.Bracket(t).champion") == s2, "a character logging in later sees the same champion")
check(T(late, "return T.Serialize(t)") == T(a, "return T.Serialize(t)"), "and exactly the same tournament")
lens = [len(t.encode("utf-8")) for _, t in sent_log]
check(max(lens) <= 255, f"no addon message over 255 bytes (max {max(lens)})")

# --- Wire format round-trips --------------------------------------------------------
check(T(a, "return T.Serialize(T.Deserialize(T.Serialize(t))) == T.Serialize(t)"), "serialize -> deserialize -> serialize is stable")
check(a.eval('NS.Tournament.Deserialize("garbage") == nil'), "garbage is rejected")

# --- A new one can start once the old one is finished ----------------------------------
ui(b)
b.run("CLICK(BUTTON_IN(NS.UI.frame, 'New tournament')); ACCEPT_POPUP()")
tid2 = b.eval('NS.Tournament:Latest().id')
check(tid2 != tid, "a new tournament can be hosted from the tab once the last one is over")
check(b.eval(f'NS.Tournament:All()["{tid2}"].name') == "Bo's Tournament", "an empty name becomes 'Bo's Tournament'")
check(b.eval(f'NS.Tournament:Cancel("{tid2}")') is True, "the host can cancel")
pump(10)
check(a.eval(f'NS.Tournament.Status(NS.Tournament:All()["{tid2}"])') == "cancelled", "everyone sees it cancelled")

print(f"\n{failures} failure(s)")
sys.exit(1 if failures else 0)

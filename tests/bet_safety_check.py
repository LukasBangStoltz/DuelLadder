"""Betting safety: no promising more gold than you have, expired pots stay void, old pots
can't swallow new ones, late bets don't undo payments, and copies of a pool converge."""
import os
HERE = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(HERE, "sim.py"), encoding="utf-8").read().split("# --- 1. Login and sync")[0])

A, B, C, D, E = K("Anna"), K("Bo"), K("Carl"), K("Dina"), K("Erik")
G, DAY = 10000, 86400
a = login("Anna", "WARRIOR", 70)
b = login("Bo", "MAGE", 70)
c = login("Carl", "WARRIOR", 70)
d = login("Dina", "PRIEST", 70)
pump(30)

def transfers(x, pid):
    return x.eval(f'(function() local p = NS.Bets:All()["{pid}"]; if not p then return "(none)" end local out = {{}} for _, t in ipairs(NS.Bets.Transfers(p)) do out[#out+1] = t.from .. ">" .. t.to .. ":" .. t.copper .. (t.paid and "(paid)" or "") end return table.concat(out, " ") end)()')
def available(x): return x.eval("NS.Bets:Available()")
def days(n):
    for x in online():
        x.run(f"NOW = NOW + {n * DAY}")
    pump(2)

# 1. You can't promise more gold than you have ------------------------------------------
c.run(f"MONEY = 100 * {G}")
pid = c.eval(f'NS.Bets:Place("{A}", "{B}", "{A}", 60 * {G})')
check(pid is not None and available(c) == 40 * G, "Carl has 100g and bets 60g: 40g left to bet")
ok, err = c.eval(f'NS.Bets:Place("{A}", "{D}", "{A}", 50 * {G})')
check(ok is None and "40g free" in err and "60g" in err, f"a 50g bet on another duel is refused ({err})")
ok, err = c.eval(f'NS.Bets:Challenge("{D}", 50 * {G})')
check(ok is None and "free to bet" in err, "so is a 50g challenge")
cid = c.eval(f'NS.Bets:Challenge("{B}", 40 * {G})')
check(cid is not None and available(c) == 0, "a 40g challenge fits exactly")
pump(8)
did = d.eval(f'NS.Bets:Challenge("{C}", 10 * {G})')
pump(8)
ok, err = c.eval(f'NS.Bets:Accept("{did}")')
check(ok is None and "can't match" in err, "Carl can't accept a 10g challenge with nothing free")
check(c.eval(f'NS.Bets:Cancel("{cid}")') is True and available(c) == 40 * G, "cancelling the 40g challenge frees it again")
check(c.eval(f'NS.Bets:Accept("{did}")') == did and available(c) == 30 * G, "now he can accept: 30g left")
pump(8)

# The bet popup warns before you even press the button
c.run(f'NS.UI:Toggle(); NS.UI:OpenBetPopup("{A}", "{D}")')
c.run(f'DuelLadderBetPopup.money:SetCopper(50 * {G}); DuelLadderBetPopup.money.gold.scripts.OnTextChanged()')
check("free to bet" in c.eval("DuelLadderBetPopup.preview.text"), "the bet popup says 50g is more than Carl has free")
check("No bets" in c.eval("DuelLadderBetPopup.pot.text"), "popup: nobody has bet on Anna vs Dina yet")
b.eval(f'NS.Bets:Place("{A}", "{D}", "{A}", 5 * {G})')
pump(8)
check("Pot:" in c.eval("DuelLadderBetPopup.pot.text"), "Bo bets while Carl's popup is open: the pot updates")
c.run("DuelLadderBetPopup:Hide()")

# Debts count too: Carl loses the challenge and owes Dina 10g until she confirms
duel("Dina", "Carl")
check(available(c) == 30 * G, "after losing, the 10g he owes still isn't free (30g)")
check(d.eval(f'NS.Bets:MarkPaid("{did}", "{C}")') is True, "Dina confirms Carl paid")
pump(8)
check(available(c) == 40 * G, "once paid, only the 60g bet is still tied up")
check(c.eval(f'NS.Bets:Cancel("{pid}")') is True, "Carl cancels his 60g bet")
pump(8)

# 2. A pot with no duel for a week stays void, even if they fight later ---------------
xid = a.eval(f'NS.Bets:Place("{B}", "{C}", "{C}", 20 * {G})')
pump(8)
d.eval(f'NS.Bets:Place("{B}", "{C}", "{B}", 20 * {G})')
pump(8)
days(8)
check(all_agree(lambda x: x.bet_state(xid), "state after 8 days") == "expired", "no duel in a week: the pot expires")
duel("Carl", "Bo")
check(all_agree(lambda x: x.bet_state(xid), "state after a late duel") == "expired", "a duel on day 8 doesn't decide it")
check(transfers(d, xid) == "", "and nobody owes anything")

# A copy from an older version that did decide it is cleaned up
bad = a.eval(f'''(function()
  local p = NS.Bets.Deserialize(NS.Bets.Serialize(NS.Bets:All()["{xid}"]))
  p.res, p.rs = "{C}", p.t + 8 * {DAY}
  local back = NS.Bets.Deserialize(NS.Bets.Serialize(p))
  return tostring(back.res)
end)()''')
check(bad == "nil", "a result from a duel after the pot expired is dropped when received")

# 3. An old expired pot can't swallow a fresh one ----------------------------------------
old = b.eval(f'NS.Bets:Place("{A}", "{C}", "{A}", 30 * {G})')
pump(8)
days(8)
e = login("Erik", "ROGUE", 70)           # a new install: knows no pots yet
pump(3.2)                                # guild is loaded and the sync request is out, no answers yet
new = e.eval(f'NS.Bets:Place("{A}", "{C}", "{C}", 5 * {G})')
pump(40)
check(all_agree(lambda x: (x.bet_state(old), x.bet_state(new)), "states") == ("expired", "open"),
      "Erik's new pot stays open and the old one stays expired, on every client")
check(e.eval(f'(function() local p = NS.Bets:OpenPool("{A}", "{C}") return p and p.id end)()') == new, "Erik still finds his pot")
d.eval(f'NS.Bets:Place("{A}", "{C}", "{A}", 5 * {G})')
pump(8)
duel("Carl", "Anna")
check(all_agree(lambda x: (transfers(x, old), transfers(x, new)), "payments") == ("", f"{D}>{E}:50000"),
      "only the new pot pays out: Dina owes Erik 5g once")

# 4. A bet that turns up late doesn't undo payments already made -----------------------
pid = c.eval(f'NS.Bets:Place("{B}", "{D}", "{B}", 20 * {G})')
pump(8)
a.eval(f'NS.Bets:Place("{B}", "{D}", "{D}", 20 * {G})')
pump(8)
check(e.eval(f'NS.Bets:Place("{B}", "{D}", "{B}", 20 * {G})') == pid, "Erik bets on Bo too...")
e.run("OUT = {}")                        # ...but his message never goes out
e_db = logout("Erik")
pump(5)
duel("Bo", "Dina")
check(all_agree(lambda x: transfers(x, pid), "payments") == f"{A}>{C}:200000", "without Erik's bet: Anna pays Carl 20g")
check(c.eval(f'NS.Bets:MarkPaid("{pid}", "{A}")') is True, "Carl confirms Anna paid")
pump(8)
check(all_agree(lambda x: x.bet_state(pid), "state") == "paid", "fully paid")

# Payments confirmed by DuelLadder 0.4 (no amount) still count
legacy = c.eval(f'''(function()
  local s = NS.Bets.Serialize(NS.Bets:All()["{pid}"])
  s = s:gsub(";[^;]*$", ";{A}>{C}")    -- paid field as 0.4 wrote it
  local p = NS.Bets.Deserialize(s)
  return p.paid["{A}>{C}"]
end)()''')
check(legacy == 200000, f"a 0.4-style 'paid' entry is read as the 20g it was ({legacy})")
paid_field = c.eval(f'NS.Bets.Serialize(NS.Bets:All()["{pid}"])').split(";")[-1].split(",")
check(f"{A}>{C}" in paid_field and f"{A}>{C}=200000" in paid_field,
      f"payments are also sent the 0.4 way, so older versions see them as paid ({paid_field})")

e = login("Erik", "ROGUE", 70, e_db)     # Erik comes back with his bet
pump(40)
tr = all_agree(lambda x: transfers(x, pid), "payments after Erik's bet arrives")
check(tr == f"{A}>{C}:200000(paid) {C}>{E}:100000", f"Anna's payment still counts; Carl passes 10g on to Erik ({tr})")
check(all_agree(lambda x: x.bet_state(pid), "state") == "settled", "the pot is open for payment again")

# 5. Copies of a pool converge, whatever order things arrive in -----------------------
conv = a.eval(f'''(function()
  local base = {{ id = "X#1#1", a = "{A}", b = "{B}", t = 100, by = "{A}", stakes = {{}}, paid = {{}}, v = 2 }}
  local function copy(extra)
    local p = NS.Bets.Deserialize(NS.Bets.Serialize(base))
    for k, s in pairs(extra) do p.stakes[k] = s end
    return p
  end
  local x = copy({{ ["{C}"] = {{ side = "{A}", amt = 500, t = 110 }} }})
  local y = copy({{ ["{C}"] = {{ side = "{B}", amt = 900, t = 105 }}, ["{D}"] = {{ side = "{A}", amt = 100, t = 120, cancel = 130 }} }})
  x.res, x.rs, y.res, y.rs = "{A}", 200, "{B}", 200
  local x2 = NS.Bets.Deserialize(NS.Bets.Serialize(x))
  local y2 = NS.Bets.Deserialize(NS.Bets.Serialize(y))
  NS.Bets:All()["X#1#1"] = x  NS.Bets:Merge(y2)
  local one = NS.Bets.Serialize(NS.Bets:All()["X#1#1"])
  NS.Bets:All()["X#1#1"] = y  NS.Bets:Merge(x2)
  local two = NS.Bets.Serialize(NS.Bets:All()["X#1#1"])
  NS.Bets:All()["X#1#1"] = nil
  return tostring(one == two)
end)()''')
check(conv == "true", "merging two different copies gives the same pool in either order")

# 6. Old finished pools stay forgotten ----------------------------------------------------
days(31)
for x in online():
    x.run('NS.Bets:Prune()')
check(all(x.bet_state(old) is None for x in online()), "old expired pots are pruned")
check(all(x.eval('next(NS.Data.guild.poolAlias)') is None for x in online()), "and redirects to pruned pots are gone")
back = a.eval(f'''(function()
  local p = {{ id = "{old}", a = "{A}", b = "{C}", t = NOW - 40 * {DAY}, by = "{B}", stakes = {{}}, paid = {{}}, v = 2 }}
  return tostring(NS.Bets:Merge(p)) .. "/" .. tostring(NS.Bets:All()["{old}"] ~= nil)
end)()''')
check(back == "false/false", "a pruned pot sent by someone who hasn't pruned yet isn't taken back")

# 7. A decided pot is sent once or twice, not by every client ----------------------------
sent_log.clear()
qid = a.eval(f'NS.Bets:Place("{C}", "{D}", "{C}", 10 * {G})')
pump(8)
b.eval(f'NS.Bets:Place("{C}", "{D}", "{D}", 10 * {G})')
pump(8)
sent_log.clear()
duel("Carl", "Dina")
pump(10)
senders = {name for name, text in sent_log if text.startswith("P^" + qid + "^")}
check(all_agree(lambda x: x.bet_state(qid), "state") == "settled", "the pot is decided everywhere")
check(len(senders) <= 2, f"at most two clients sent the decided pot, not all {len(online())} ({sorted(senders)})")

print(f"\n{failures} failure(s)")

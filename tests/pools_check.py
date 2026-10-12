import os, random
HERE = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(HERE, "sim.py"), encoding="utf-8").read().split("# --- 1. Login and sync")[0])

A, B, C, D = K("Anna"), K("Bo"), K("Carl"), K("Dina")
a = login("Anna", "WARRIOR", 70)
b = login("Bo", "MAGE", 70)
c = login("Carl", "WARRIOR", 70)
d = login("Dina", "PRIEST", 70)
pump(30)

def transfers(x, pid):
    return x.eval(f'(function() local out = {{}} for _, t in ipairs(NS.Bets.Transfers(NS.Bets:All()["{pid}"])) do out[#out+1] = t.from .. ">" .. t.to .. ":" .. t.copper end return table.concat(out, " ") end)()')

# 1. Cancelling DURING the fight doesn't count; betting during the fight doesn't either
pid = c.eval(f'NS.Bets:Place("{A}", "{B}", "{A}", 200000)')
d.eval(f'NS.Bets:Place("{A}", "{B}", "{B}", 200000)')
pump(8)
check(all_agree(lambda x: x.eval("BETCOUNT()"), "pot count") == 1, "Carl and Dina opened pots at the same moment: they merge into one")
check(all_agree(lambda x: x.eval(f'(function() local ta, ca, tb, cb = NS.Bets.Pot(NS.Bets:All()["{pid}"]) return ta .. "/" .. tb end)()'), "pot") == "200000/200000", "merged pot has both bets")
for x in (a, b):
    x.L.globals().FIRE("PLAYER_REGEN_DISABLED")      # the duel starts
pump(10)
check(d.eval(f'NS.Bets:Cancel("{pid}")') is True, "Dina hits cancel mid-fight (the addon can't know yet)")
a.eval(f'NS.Bets:Place("{A}", "{B}", "{A}", 500000)')     # Anna bets on herself mid-fight
pump(10)
for x in (a, b):
    x.run("HEALTH = 50")
    x.L.globals().FIRE("CHAT_MSG_SYSTEM", "Anna has defeated Bo in a duel")
pump(10)
tr = all_agree(lambda x: transfers(x, pid), "payments")
check(tr == f"{D}>{C}:200000", f"Dina's mid-fight cancel doesn't count: she still pays Carl 20g, and Anna's mid-fight bet is ignored ({tr})")

# 2. Cancelling BEFORE the fight counts
pid2 = c.eval(f'NS.Bets:Place("{A}", "{B}", "{A}", 300000)')
d.eval(f'NS.Bets:Place("{A}", "{B}", "{B}", 300000)')
pump(8)
check(pid2 != pid, "a new pot opens for the next duel after one is decided")
check(d.eval(f'NS.Bets:Cancel("{pid2}")') is True, "Dina cancels before the duel")
pump(8)
duel("Anna", "Bo")
check(all_agree(lambda x: x.bet_state(pid2), "state") == "void", "with Dina out, nobody's on Bo: the pot is void")
check(transfers(c, pid2) == "", "nobody owes anything")
check("Nobody took the other side" in c.prints(), "Carl is told why")

# 3. Can't cancel after the result is in
ok, err = c.eval(f'NS.Bets:Cancel("{pid}")')
check(ok is False and "already happened" in err, "can't cancel once the duel is decided")

# 4. A pot opened mid-fight is decided by the NEXT duel, not the one already running
for x in (c, d):
    x.L.globals().FIRE("PLAYER_REGEN_DISABLED")
pump(5)
pid3 = a.eval(f'NS.Bets:Place("{C}", "{D}", "{C}", 100000)')
b.eval(f'NS.Bets:Place("{C}", "{D}", "{D}", 100000)')
pump(10)
for x in (c, d):
    x.run("HEALTH = 50")
    x.L.globals().FIRE("CHAT_MSG_SYSTEM", "Carl has defeated Dina in a duel")
pump(10)
check(all_agree(lambda x: x.bet_state(pid3), "state") == "open", "the duel that was already running doesn't decide a pot opened during it")
duel("Dina", "Carl")
check(all_agree(lambda x: transfers(x, pid3), "payments") == f"{A}>{B}:100000", "the next duel does: Dina wins, Anna pays Bo 10g")

# 5. Rounding: payouts always add up exactly, and match on every client
random.seed(7)
pure = a.L  # use Anna's Lua state for pure math
ok_all = True
for trial in range(200):
    n = random.randint(2, 8)
    stakes = []
    for i in range(n):
        side = "A" if i == 0 else ("B" if i == 1 else random.choice("AB"))
        stakes.append(f'["P{i}-R"] = {{ side = "{side}", amt = {random.randint(1, 500)}, t = 1 }}')
    res = random.choice("AB")
    lua = f'''(function()
      local pool = {{ a = "A", b = "B", t = 0, res = "{res}", rs = 10, paid = {{}}, stakes = {{ {", ".join(stakes)} }} }}
      local net = NS.Bets.Payouts(pool)
      local sum, paid_in, got = 0, 0, 0
      for k, v in pairs(net) do sum = sum + v end
      for _, t in ipairs(NS.Bets.Transfers(pool)) do paid_in = paid_in + t.copper end
      for k, v in pairs(net) do if v > 0 then got = got + v end end
      return sum == 0 and paid_in == got
    end)()'''
    if not pure.eval(lua):
        ok_all = False
        break
check(ok_all, "200 random pots: winnings exactly equal losses, and the payments add up")

# 6. Old 0.2 bets are converted, payment state kept
old = '''{ settings = {}, myChars = {}, guilds = { ["Spineshatter/Fun Times"] = { entries = {}, betSeen = {}, bets = {
  ["Anna-Spineshatter#1700000500#1"] = { id = "Anna-Spineshatter#1700000500#1", by = "Anna-Spineshatter", a = "Anna-Spineshatter", b = "Bo-Spineshatter",
     pick = "Anna-Spineshatter", amt = 25, t = 1700000500, only = "Bo-Spineshatter", taker = "Bo-Spineshatter", tt = 1700000600,
     res = "Anna-Spineshatter", rt = 1700000700, paid = true },
  ["Anna-Spineshatter#1700000800#2"] = { id = "Anna-Spineshatter#1700000800#2", by = "Anna-Spineshatter", a = "Carl-Spineshatter", b = "Dina-Spineshatter",
     pick = "Carl-Spineshatter", amt = 5, t = 1700000800, taker = "Bo-Spineshatter", tt = 1700000900,
     res = "Dina-Spineshatter", rt = 1700001000 } } } } }'''
m = Client("Anna", "WARRIOR", 70, old, now=a.eval("NOW"))
m.run("ADVANCE(5)")
check(m.eval('DuelLadderDB.guilds["Spineshatter/Fun Times"].bets') is None, "old bets list is gone after converting")
check(m.eval('NS.Bets.State(NS.Bets:All()["Anna-Spineshatter#1700000500#1"])') == "paid", "a paid old bet stays paid")
check(transfers(m, "Anna-Spineshatter#1700000800#2") == f"{A}>{B}:50000", "an unpaid old bet becomes 'Anna pays Bo 5g'")
check(m.eval('NS.Bets:All()["Anna-Spineshatter#1700000500#1"].challenge') == B, "old challenges stay challenges")

print(f"\n{failures} failure(s)")

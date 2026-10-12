import os
HERE = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(HERE, "sim.py"), encoding="utf-8").read().split("# --- 1. Login and sync")[0])

A, B, C, D = K("Anna"), K("Bo"), K("Carl"), K("Dina")
G, S = 10000, 100
a = login("Anna", "WARRIOR", 70)
b = login("Bo", "MAGE", 70)
c = login("Carl", "WARRIOR", 70)
pump(30)

def transfers(x, pid):
    return x.eval(f'(function() local out = {{}} for _, t in ipairs(NS.Bets.Transfers(NS.Bets:All()["{pid}"])) do out[#out+1] = t.from .. ">" .. t.to .. ":" .. t.copper end return table.concat(out, " ") end)()')
def stake(x, pid, who, field="amt"):
    return x.eval(f'(function() local s = NS.Bets:All()["{pid}"].stakes["{who}"]; return s and s.{field} end)()')

# 1. Challenge with silver: 2g 50s, accepted, decided
cid = a.eval(f'NS.Bets:Challenge("{B}", 2 * {G} + 50 * {S})')
pump(8)
check("2g 50s" in b.prints(), "Bo is told the challenge is for 2g 50s")
check(b.eval(f'NS.Bets:Accept("{cid}")') == cid, "Bo accepts")
pump(8)
check(stake(a, cid, B) == 25000, "Anna sees Bo matched 2g 50s")
check("accepted your challenge" in a.prints(), "Anna is told Bo accepted")
duel("Anna", "Bo")
check(all_agree(lambda x: transfers(x, cid), "payments") == f"{B}>{A}:25000", "Bo pays Anna 2g 50s")

# 2. Decline
did = a.eval(f'NS.Bets:Challenge("{C}", 5 * {G})')
pump(8)
check(c.eval(f'NS.Bets:Decline("{did}")') is True, "Carl declines")
pump(8)
check("declined your challenge" in a.prints(), "Anna is told Carl declined")
check(a.eval(f'NS.Bets.Declined(NS.Bets:All()["{did}"])') is True, "everyone sees it as declined")
ok, err = c.eval(f'NS.Bets:Accept("{did}")')
check(ok is None and "already answered" in err, "can't accept after declining")
check(a.eval(f'NS.Bets:Cancel("{did}")') is True, "Anna cancels the declined challenge")
duel("Anna", "Carl")
check(all_agree(lambda x: x.bet_state(did), "state") == "void", "nobody owes anything")

# 3. Challenger cancels before the duel
xid = b.eval(f'NS.Bets:Challenge("{C}", 1 * {G})')
pump(8)
check(b.eval(f'NS.Bets:Cancel("{xid}")') is True, "Bo cancels his challenge")
pump(8)
ok, err = c.eval(f'NS.Bets:Accept("{xid}")')
check(ok is None and "cancelled" in err, "Carl can't accept a cancelled challenge")
check(b.eval(f'NS.Bets:Challenge("{C}", 3 * {G})') is not None, "Bo can challenge Carl again after cancelling")

# 4. Challenged player accepts, then backs out before the duel
yid = c.eval(f'NS.Bets:Challenge("{A}", 4 * {G})')
pump(8)
a.eval(f'NS.Bets:Accept("{yid}")')
pump(8)
check(a.eval(f'NS.Bets:Cancel("{yid}")') is True, "Anna withdraws her acceptance before the duel")
pump(8)
duel("Carl", "Anna")
check(all_agree(lambda x: x.bet_state(yid), "state") == "void", "withdrawn acceptance: nobody owes anything")

# 5. Spectators can't bet in a challenge, only in the public pot
zid = a.eval(f'NS.Bets:Challenge("{B}", 1 * {G})')
pump(8)
pid = c.eval(f'NS.Bets:Place("{A}", "{B}", "{A}", 75 * {S})')
check(pid != zid and c.eval(f'NS.Bets:All()["{zid}"].stakes["{C}"]') is None, "Carl's 75s goes to the public pot, not the challenge")
pump(8)
check(a.eval("BETCOUNT()") == b.eval("BETCOUNT()") == c.eval("BETCOUNT()"), "the challenge and the pot don't merge")

# 6. Silver limits
ok, err = c.eval(f'NS.Bets:Place("{B}", "{D}", "{B}", 50)')
check(ok is None and "between" in err, "less than 1 silver is refused")

# 7. Money box: gold + silver in, copper out
c.run("NS.UI:Toggle(); NS.UI:ShowTab('Members')")
box = c.eval("(function() local f = UI_TEST_BOX or nil return f end)()")
copper = c.eval('''(function()
  local box = NS.UI.MoneyBox(UIParent)
  box.gold:SetText("12"); box.silver:SetText("34")
  local a = box:GetCopper()
  box:SetCopper(5 * 10000 + 7 * 100 + 99)
  return a .. " " .. box.gold:GetText() .. " " .. box.silver:GetText()
end)()''')
check(copper == "123400 5 7", f"12g 34s -> 123400 copper, and 5g 7s 99c shows as 5g 7s ({copper})")

# 8. A pool sent by a 0.3.0 client (whole gold) is read as gold
old_msg = f"1;Bo-Spineshatter#1700009999#9;{A};{C};1700009999;{B};;;0;{B}=A:3:1700009999:0;"
c.eval(f'(function() NS.Bets:Merge(NS.Bets.Deserialize("{old_msg}")) end)()')
check(stake(c, "Bo-Spineshatter#1700009999#9", B) == 30000, "an old 3-gold bet becomes 30000 copper")

print(f"\n{failures} failure(s)")

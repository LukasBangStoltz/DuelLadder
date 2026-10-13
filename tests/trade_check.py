import os
HERE = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(HERE, "sim.py"), encoding="utf-8").read().split("# --- 1. Login and sync")[0])

a = login("Anna", "WARRIOR", 70)
b = login("Bo", "MAGE", 70)
pump(20)
cid = a.eval('NS.Bets:Challenge("Bo-Spineshatter", 100000)')
pump(8)
check(b.eval(f'NS.Bets:Accept("{cid}")') == cid, "Bo accepts Anna's 10g challenge")
pump(8)
duel("Anna", "Bo")
check(b.bet_state(cid) == "settled" and b.eval("select(3, NS.Bets:Balance())") == 100000, "Bo lost and owes Anna 10g")

def last_print(c): return c.eval("PRINTS[#PRINTS]")
def pay(): b.eval(f'NS.Bets:Pay("{cid}", "Anna-Spineshatter")')

# 1. Can't see Anna
pay()
check("Can't see Anna" in last_print(b) and b.eval("#TRADES_OPENED") == 0, "no unit for Anna -> asks you to target her")

# 2. Targeted but too far
b.run('UNITS.target = { "Anna", "" }; IN_RANGE = false')
pay()
check("too far away" in last_print(b) and b.eval("#TRADES_OPENED") == 0, "out of range -> says get closer, no trade")

# 3. In range: opens trade with the target, fills gold when the window shows
b.run('IN_RANGE = true')
pay()
check(b.eval("TRADES_OPENED[1]") == "target", "in range -> opens a trade with the target")
b.run('UNITS.NPC = { "Anna", "" }; TradeFrame:Show(); FIRE("TRADE_SHOW"); ADVANCE(1)')
check(b.eval("TRADE_COPPER") == 100000, "10g filled into the trade window")
check("click Trade" in last_print(b), "tells Bo to check it and click Trade")

# 4. Trade already open with Anna: fills right away, no new trade
b.run('TRADE_COPPER = nil; TRADES_OPENED = {}')
pay()
check(b.eval("TRADE_COPPER") == 100000 and b.eval("#TRADES_OPENED") == 0, "trade already open with Anna -> fills gold immediately")

# 5. Trade window opens with someone else after Pay: don't put gold in
b.run('TradeFrame:Hide(); UNITS.NPC = nil; TRADE_COPPER = nil; TRADES_OPENED = {}')
pay()
b.run('UNITS.NPC = { "Carl", "" }; TradeFrame:Show(); FIRE("TRADE_SHOW"); ADVANCE(1)')
check(b.eval("TRADE_COPPER") is None, "a trade with someone else doesn't get Anna's gold")

# 6. Found through the party instead of target
b.run('TradeFrame:Hide(); UNITS.NPC = nil; UNITS.target = nil; UNITS.party2 = { "Anna", "" }; TRADES_OPENED = {}')
pay()
check(b.eval("TRADES_OPENED[1]") == "party2", "finds Anna as a party member without targeting")

# 7. Mailbox open still works (and wins over opening a trade)
b.run('UNITS.party2 = nil; MailFrame:Show(); TRADES_OPENED = {}')
pay()
check(b.eval("MAIL_COPPER") == 100000 and b.eval("#TRADES_OPENED") == 0, "at a mailbox -> fills in a mail instead")

# 8. Winner can't 'pay' themselves
a.run('UNITS.target = { "Bo", "" }')
a.eval(f'NS.Bets:Pay("{cid}", "Bo-Spineshatter")')
check(a.eval("#TRADES_OPENED") == 0, "the winner's Pay does nothing")


# 9. Gold actually lands in the trade, both when the box passes it on and when it doesn't
for propagates in (True, False):
    b.run(f"""MailFrame:Hide(); TradeFrame:Hide(); UNITS = {{ target = {{ "Anna", "" }} }}; TRADE_MONEY = 0; SET_TRADE_CALLS = 0; TRADES_OPENED = {{}}; BOX_PROPAGATES = {'true' if propagates else 'false'}""")
    pay()
    b.run('UNITS.NPC = { "Anna", "" }; TradeFrame:Show(); FIRE("TRADE_SHOW"); ADVANCE(2)')
    check(b.eval("TRADE_MONEY") == 100000 and b.eval("SET_TRADE_CALLS") == (0 if propagates else 1),
          f"10g is in the trade ({'box passes it on' if propagates else 'fallback sets it directly'})")

# 10. Not enough gold: warned, still filled in
b.run('MONEY = 5 * 10000; TradeFrame:Hide(); UNITS.NPC = nil; TRADE_MONEY = 0; BOX_PROPAGATES = true')
pay()
b.run('UNITS.NPC = { "Anna", "" }; TradeFrame:Show(); FIRE("TRADE_SHOW"); ADVANCE(2)')
check("You only have" in b.prints() and b.eval("TRADE_MONEY") == 100000, "warns when you can't afford it, still fills in the amount")

# 11. TRADE_SHOW arrives before the trade window is shown: still filled in
b.run('MONEY = 1000 * 10000; TradeFrame:Hide(); UNITS.NPC = nil; TRADE_MONEY = 0')
pay()
b.run('UNITS.NPC = { "Anna", "" }; FIRE("TRADE_SHOW"); TradeFrame:Show(); ADVANCE(2)')
check(b.eval("TRADE_MONEY") == 100000, "the gold is filled in even if the window shows just after the event")

# 12. A trade with someone else first doesn't use up the payment
b.run('TradeFrame:Hide(); UNITS.NPC = nil; TRADE_MONEY = 0')
pay()
b.run('UNITS.NPC = { "Carl", "" }; TradeFrame:Show(); FIRE("TRADE_SHOW"); ADVANCE(1); TradeFrame:Hide()')
b.run('UNITS.NPC = { "Anna", "" }; TradeFrame:Show(); FIRE("TRADE_SHOW"); ADVANCE(1)')
check(b.eval("TRADE_MONEY") == 100000, "Carl trades first, then Anna's trade opens: her gold is still filled in")

# 13. Never accepts the trade for you
check(b.eval("ACCEPTED") == 0 and a.eval("ACCEPTED") == 0, "the addon never clicks Trade")

print(f"\n{failures} failure(s)")

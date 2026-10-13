import os
HERE = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(HERE, "sim.py"), encoding="utf-8").read().split("# --- 1. Login and sync")[0])

# Anna's SavedVariables from 0.1: 3 wins, 6 fled... no badges at all
old_db = '''{ settings = {}, myChars = {}, guilds = { ["Spineshatter/Fun Times"] = { entries = {
  ["Anna-Spineshatter"] = { rev = 9, class = "WARRIOR", level = 70, w = 3, l = 2, fled = 5, streak = 1, best = 6, last = 0, h2h = {} } } } } }'''
a = login("Anna", "WARRIOR", 70, old_db)
b = login("Bo", "MAGE", 70)
pump(15)
check(a.badge("Anna", "fb") == 1, "First Blood awarded at login for wins from before badges existed")
check(a.badge("Anna", "s5") == 1 and a.badge("Anna", "s10") is None, "Rampage caught up from best streak 6 (Unstoppable not)")
check(a.badge("Anna", "ch") == 1, "Chicken caught up from 5 flees")
check("Badge earned" in a.prints() and "First Blood" in a.prints(), "Anna is told about the caught-up badges")
check(b.badge("Anna", "fb") == 1, "Bo sees Anna's caught-up badges")

duel("Anna", "Bo")
check(a.badge("Anna", "fb") == 1, "another win doesn't give First Blood twice")

# Lose first, then win: First Blood on the first win
duel("Anna", "Bo")  # warm up (Bo stays at 0 wins)
check(b.badge("Bo", "fb") is None, "Bo has no First Blood after only losses")
duel("Bo", "Anna")
check(b.badge("Bo", "fb") == 1, "Bo's first win after 3 losses gives First Blood")

# Duel length only counts combat that belongs to the duel
for x in (a, b):
    x.L.globals().FIRE("PLAYER_REGEN_DISABLED")      # a mob fight...
pump(10)
for x in (a, b):
    x.L.globals().FIRE("PLAYER_REGEN_ENABLED")       # ...that ended
pump(200)
for x in (a, b):
    x.L.globals().FIRE("CHAT_MSG_SYSTEM", "Bo has fled from Anna in a duel")  # fled in the countdown
pump(8)
check(a.badge("Anna", "ma") is None and b.badge("Bo", "ma") is None, "an old mob fight doesn't make an instant flee a Marathon")
check(a.eval('NS.Data:MyEntry().recent[1].du') is None, "that duel's length is unknown, not 210 seconds")
for x in (a, b):
    x.L.globals().FIRE("PLAYER_REGEN_DISABLED")      # a real duel...
pump(125)
for x in (a, b):
    x.L.globals().FIRE("PLAYER_REGEN_ENABLED")       # ...where combat drops just before it ends
pump(5)
for x in (a, b):
    x.L.globals().FIRE("CHAT_MSG_SYSTEM", "Anna has defeated Bo in a duel")
pump(8)
check(a.badge("Anna", "ma") == 1, "a real 2-minute duel is still a Marathon")

# Relogging doesn't award again
db = logout("Anna")
a = login("Anna", "WARRIOR", 70, db)
pump(15)
check(a.badge("Anna", "fb") == 1 and a.badge("Anna", "s5") == 1, "relogging doesn't award catch-up badges twice")

# Ratings survive a relog
rating = a.stat("Anna", "rating")
db = logout("Anna")
a = login("Anna", "WARRIOR", 70, db)
pump(15)
check(a.stat("Anna", "rating") == rating, "relogging doesn't change Anna's rating")
print(f"\n{failures} failure(s)")

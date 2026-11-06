"""Checks for Midnight-style clients (WoW Forever, Retail): addon messages blocked in lockdown are
sent later instead of lost, secret chat text is ignored, and the .toc lists Forever."""
import os, re
HERE = os.path.dirname(os.path.abspath(__file__))
exec(open(os.path.join(HERE, "sim.py"), encoding="utf-8").read().split("# --- 1. Login and sync")[0])

toc = open(os.path.join(ADDON, "DuelLadder.toc"), encoding="utf-8").read()
interfaces = re.search(r"^## Interface:(.*)$", toc, re.M).group(1).replace(" ", "").split(",")
check("16001" in interfaces, f"the .toc lists WoW Forever (16001): {interfaces}")

a = login("Anna", "WARRIOR", 70)
b = login("Bo", "MAGE", 70)
c = login("Carl", "WARRIOR", 70)
pump(30)

# 1. The client reports a messaging lockdown (boss fight, Mythic+, rated PvP).
a.run("LOCKDOWN = true; C_ChatInfo.InChatMessagingLockdown = function() return LOCKDOWN end")
duel("Anna", "Bo")
check(a.stat("Anna", "rating") == 1520, "Anna records her win during the lockdown")
check(c.stat("Anna", "rating") == 1500, "nothing goes out while the lockdown lasts")
a.run("LOCKDOWN = false")
pump(30)
check(c.stat("Anna", "rating") == 1520, "Anna's win reaches the guild once the lockdown lifts")

# 2. The send itself is refused with AddOnMessageLockdown (no lockdown check beforehand).
a.run("C_ChatInfo.InChatMessagingLockdown = nil")
a.run("""
REFUSE = true
local realSend = C_ChatInfo.SendAddonMessage
C_ChatInfo.SendAddonMessage = function(...)
    if REFUSE then return Enum.SendAddonMessageResult.AddOnMessageLockdown end
    return realSend(...)
end
""")
duel("Anna", "Bo")
won = a.stat("Anna", "rating")
check(won > 1520, "Anna records a second win while sends are refused")
check(c.stat("Anna", "rating") == 1520, "refused messages don't arrive")
a.run("REFUSE = false")
pump(30)
check(c.stat("Anna", "rating") == won, "refused messages are sent again later, not dropped")

# 3. Secret chat text is skipped without errors.
a.run("""
SECRET = {}
function issecretvalue(v) return v == SECRET end
""")
before = a.stat("Anna", "w")
a.run('FIRE("CHAT_MSG_SYSTEM", SECRET)')
check(a.stat("Anna", "w") == before, "a secret system message is ignored")

# 4. A client without GetGuildRosterInfo doesn't break the roster.
a.run("GetGuildRosterInfo = nil")
roster_ok = a.eval("(function() local ok = pcall(NS.Compat.GetGuildRoster); return ok end)()")
check(roster_ok, "the roster read doesn't error when GetGuildRosterInfo is missing")
a.run('FIRE("GUILD_ROSTER_UPDATE")')
check(a.stat("Anna", "rating") == won, "the ladder survives a roster update without the roster API")

if failures:
    raise SystemExit(1)

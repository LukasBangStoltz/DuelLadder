# DuelLadder

A guild duel ladder for World of Warcraft: ratings, titles, King of the Hill, badges,
head-to-head records and gold betting for every character in your guild. Built for
**TBC Anniversary** (client 2.5.6), with **WoW Forever** in mind.

Every character is its own entry, so alts show up separately. Stats are shared with the
guild over hidden addon messages, so everyone with the addon sees the same ladder, even
for members who are offline.

## Features

- **Ladder** - everyone ranked by rating, with title, wins, losses, win %, streaks, times
  fled and badge count. Click a column to sort.
- **Rating and titles** - chess-style (Elo) rating starting at 1500. Titles from Peasant to
  Warlord; Recruit until 5 duels.
- **King of the Hill** - the first winner takes the crown; beat the king to take it.
- **Members** - a profile for everyone with the addon: record, streaks, nemesis, favourite
  victim, biggest rival, badges and their record against every other member.
- **Matchups** - every rivalry in the guild as a scoreboard line, with a Bet button.
- **History** - recent duels across the guild with rating changes and where they happened.
- **Bets** (gold and silver)
  - *Challenges*: one-on-one. Challenge someone for an amount; they accept (matching it) or
    decline. The winner of your next duel takes it all.
  - *Public pots*: anyone can bet on either fighter. The winners split the losers' money by
    how much they bet.
  - Cancel until the duel starts. A cancel made mid-fight doesn't count.
  - DuelLadder never moves money: it works out who pays whom, **Pay** fills in a trade
    (if they're next to you) or a mail, and the winner confirms with **Got it**.
- **Badges** - 18 badges like Flawless, Clutch, Giant Slayer, Kingslayer and Chicken.
- **Minimap button** with your record, the king and the top 3.

## Install

1. Download the latest zip from [Releases](https://github.com/LukasBangStoltz/DuelLadder/releases),
   or clone this repo.
2. Put it in `World of Warcraft\_anniversary_\Interface\AddOns` so you have
   `AddOns\DuelLadder\DuelLadder.toc`.
3. Restart the game (a `/reload` won't pick up new files).

Everyone in the guild should run the same version: sync formats change between versions.

## Commands

| Command | What it does |
| --- | --- |
| `/duels` | Show or hide the window |
| `/duels me` | Your profile |
| `/duels bets` | Open the Bets tab |
| `/duels sync` | Ask the guild for fresh stats (normally automatic) |
| `/duels guildonly` | Toggle counting only duels against guild members |
| `/duels announce` | Toggle posting your wins in guild chat |
| `/duels minimap` | Show or hide the minimap button |

## How it works

- Duel results come from the system message ("X has defeated Y in a duel"), read with the
  client's own localized strings, so it works in any language. Each duelist records their
  own side.
- Only the owner of a character changes its stats; everyone else keeps the copy with the
  highest revision. Bets are merged, since several people change parts of them.
- Everything that differs between game clients lives in `Compat.lua`, to make porting to
  WoW Forever easier. The addon never reads combat data.

## Files

| File | Purpose |
| --- | --- |
| `Compat.lua` | Every client-specific API call |
| `Core.lua` | Event bus and startup |
| `Data.lua` | Saved data, rating, titles, crown, wire format |
| `Badges.lua` | Badge definitions and awarding |
| `Bets.lua` | Challenges, pots, payouts, payments |
| `Sync.lua` | Guild sync over addon messages |
| `Duel.lua` | Detecting duel results |
| `UI/` | The window and one file per tab |
| `Commands.lua`, `Minimap.lua` | Slash commands and the minimap button |
| `Libs/` | LibStub, CallbackHandler, LibDataBroker, LibDBIcon |
| `tests/` | Out-of-game test harness (not loaded by WoW) |
| `media/` | Project logo (not part of the addon) |

## Tests

The tests run the addon in a Lua 5.1 runtime with fake WoW APIs and simulate several guild
members dueling, syncing and betting. They need Python 3 and
[lupa](https://pypi.org/project/lupa/):

```bash
pip install lupa
```

```bash
python tests/run_all.py
```

The tests can't show what the window looks like in the game, so changes to the UI still
need a look in-game. GitHub runs them on every push (`.github/workflows/tests.yml`).

## Releasing

Releases are built by the [BigWigs packager](https://github.com/BigWigsMods/packager)
(`.github/workflows/release.yml`):

1. Bump `## Version:` in `DuelLadder.toc` and commit.
2. Tag the commit with the same version and push the tag:

   ```bash
   git tag v0.4.1
   ```

   ```bash
   git push origin v0.4.1
   ```

3. GitHub runs the tests, checks the tag matches the `.toc` version, builds the zip
   (without `tests/`, see `.pkgmeta`) and publishes the GitHub Release.

**CurseForge:** the project ID is in `DuelLadder.toc` (`## X-Curse-Project-ID`), and the
upload token is the repository secret `CF_API_TOKEN` (created under Author Settings → API
Tokens on authors.curseforge.com). Every release is uploaded to CurseForge too.
`## Interface: 20506` is published as TBC Classic (Anniversary).

## License

MIT - see [LICENSE](LICENSE). The bundled libraries in `Libs/` keep their own licenses.

# StoryTracker — WoW Character Chronicle Addon (Retail)

Records every detail of your Retail WoW journey for storytelling.

**This is the Retail version. For WoW Forever (Classic 1.15.x), see [wow-storytracker-addon](https://github.com/ninepointlabs/wow-storytracker-addon).**

## What It Tracks

Every session is recorded to SavedVariables with timestamps, zones, and details:

| Category | What Gets Recorded |
|----------|-------------------|
| **Quests** | Accepted, completed, abandoned — with names and levels |
| **Zones** | Every zone, subzone, and continent change |
| **Levels** | Your dings and your party members' dings |
| **Deaths** | Where, who killed you, and with what ability |
| **Dungeons** | Entered, bosses killed, completed (via ENCOUNTER_END) |
| **Loot** | Rare, epic, and legendary items — plus new gear equipped and mounts learned |
| **Achievements** | Every achievement earned, with name and points |
| **Transmog** | New appearances added to your collection |
| **Reputation** | Every faction standing change |
| **Professions** | Skillups and recipes learned |
| **Gold** | Earned, spent, and session net totals |
| **Combat** | Notable elite/rare/world boss kills |
| **Social** | Guild join/leave, party/raid formation |
| **PvP** | Honorable kills, battleground results, duels |
| **Sessions** | Login/logout times, duration, zones |

World quests and bonus objectives are not recorded as quest events.

## Compatibility

**WoW Retail (11.x+).** Does not work on Classic or Forever — use the
[Forever version](https://github.com/ninepointlabs/wow-storytracker-addon) there.

Both versions write the same `StoryTrackerDB` format (each event is
`{ type, timestamp, zone, data }`), so the companion tool reads either.

## Installation

1. Download the latest release from the [Releases page](https://github.com/ninepointlabs/wow-storytracker-addon-retail/releases)
2. Extract to `World of Warcraft/_retail_/Interface/AddOns/StoryTracker/`
3. Works immediately — no configuration needed

## How It Works

StoryTracker hooks into WoW's event system and records structured data to
`StoryTrackerDB` SavedVariables. On logout or `/reload`, the file
`WTF/Account/<account>/SavedVariables/StoryTracker.lua` is written to disk.

A companion tool (in the [storytracker repo](https://github.com/ninepointlabs/wow-storytracker))
reads that file, detects new events since the last report, and feeds them
to an AI that composes narrative blog posts at [myazerothlife.com](https://myazerothlife.com).

## Screenshots

StoryTracker takes a screenshot (WoW's own `Screenshot()`, saved to the
game's `Screenshots` folder) about 0.75 s after each story moment, so blog
posts can use them:

- quest turn-in
- level up
- achievement earned
- boss kill (successful `ENCOUNTER_END`)
- first visit to a zone (tracked per character; zones already in your
  history count as visited)
- other story moments: entering a dungeon or battleground, battleground
  result, notable (rare/elite) kills, new mounts, epic or better loot,
  duels, joining a guild, reputation standing increases, and deaths
- optionally every 15 minutes, only when you're out of combat, not on a
  loading screen and not AFK

At most one screenshot is taken per 20 seconds; when two moments land
together (a turn-in that dings) the shot is labelled with the bigger one.
With "hide UI" on, the interface is hidden for the shot when you're out of
combat; in combat it is never touched.

Each shot is logged to `StoryTrackerDB.screenshotLog` with its time, the
`WoWScrnShot_MMDDYY_HHMMSS` file name WoW gives it, what happened, the zone
and subzone, and the character's name, realm and level. Entries older than
30 days are dropped from the log.

**Addons cannot delete files**, so StoryTracker never removes screenshots.
Clean up the `Screenshots` folder outside the game.

## Slash Commands

- `/storytracker` — show event and session count
- `/storytracker shots` — show screenshot settings
- `/storytracker shots on|off` — turn auto-screenshots on or off (default on)
- `/storytracker shots <event> on|off` — per event: `quest`, `levelup`,
  `achievement`, `boss`, `newzone`, `story` (all default on)
- `/storytracker shots timer on|off|<minutes>` — timed shots (default on,
  every 15 minutes; 1-120)
- `/storytracker shots hideui on|off` — hide the UI for shots when out of
  combat (default off)
- `/storytracker shots log` — show the last few logged screenshots
- `/storytracker about` — print version, license, support address (with a version line to paste into your email), privacy details, and your WoW client build
- `/storytracker debug` — toggle debug mode

## License

MIT © 2026 Nine Point Labs

## Privacy

StoryTracker has no network access (WoW addons can't use the internet). It
records the categories above for your own character, saved by WoW to
`WTF/Account/<account>/SavedVariables/StoryTracker.lua`. Other players' names
are saved only from your group roster, party level-ups, duels, honorable kills,
and death recaps; no player chat is read or saved.
Screenshots are saved by WoW to its `Screenshots` folder; the log records
when and where each was taken. The file stays on your computer — nothing leaves it unless you run the companion tool or share the
file yourself. To clear it, log out and delete that file (and
`StoryTracker.lua.bak`). `/storytracker about` prints the same summary in game.

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

## Slash Commands

- `/storytracker` — show event and session count
- `/storytracker debug` — toggle debug mode

## License

MIT © 2026 Tim

## Privacy

All data stays on your machine. The SavedVariables file never leaves your
computer. Blog posts are generated locally by your own AI agent.

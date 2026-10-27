-- Plain-Lua checks for auto-screenshots: event mapping, debounce, merge,
-- timer conditions, new-zone tracking, log shape and 30-day trim.
-- Run from the repo root: lua tests/screenshots_test.lua
local out = {}
print = function(s) table.insert(out, tostring(s)) end -- luacheck: ignore

-- Clocks: GetTime() is monotonic seconds, time() is epoch seconds.
local clock = 1000
local epoch = 1798380000 -- 2026-12-27-ish; exact value doesn't matter
GetTime = function() return clock end
local realDate = os.date
time = function() return epoch end
date = function(fmt, t) return realDate(fmt, t or epoch) end

-- C_Timer: callbacks run when the test advances the clock.
local timers = {}
local tickers = {}
C_Timer = {
    After = function(delay, fn) table.insert(timers, { at = clock + delay, fn = fn }) end,
    NewTicker = function(interval, fn)
        local t = { interval = interval, fn = fn, Cancel = function(self) self.cancelled = true end }
        table.insert(tickers, t)
        return t
    end,
}
local function Advance(seconds)
    local target = clock + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local nextTimer = timers[1]
        if not nextTimer or nextTimer.at > target then break end
        table.remove(timers, 1)
        clock = nextTimer.at
        nextTimer.fn()
    end
    clock = target
end

local shotsTaken = 0
Screenshot = function() shotsTaken = shotsTaken + 1 end

local combat, afk = false, false
InCombatLockdown = function() return combat end
UnitAffectingCombat = function() return combat end
UnitIsAFK = function() return afk end

local zone, subzone = "Elwynn Forest", "Goldshire"
GetZoneText = function() return zone end
GetSubZoneText = function() return subzone end
GetCVar = function(name) if name == "screenshotFormat" then return "jpeg" end end
UnitName = function() return "Tim" end
GetRealmName = function() return "Wyrmrest Accord" end
UnitClass = function() return "Warrior", "WARRIOR" end
UnitRace = function() return "Human", "Human" end
UnitLevel = function() return 12 end
UnitFactionGroup = function() return "Alliance" end
GetGuildInfo = function() return nil end

local uiShown = true
UIParent = {
    IsShown = function() return uiShown end,
    Hide = function() assert(not combat, "UIParent hidden in combat"); uiShown = false end,
    Show = function() assert(not combat, "UIParent shown in combat"); uiShown = true end,
}

local frames = {}
CreateFrame = function()
    local f = { events = {} }
    f.RegisterEvent = function(self, e) self.events[e] = true end
    f.UnregisterEvent = function(self, e) self.events[e] = nil end
    f.SetScript = function(self, _, fn) self.onEvent = fn end
    table.insert(frames, f)
    return f
end
SlashCmdList = {}

local ST = {}
assert(loadfile("core.lua"))("StoryTracker", ST)
assert(loadfile("screenshots.lua"))("StoryTracker", ST)
local coreFrame, shotFrame = frames[1], frames[2]

-- Existing SavedVariables: an old log entry and a zone already on record.
StoryTrackerDB = {
    screenshotLog = {
        { time = epoch - 31 * 86400, event = "quest", description = "too old" },
        { time = epoch - 29 * 86400, event = "quest", description = "keep me" },
    },
    characters = {
        ["Tim-WyrmrestAccord"] = {
            events = { { type = "ZONE_CHANGED_NEW_AREA", data = { zone = "Westfall" } } },
            sessions = {},
        },
    },
}
coreFrame.onEvent(coreFrame, "ADDON_LOADED", "StoryTracker")

local log = StoryTrackerDB.screenshotLog
local settings = StoryTrackerDB.screenshotSettings
local checks = 0
local function eq(actual, expected, what)
    checks = checks + 1
    assert(actual == expected, what .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

-- Defaults and trim on load.
eq(settings.enabled, true, "enabled default")
eq(settings.hideUI, false, "hideUI default")
eq(settings.timer, true, "timer default")
eq(settings.timerMinutes, 15, "timer minutes default")
for _, key in ipairs(ST.SCREENSHOT_EVENTS) do eq(settings.events[key], true, key .. " default") end
eq(#log, 1, "old entry trimmed on load")
eq(log[1].description, "keep me", "recent entry kept")
eq(#tickers, 1, "timer started")
eq(tickers[1].interval, 900, "timer interval seconds")
eq(shotFrame.events.SCREENSHOT_SUCCEEDED, true, "shot frame registered")

-- Quest turn-in: shot after the delay, not before; logged with full shape.
ST:RecordEvent("QUEST_COMPLETED", { questName = "The Fargodeep Mine", questID = 62 })
eq(shotsTaken, 0, "no shot before delay")
Advance(1)
eq(shotsTaken, 1, "quest shot taken")
local e = log[#log]
eq(e.event, "quest", "log event")
eq(e.source, "QUEST_COMPLETED", "log source")
eq(e.description, "The Fargodeep Mine", "log description")
eq(e.zone, "Elwynn Forest", "log zone")
eq(e.subzone, "Goldshire", "log subzone")
eq(e.character, "Tim-WyrmrestAccord", "log character")
eq(e.name, "Tim", "log name")
eq(e.realm, "WyrmrestAccord", "log realm")
eq(e.level, 12, "log level")
eq(e.time, epoch, "log time")
eq(e.stamp, realDate("%m%d%y_%H%M%S", epoch), "log stamp")
eq(e.file, "WoWScrnShot_" .. e.stamp .. ".jpg", "log file")
eq(e.date, realDate("%Y-%m-%d %H:%M:%S", epoch), "log date")

-- Debounce: another moment within 20 s is dropped, after 20 s it fires.
Advance(5)
eq(ST:RequestScreenshot("boss", "Hogger", "DUNGEON_BOSS_KILLED"), "debounced", "debounced inside 20 s")
Advance(15)
ST:RecordEvent("PLAYER_LEVEL_UP", { level = 13 })
Advance(1)
eq(shotsTaken, 2, "level-up shot after debounce window")
eq(log[#log].description, "Reached level 13", "level-up description")

-- Two moments inside the delay: one shot, labelled with the bigger one.
Advance(30)
ST:RecordEvent("QUEST_COMPLETED", { questName = "Report to Goldshire" })
ST:RecordEvent("PLAYER_LEVEL_UP", { level = 14 })
Advance(1)
eq(shotsTaken, 3, "merged into one shot")
eq(log[#log].event, "levelup", "merged shot uses higher priority")

-- Routine records don't trigger shots; story moments do.
Advance(30)
ST:RecordEvent("PLAYER_MONEY", { delta = 50000 })
ST:RecordEvent("CHAT_MSG_LOOT", { itemName = "Blue Thing", quality = 3 })
ST:RecordEvent("UPDATE_FACTION", { faction = "Stormwind", change = "discovered" })
Advance(1)
eq(shotsTaken, 3, "routine records ignored")
ST:RecordEvent("NOTABLE_KILL", { name = "Mother Fang", classification = "rare" })
Advance(1)
eq(shotsTaken, 4, "story moment shot")
eq(log[#log].description, "Killed Mother Fang (rare)", "story description")
eq(log[#log].source, "NOTABLE_KILL", "story source")

-- Boss kill and achievement.
Advance(30)
ST:RecordEvent("DUNGEON_BOSS_KILLED", { bossName = "Edwin VanCleef", instanceName = "The Deadmines" })
Advance(1)
eq(log[#log].description, "Edwin VanCleef (The Deadmines)", "boss description")
Advance(30)
ST:RecordEvent("ACHIEVEMENT_EARNED", { achievementName = "Level 10", alreadyEarned = true })
Advance(1)
eq(shotsTaken, 5, "already-earned achievement ignored")
ST:RecordEvent("ACHIEVEMENT_EARNED", { achievementName = "Level 20" })
Advance(1)
eq(shotsTaken, 6, "achievement shot")

-- New zones: first visit only; zones already on record don't count.
Advance(30)
ST:RecordEvent("ZONE_CHANGED_NEW_AREA", { zone = "Westfall" })
Advance(1)
eq(shotsTaken, 6, "zone from history is not new")
ST:RecordEvent("ZONE_CHANGED_NEW_AREA", { zone = "Redridge Mountains" })
Advance(1)
eq(shotsTaken, 7, "new zone shot")
eq(ST.char.visitedZones["Redridge Mountains"], true, "visited zone saved")
Advance(30)
ST:RecordEvent("ZONE_CHANGED_NEW_AREA", { zone = "Redridge Mountains" })
Advance(1)
eq(shotsTaken, 7, "revisit not shot")

-- Loading screen: the shot waits until it's over.
Advance(30)
shotFrame.onEvent(shotFrame, "LOADING_SCREEN_ENABLED")
ST:RecordEvent("ZONE_CHANGED_NEW_AREA", { zone = "Duskwood" })
Advance(3)
eq(shotsTaken, 7, "no shot during loading screen")
shotFrame.onEvent(shotFrame, "LOADING_SCREEN_DISABLED")
Advance(1)
eq(shotsTaken, 8, "shot after loading screen")

-- Timer: skipped in combat, AFK, or loading; otherwise shoots.
Advance(30)
combat = true
eq(ST:TimedScreenshot(), "skipped", "timer skipped in combat")
combat = false
afk = true
eq(ST:TimedScreenshot(), "skipped", "timer skipped while AFK")
afk = false
shotFrame.onEvent(shotFrame, "LOADING_SCREEN_ENABLED")
eq(ST:TimedScreenshot(), "skipped", "timer skipped while loading")
shotFrame.onEvent(shotFrame, "LOADING_SCREEN_DISABLED")
tickers[#tickers].fn()
Advance(1)
eq(shotsTaken, 9, "timer shot")
eq(log[#log].event, "timer", "timer event")
eq(log[#log].description, "Goldshire, Elwynn Forest", "timer description")

-- Hide UI: hidden around the shot out of combat, restored on success.
SlashCmdList.STORYTRACKER("shots hideui on")
eq(settings.hideUI, true, "hideui set")
Advance(30)
ST:RecordEvent("PLAYER_LEVEL_UP", { level = 15 })
Advance(0.8)
eq(uiShown, false, "UI hidden for shot")
Advance(0.2)
eq(shotsTaken, 10, "hidden-UI shot taken")
shotFrame.onEvent(shotFrame, "SCREENSHOT_SUCCEEDED")
eq(uiShown, true, "UI restored")
-- In combat the UI is left alone (UIParent asserts if touched).
Advance(30)
combat = true
ST:RecordEvent("DUNGEON_BOSS_KILLED", { bossName = "Ragnaros" })
Advance(1)
eq(shotsTaken, 11, "combat shot taken")
eq(uiShown, true, "UI untouched in combat")
combat = false
shotFrame.onEvent(shotFrame, "SCREENSHOT_FAILED")
eq(log[#log].failed, true, "failed shot flagged")

-- Settings via slash command.
SlashCmdList.STORYTRACKER("shots quest off")
eq(settings.events.quest, false, "quest toggle off")
Advance(30)
ST:RecordEvent("QUEST_COMPLETED", { questName = "Ignored" })
Advance(1)
eq(shotsTaken, 11, "disabled event not shot")
SlashCmdList.STORYTRACKER("shots timer 5")
eq(settings.timerMinutes, 5, "timer minutes set")
eq(tickers[#tickers].interval, 300, "ticker restarted with new interval")
eq(tickers[#tickers - 1].cancelled, true, "old ticker cancelled")
SlashCmdList.STORYTRACKER("shots timer 500")
eq(settings.timerMinutes, 5, "out-of-range interval rejected")
SlashCmdList.STORYTRACKER("shots timer off")
eq(settings.timer, false, "timer off")
eq(tickers[#tickers].cancelled, true, "ticker cancelled when timer off")
SlashCmdList.STORYTRACKER("shots off")
eq(settings.enabled, false, "master off")
eq(ST:RequestScreenshot("boss", "x"), "disabled", "nothing shot when off")
SlashCmdList.STORYTRACKER("shots on ")
eq(settings.enabled, true, "master on (trailing space)")
SlashCmdList.STORYTRACKER("shots")
assert(table.concat(out, "\n"):find("StoryTracker screenshots: on", 1, true), "status printed")

-- 30-day trim as time passes.
epoch = epoch + 31 * 86400
Advance(30)
ST:RecordEvent("PLAYER_LEVEL_UP", { level = 16 })
Advance(1)
eq(#log, 1, "log trimmed to last 30 days on add")
eq(log[1].description, "Reached level 16", "only the new entry remains")

-- A screenshot error must not stop the event being recorded.
local realOnStoryEvent = ST.OnStoryEvent
ST.OnStoryEvent = function() error("boom") end
local before = #ST.char.events
local record = ST:RecordEvent("QUEST_COMPLETED", { questName = "Unaffected" })
eq(#ST.char.events, before + 1, "event recorded")
eq(record and record.type, "QUEST_COMPLETED", "record returned")
ST.OnStoryEvent = realOnStoryEvent

io.stdout:write("screenshots_test: ok (" .. checks .. " checks)\n")

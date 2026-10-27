-- StoryTracker auto-screenshots: takes a screenshot shortly after story
-- moments (and optionally on a timer) and logs each one so blog posts can
-- match WoWScrnShot_MMDDYY_HHMMSS files to what happened.
-- Moments come from ST:RecordEvent, so they follow the events.lua handlers.
-- Addons cannot delete files; old screenshots are cleaned up outside WoW.

local _, ST = ...

-- Wait this long after an event so the moment is on screen.
local SHOT_DELAY_SECONDS = 0.75
-- At most one screenshot per this many seconds.
local DEBOUNCE_SECONDS = 20
-- Log entries older than this are dropped.
local LOG_KEEP_SECONDS = 30 * 24 * 60 * 60
-- A shot due during a loading screen is retried this often, this many times.
local LOADING_RETRY_SECONDS = 1
local LOADING_RETRIES = 10
-- If WoW never reports the capture, show the UI again after this long.
local UI_RESTORE_SECONDS = 3

local MIN_TIMER_MINUTES, MAX_TIMER_MINUTES = 1, 120

ST.SCREENSHOT_EVENTS = { "quest", "levelup", "achievement", "boss", "newzone", "story" }

local DEFAULTS = {
    enabled = true,
    hideUI = false,
    timer = true,
    timerMinutes = 15,
    events = {
        quest = true,
        levelup = true,
        achievement = true,
        boss = true,
        newzone = true,
        story = true,
    },
}

-- When two moments land inside the shot delay (a quest turn-in that
-- dings), the shot is labelled with the bigger one.
local PRIORITY = {
    timer = 0, story = 1, newzone = 2, quest = 3, achievement = 4, levelup = 5, boss = 6,
}

local MIN_STORY_LOOT_QUALITY = 4 -- epic+

local function Join(a, b)
    if a and b then return a .. " (" .. b .. ")" end
    return a or b
end

-- Recorded event type -> function(data) returning a description, or nil
-- to skip. These are the other moments StoryTracker records that are worth
-- a picture; routine ones (gold, reputation discovery, skill-ups) are not.
local STORY_MOMENTS = {
    DUNGEON_ENTERED = function(d) return "Entered " .. (d.instanceName or "an instance") end,
    PVP_BATTLEGROUND_ENTERED = function(d) return "Entered " .. (d.instanceName or "a battleground") end,
    PVP_BATTLEGROUND_ENDED = function(d)
        return (d.won and "Won " or "Lost ") .. (d.battleground or "a battleground")
    end,
    NOTABLE_KILL = function(d) return "Killed " .. Join(d.name or "a notable enemy", d.classification) end,
    MOUNT_LEARNED = function(d) return "New mount: " .. (d.mountName or "unknown") end,
    CHAT_MSG_LOOT = function(d)
        if not d.quality or d.quality < MIN_STORY_LOOT_QUALITY then return nil end
        return "Looted " .. (d.itemName or "an item")
    end,
    PVP_DUEL = function(d)
        return (d.won and "Won a duel against " or "Lost a duel to ")
            .. ((d.won and d.loser or d.winner) or "someone")
    end,
    GUILD_JOINED = function(d) return "Joined " .. (d.guild or "a guild") end,
    UPDATE_FACTION = function(d)
        if d.change ~= "increased" then return nil end
        return (d.faction or "Reputation") .. ": " .. (d.standing or "up")
    end,
    PLAYER_DEAD = function(d) return d.killer and ("Killed by " .. d.killer) or "Died" end,
}

-- Recorded event type -> screenshot event key and description.
local function Classify(eventType, data)
    if eventType == "QUEST_COMPLETED" then
        return "quest", data.questName or ("Quest " .. tostring(data.questID or "?"))
    elseif eventType == "PLAYER_LEVEL_UP" then
        return "levelup", "Reached level " .. tostring(data.level or UnitLevel("player"))
    elseif eventType == "ACHIEVEMENT_EARNED" then
        if data.alreadyEarned then return nil end
        return "achievement", data.achievementName or ("Achievement " .. tostring(data.achievementID or "?"))
    elseif eventType == "DUNGEON_BOSS_KILLED" then
        return "boss", Join(data.bossName or "Boss", data.instanceName)
    elseif eventType == "ZONE_CHANGED_NEW_AREA" then
        return "newzone", data.zone
    end
    local story = STORY_MOMENTS[eventType]
    if story then
        return "story", story(data)
    end
    return nil
end

local shots = {
    pending = nil,     -- { kind, description, source }
    lastShotAt = nil,  -- GetTime() of the last screenshot
    loading = false,   -- a loading screen is up
    uiHidden = false,  -- we hid UIParent for the current shot
    ticker = nil,
    current = nil,     -- log entry of the shot in flight
}
ST.shots = shots

------------------------------------------------------------------------
-- Settings and log
------------------------------------------------------------------------

local function ApplyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            ApplyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

function ST:ScreenshotSettings()
    return self.db.screenshotSettings
end

-- Drop entries older than LOG_KEEP_SECONDS, keeping order.
function ST:TrimScreenshotLog(now)
    local log = self.db.screenshotLog
    local cutoff = (now or time()) - LOG_KEEP_SECONDS
    local kept = 0
    for i = 1, #log do
        local entry = log[i]
        if type(entry) == "table" and (entry.time or 0) >= cutoff then
            kept = kept + 1
            log[kept] = entry
        end
    end
    for i = #log, kept + 1, -1 do
        log[i] = nil
    end
end

local function ScreenshotExtension()
    local format = GetCVar and GetCVar("screenshotFormat")
    if format == "jpeg" or format == nil or format == "" then return "jpg" end
    return format
end

local function LogShot(kind, description, source)
    local now = time()
    local char = ST.char or {}
    local stamp = date("%m%d%y_%H%M%S", now)
    local sub = GetSubZoneText and GetSubZoneText() or ""
    local entry = {
        time = now,
        date = date("%Y-%m-%d %H:%M:%S", now),
        stamp = stamp,
        file = "WoWScrnShot_" .. stamp .. "." .. ScreenshotExtension(),
        event = kind,
        source = source,
        description = description,
        zone = GetZoneText() or "",
        subzone = sub ~= "" and sub or nil,
        character = ST.charKey,
        name = char.name or UnitName("player"),
        realm = char.realm,
        level = UnitLevel("player") or char.level,
    }
    table.insert(ST.db.screenshotLog, entry)
    ST:TrimScreenshotLog(now)
    return entry
end

------------------------------------------------------------------------
-- Taking shots
------------------------------------------------------------------------

local function RestoreUI()
    if shots.uiHidden and not (InCombatLockdown and InCombatLockdown()) then
        shots.uiHidden = false
        if UIParent and not UIParent:IsShown() then UIParent:Show() end
    end
end

local function InCombat()
    return (InCombatLockdown and InCombatLockdown())
        or (UnitAffectingCombat and UnitAffectingCombat("player")) or false
end

local function Capture(kind, description, source)
    shots.lastShotAt = GetTime()
    shots.current = LogShot(kind, description, source)
    -- UIParent parents protected frames, so it is only touched out of
    -- combat; PLAYER_REGEN_DISABLED shows it again before lockdown.
    if ST:ScreenshotSettings().hideUI and UIParent and UIParent:IsShown() and not InCombat() then
        shots.uiHidden = true
        UIParent:Hide()
        -- Give the client a frame without the UI before capturing.
        C_Timer.After(0.1, function()
            Screenshot()
            C_Timer.After(UI_RESTORE_SECONDS, RestoreUI)
        end)
    else
        Screenshot()
    end
    if ST.debug then
        print("StoryTracker screenshot: " .. kind .. " - " .. tostring(description))
    end
end

local function Debounced()
    return shots.lastShotAt and (GetTime() - shots.lastShotAt) < DEBOUNCE_SECONDS
end

local function FirePending(tries)
    local pending = shots.pending
    if not pending then return end
    if shots.loading and tries < LOADING_RETRIES then
        C_Timer.After(LOADING_RETRY_SECONDS, function() FirePending(tries + 1) end)
        return
    end
    shots.pending = nil
    if shots.loading or Debounced() or not ST:ScreenshotSettings().enabled then return end
    Capture(pending.kind, pending.description, pending.source)
end

-- Queue a screenshot for event `kind` ("quest", "timer", ...). Returns
-- "queued", "merged", "debounced" or "disabled".
function ST:RequestScreenshot(kind, description, source)
    local settings = self:ScreenshotSettings()
    if not settings or not settings.enabled then return "disabled" end
    if kind == "timer" then
        if not settings.timer then return "disabled" end
    elseif not settings.events[kind] then
        return "disabled"
    end
    if Debounced() then return "debounced" end
    local pending = shots.pending
    if pending then
        if (PRIORITY[kind] or 0) > (PRIORITY[pending.kind] or 0) then
            pending.kind, pending.description, pending.source = kind, description, source
        end
        return "merged"
    end
    shots.pending = { kind = kind, description = description, source = source }
    C_Timer.After(SHOT_DELAY_SECONDS, function() FirePending(0) end)
    return "queued"
end

-- A new zone gets a shot only on the character's first visit.
local function FirstVisit(zone)
    if not zone or zone == "" then return false end
    local visited = ST.char.visitedZones
    if visited[zone] then return false end
    visited[zone] = true
    return true
end

function ST:OnStoryEvent(record)
    local kind, description = Classify(record.type, record.data or {})
    if not kind then return end
    if kind == "newzone" and not FirstVisit(description) then return end
    if not description then return end
    return self:RequestScreenshot(kind, description, record.type)
end

-- Every recorded event passes through here; a screenshot problem must
-- never stop the event being recorded.
local RecordEvent = ST.RecordEvent
function ST:RecordEvent(eventType, data)
    local record = RecordEvent(self, eventType, data)
    if record and self.db and self.db.screenshotSettings then
        local ok, err = pcall(self.OnStoryEvent, self, record)
        if not ok and self.debug then
            print("|cffff6060StoryTracker screenshot error|r: " .. tostring(err))
        end
    end
    return record
end

------------------------------------------------------------------------
-- Timer
------------------------------------------------------------------------

function ST:TimedScreenshot()
    if InCombat() or shots.loading then return "skipped" end
    if UnitIsAFK and UnitIsAFK("player") then return "skipped" end
    local zone = GetZoneText() or ""
    local sub = GetSubZoneText and GetSubZoneText() or ""
    return self:RequestScreenshot("timer", sub ~= "" and (sub .. ", " .. zone) or zone, "TIMER")
end

function ST:RestartScreenshotTimer()
    if shots.ticker then
        shots.ticker:Cancel()
        shots.ticker = nil
    end
    local settings = self:ScreenshotSettings()
    if not (settings.enabled and settings.timer and C_Timer.NewTicker) then return end
    shots.ticker = C_Timer.NewTicker(settings.timerMinutes * 60, function()
        ST:TimedScreenshot()
    end)
end

------------------------------------------------------------------------
-- Setup and events
------------------------------------------------------------------------

-- Zones the character already has on record count as visited, so
-- existing characters don't get a shot of every zone they return to.
local function SeedVisitedZones(char)
    if char.visitedZones then return end
    local visited = {}
    for _, record in ipairs(char.events or {}) do
        local zone = record.type == "ZONE_CHANGED_NEW_AREA" and record.data and record.data.zone
        if zone and zone ~= "" then visited[zone] = true end
    end
    for _, session in ipairs(char.sessions or {}) do
        if session.loginZone and session.loginZone ~= "" then visited[session.loginZone] = true end
    end
    char.visitedZones = visited
end

local shotFrame = CreateFrame("Frame")
local shotEvents = {}

function shotEvents.SCREENSHOT_SUCCEEDED()
    shots.current = nil
    RestoreUI()
end

function shotEvents.SCREENSHOT_FAILED()
    if shots.current then shots.current.failed = true end
    shots.current = nil
    RestoreUI()
end

-- Fires just before combat lockdown starts: last chance to show the UI.
shotEvents.PLAYER_REGEN_DISABLED = RestoreUI

function shotEvents.LOADING_SCREEN_ENABLED()
    shots.loading = true
end

function shotEvents.LOADING_SCREEN_DISABLED()
    shots.loading = false
end

-- The zone a session starts in is the baseline, not an arrival.
function shotEvents.PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi)
    shots.loading = false
    if ST.char and (isInitialLogin or isReloadingUi) then
        local zone = GetZoneText()
        if zone and zone ~= "" then ST.char.visitedZones[zone] = true end
    end
end

-- Clients without an events.lua achievement handler (Forever) still get
-- achievement shots if the event exists there.
function shotEvents.ACHIEVEMENT_EARNED(achievementID, alreadyEarned)
    if ST.handlers.ACHIEVEMENT_EARNED or not achievementID then return end
    local name = GetAchievementInfo and select(2, GetAchievementInfo(achievementID))
    ST:OnStoryEvent({
        type = "ACHIEVEMENT_EARNED",
        data = { achievementID = achievementID, achievementName = name, alreadyEarned = alreadyEarned },
    })
end

shotFrame:SetScript("OnEvent", function(_, event, ...)
    if not ST.db or not ST.db.screenshotSettings then return end
    local ok, err = pcall(shotEvents[event], ...)
    if not ok and ST.debug then
        print("|cffff6060StoryTracker screenshot error|r in " .. event .. ": " .. tostring(err))
    end
end)

-- Called from core.lua once SavedVariables and the character are ready.
function ST:InitScreenshots()
    local db = self.db
    if type(db.screenshotSettings) ~= "table" then db.screenshotSettings = {} end
    ApplyDefaults(db.screenshotSettings, DEFAULTS)
    if type(db.screenshotLog) ~= "table" then db.screenshotLog = {} end
    self:TrimScreenshotLog()
    SeedVisitedZones(self.char)
    for event in pairs(shotEvents) do
        pcall(shotFrame.RegisterEvent, shotFrame, event)
    end
    self:RestartScreenshotTimer()
end

------------------------------------------------------------------------
-- /storytracker shots
------------------------------------------------------------------------

local function OnOff(value) return value and "on" or "off" end

local function PrintShotStatus()
    local s = ST:ScreenshotSettings()
    print("StoryTracker screenshots: " .. OnOff(s.enabled)
        .. ", timer " .. OnOff(s.timer) .. " every " .. s.timerMinutes .. " min"
        .. ", hide UI " .. OnOff(s.hideUI)
        .. ", " .. #ST.db.screenshotLog .. " logged (last 30 days)")
    local parts = {}
    for _, key in ipairs(ST.SCREENSHOT_EVENTS) do
        table.insert(parts, key .. " " .. OnOff(s.events[key]))
    end
    print("Events: " .. table.concat(parts, ", "))
    print("Commands: /storytracker shots on|off, shots <event> on|off, shots timer on|off|<minutes>, shots hideui on|off, shots log")
end

local function ParseOnOff(word)
    if word == "on" then return true end
    if word == "off" then return false end
    return nil
end

-- msg is everything after "shots", already lowercased.
function ST:ScreenshotCommand(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    if not (self.db and self.db.screenshotSettings) then
        print("StoryTracker: not initialized")
        return
    end
    local s = self:ScreenshotSettings()
    local word, arg = msg:match("^(%S*)%s*(.-)$")
    local flag = ParseOnOff(word)

    if word == "" or word == "status" then
        PrintShotStatus()
    elseif flag ~= nil then
        s.enabled = flag
        self:RestartScreenshotTimer()
        print("StoryTracker screenshots " .. OnOff(flag))
    elseif word == "timer" then
        local minutes = tonumber(arg)
        local timerFlag = ParseOnOff(arg)
        if minutes then
            minutes = math.floor(minutes)
            if minutes < MIN_TIMER_MINUTES or minutes > MAX_TIMER_MINUTES then
                print("StoryTracker: timer interval must be " .. MIN_TIMER_MINUTES .. "-" .. MAX_TIMER_MINUTES .. " minutes")
                return
            end
            s.timerMinutes = minutes
            s.timer = true
        elseif timerFlag ~= nil then
            s.timer = timerFlag
        else
            print("Usage: /storytracker shots timer on|off|<minutes>")
            return
        end
        self:RestartScreenshotTimer()
        print("StoryTracker timed screenshots " .. OnOff(s.timer) .. ", every " .. s.timerMinutes .. " min")
    elseif word == "hideui" then
        local value = ParseOnOff(arg)
        if value == nil then
            print("Usage: /storytracker shots hideui on|off")
            return
        end
        s.hideUI = value
        print("StoryTracker hide UI for screenshots " .. OnOff(value) .. " (never in combat)")
    elseif word == "log" then
        local log = self.db.screenshotLog
        print("StoryTracker: " .. #log .. " screenshots logged; latest:")
        for i = math.max(1, #log - 4), #log do
            local e = log[i]
            print(string.format("%s %s %s - %s", e.file, e.event, tostring(e.description), e.zone or ""))
        end
    elseif s.events[word] ~= nil then
        local value = ParseOnOff(arg)
        if value == nil then
            print("Usage: /storytracker shots " .. word .. " on|off")
            return
        end
        s.events[word] = value
        print("StoryTracker " .. word .. " screenshots " .. OnOff(value))
    else
        PrintShotStatus()
    end
end

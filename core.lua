-- StoryTracker core: SavedVariables setup, character/session bookkeeping,
-- and event dispatch. Category handlers live in events.lua (ST.handlers).

local addonName, ST = ...

ST.DB_VERSION = 1
ST.handlers = ST.handlers or {}

-- A /reload fires PLAYER_LOGOUT then PLAYER_ENTERING_WORLD. If the gap is
-- shorter than this, the previous session is reopened instead of starting
-- a new one, so reloads don't fragment a play session.
local RELOAD_MERGE_SECONDS = 120

local frame = CreateFrame("Frame")
ST.frame = frame

-- Realm names can contain spaces ("Wyrmrest Accord"); keys must not.
local function NormalizedRealm()
    local realm = GetRealmName() or "Unknown"
    return (realm:gsub("%s+", ""))
end

function ST:CharacterKey()
    local name = UnitName("player") or "Unknown"
    return name .. "-" .. NormalizedRealm()
end

local function InitDB()
    if type(StoryTrackerDB) ~= "table" then
        StoryTrackerDB = {}
    end
    StoryTrackerDB.characters = StoryTrackerDB.characters or {}
    StoryTrackerDB.version = ST.DB_VERSION
    ST.db = StoryTrackerDB
end

-- Refresh character metadata. Safe to call repeatedly; guild info in
-- particular is often unavailable until after login completes.
function ST:UpdateCharacterInfo()
    local char = self.char
    if not char then return end

    local className, classToken = UnitClass("player")
    local raceName, raceToken = UnitRace("player")

    char.name = UnitName("player")
    char.realm = NormalizedRealm()
    char.class = classToken or char.class
    char.className = className or char.className
    char.race = raceToken or char.race
    char.raceName = raceName or char.raceName
    char.level = UnitLevel("player") or char.level
    char.faction = UnitFactionGroup("player") or char.faction

    -- Only fill guild on first sight; after that CheckGuild (events.lua)
    -- owns it, so join/leave is detected against last session's value.
    if not char.guildKnown then
        local guildName = GetGuildInfo("player")
        if guildName then
            char.guild = guildName
            char.guildKnown = true
        end
    end
end

local function InitCharacter()
    local key = ST:CharacterKey()
    local chars = ST.db.characters
    if type(chars[key]) ~= "table" then
        chars[key] = { created = time() }
    end
    local char = chars[key]
    char.events = char.events or {}
    char.sessions = char.sessions or {}
    ST.charKey = key
    ST.char = char
    ST:UpdateCharacterInfo()
end

-- Append an event record for the current character.
-- Every record: { type, timestamp, zone, data }.
function ST:RecordEvent(eventType, data)
    local char = self.char
    if not char then return nil end
    local record = {
        type = eventType,
        timestamp = time(),
        zone = GetZoneText() or "",
        data = data or {},
    }
    table.insert(char.events, record)
    return record
end

function ST:CurrentSession()
    return self.session
end

local function StartSession(isReload)
    local sessions = ST.char.sessions
    local last = sessions[#sessions]
    local now = time()

    if isReload and last and last.logoutTime
        and (now - last.logoutTime) <= RELOAD_MERGE_SECONDS then
        last.logoutTime = nil
        last.logoutZone = nil
        last.durationMinutes = nil
        last.reloads = (last.reloads or 0) + 1
        ST.session = last
        return
    end

    local session = {
        loginTime = now,
        loginZone = GetZoneText() or "",
        loginLevel = UnitLevel("player"),
        moneyEarned = 0,
        moneySpent = 0,
    }
    table.insert(sessions, session)
    ST.session = session
end

local function FinalizeSession()
    local session = ST.session
    if not session then return end
    local now = time()
    session.logoutTime = now
    session.logoutZone = GetZoneText() or ""
    session.logoutLevel = UnitLevel("player")
    session.durationMinutes = math.floor((now - session.loginTime) / 60 + 0.5)
end

-- Core lifecycle handlers. These run before any events.lua handler for
-- the same event, so ST.char / ST.session are ready for them.
local core = {}

function core.ADDON_LOADED(loadedName)
    if loadedName ~= addonName then return false end
    InitDB()
    InitCharacter()
    frame:UnregisterEvent("ADDON_LOADED")
    ST:RegisterHandlers()
    return true
end

function core.PLAYER_ENTERING_WORLD(isInitialLogin, isReloadingUi)
    if not ST.char then return end
    ST:UpdateCharacterInfo()
    -- PLAYER_ENTERING_WORLD also fires on every loading screen; only a
    -- login or reload starts a session. Older clients pass no args, so
    -- fall back to "start one if none is open".
    if isInitialLogin or isReloadingUi or not ST.session then
        StartSession(isReloadingUi)
        ST.sessionStarting = true
    else
        ST.sessionStarting = false
    end
end

function core.PLAYER_LOGOUT()
    if not ST.char then return end
    ST:UpdateCharacterInfo()
    FinalizeSession()
end

-- Some event names differ between client builds; registering an unknown
-- event raises an error on modern clients, so register defensively.
local function SafeRegister(event)
    local ok = pcall(frame.RegisterEvent, frame, event)
    return ok
end

function ST:RegisterHandlers()
    for event in pairs(self.handlers) do
        if not core[event] then
            SafeRegister(event)
        end
    end
    if self.OnLoad then
        self:OnLoad()
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    local coreHandler = core[event]
    if coreHandler then
        coreHandler(...)
    end
    local handler = ST.handlers[event]
    if handler and ST.char then
        local ok, err = pcall(handler, ...)
        if not ok and ST.debug then
            print("|cffff6060StoryTracker error|r in " .. event .. ": " .. tostring(err))
        end
    end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")

SLASH_STORYTRACKER1 = "/storytracker"
SlashCmdList["STORYTRACKER"] = function(msg)
    msg = (msg or ""):lower()
    if msg == "debug" then
        ST.debug = not ST.debug
        print("StoryTracker debug: " .. (ST.debug and "on" or "off"))
        return
    end
    local char = ST.char
    if not char then
        print("StoryTracker: not initialized")
        return
    end
    print(string.format("StoryTracker v%d: %s — %d events, %d sessions recorded",
        ST.DB_VERSION, ST.charKey, #char.events, #char.sessions))
end

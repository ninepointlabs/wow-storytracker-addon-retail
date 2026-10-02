-- StoryTracker event handlers. Each entry in H is registered by core.lua;
-- handlers call ST:RecordEvent(type, data) to append to the character log.

local _, ST = ...
local H = ST.handlers

-- Retail moved most item functions under C_Item; keep the global as a fallback.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- Individual PLAYER_MONEY events are recorded only for changes at least
-- this large (copper); every change still counts toward session totals.
local MONEY_EVENT_THRESHOLD = 10000 -- 1 gold

-- Seconds to wait after PLAYER_DEAD before reading the death recap.
local KILLER_RECAP_DELAY = 1

-- QUEST_REMOVED fires for turn-ins as well as abandons, and its order
-- relative to QUEST_TURNED_IN isn't guaranteed; wait this long before
-- deciding a removed quest was abandoned.
local ABANDON_CHECK_DELAY = 1

local MIN_LOOT_QUALITY = 3 -- 3 rare, 4 epic, 5 legendary

local QUALITY_BY_COLOR = {
    ["0070dd"] = 3,
    ["a335ee"] = 4,
    ["ff8000"] = 5,
}

local NOTABLE_CLASSIFICATIONS = {
    worldboss = true,
    rareelite = true,
    rare = true,
    elite = true,
}

-- Equipment slots worth recording (bags and the ranged/ammo slots excluded).
local EQUIPMENT_SLOTS = {
    [1] = "HEADSLOT",
    [2] = "NECKSLOT",
    [3] = "SHOULDERSLOT",
    [4] = "SHIRTSLOT",
    [5] = "CHESTSLOT",
    [6] = "WAISTSLOT",
    [7] = "LEGSSLOT",
    [8] = "FEETSLOT",
    [9] = "WRISTSLOT",
    [10] = "HANDSSLOT",
    [11] = "FINGER0SLOT",
    [12] = "FINGER1SLOT",
    [13] = "TRINKET0SLOT",
    [14] = "TRINKET1SLOT",
    [15] = "BACKSLOT",
    [16] = "MAINHANDSLOT",
    [17] = "SECONDARYHANDSLOT",
    [19] = "TABARDSLOT",
}

-- PvP team/faction indices used by battleground results.
local FACTION_BY_INDEX = { [0] = "Horde", [1] = "Alliance" }

local playerGUID
local state = {
    money = nil,
    factions = nil,      -- [name] = { standingID, value }
    skills = nil,        -- [name] = rank
    group = nil,         -- { kind, members = { [name] = true } }
    unitLevels = {},     -- [name] = level, for group members
    questCache = {},     -- [questID] = { title, level }
    turnedIn = {},       -- [questID] = true, until QUEST_REMOVED is resolved
    completingTitle = nil,
    instance = nil,      -- { name, type, maxPlayers, enteredAt }
    bgWinnerRecorded = false,
    notableTarget = nil, -- { guid, name, classification, level }, current target only
    equipment = {},      -- [slot] = itemLink
    equippedSeen = {},   -- [itemID] = true, items already worn this session
}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

-- Convert a Blizzard format string (e.g. ERR_LEARN_RECIPE_S) into an
-- anchored Lua pattern with captures.
local function FormatToPattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("%%%d?%$?s", "\001"):gsub("%%%d?%$?d", "\002")
    p = p:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
    p = p:gsub("\001", "(.+)"):gsub("\002", "(%%d+)")
    return "^" .. p .. "$"
end

local function ItemNameFromLink(link)
    return link and link:match("|h%[(.-)%]|h")
end

local function ItemIDFromLink(link)
    local id = link and link:match("|Hitem:(%d+)")
    return id and tonumber(id)
end

local function ItemQuality(link)
    local _, _, quality = GetItemInfo(link)
    if quality then return quality end
    -- Item not cached yet: fall back to the link's color code, either the
    -- classic |cffRRGGBB form or the newer |cnIQ<quality>: form.
    local iq = link:match("|cnIQ(%d+):")
    if iq then return tonumber(iq) end
    local color = link:match("|cff(%x%x%x%x%x%x)")
    return color and QUALITY_BY_COLOR[color:lower()] or nil
end

local function ItemLevel(link)
    if C_Item and C_Item.GetDetailedItemLevelInfo then
        return C_Item.GetDetailedItemLevelInfo(link)
    end
    return nil
end

local function SubZone()
    local sub = GetSubZoneText()
    if sub == "" then return nil end
    return sub
end

local function Continent()
    if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
    local mapID = C_Map.GetBestMapForUnit("player")
    local continentType = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
    local guard = 0
    while mapID and guard < 10 do
        local info = C_Map.GetMapInfo(mapID)
        if not info then return nil end
        if info.mapType == continentType then return info.name end
        mapID = info.parentMapID
        guard = guard + 1
    end
    return nil
end

local function IsGroupUnit(unit)
    return unit and (unit:match("^party%d") or unit:match("^raid%d")) and true or false
end

local function FullUnitName(unit)
    local name, realm = UnitName(unit)
    if not name or name == UNKNOWNOBJECT or name == "Unknown" then return nil end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

------------------------------------------------------------------------
-- Quests
------------------------------------------------------------------------

local function QuestLogEntry(index)
    local info = C_QuestLog.GetInfo(index)
    if not info or info.isHeader or info.isHidden then return nil end
    return info.title, info.level, info.questID
end

-- World quests and bonus objectives enter and leave the log as you move
-- around; they aren't story beats.
local function IsTaskQuest(questID)
    if not questID then return false end
    if C_QuestLog.IsWorldQuest and C_QuestLog.IsWorldQuest(questID) then return true end
    if C_QuestLog.IsQuestTask and C_QuestLog.IsQuestTask(questID) then return true end
    return false
end

local function ScanQuestLog()
    local numEntries = C_QuestLog.GetNumQuestLogEntries()
    for i = 1, numEntries do
        local title, level, questID = QuestLogEntry(i)
        if title and questID and not IsTaskQuest(questID) then
            state.questCache[questID] = { title = title, level = level }
        end
    end
end

function H.QUEST_ACCEPTED(questID)
    if IsTaskQuest(questID) then return end
    local index = questID and C_QuestLog.GetLogIndexForQuestID(questID)
    local title, level
    if index then
        title, level = QuestLogEntry(index)
    end
    title = title or (questID and C_QuestLog.GetTitleForQuestID(questID))
    if questID and title then
        state.questCache[questID] = { title = title, level = level }
    end
    ST:RecordEvent("QUEST_ACCEPTED", {
        questName = title,
        questLevel = level,
        questID = questID,
    })
end

function H.QUEST_LOG_UPDATE()
    ScanQuestLog()
end

-- Quest completion dialog is open; remember its title in case the quest
-- has already left the log by the time QUEST_TURNED_IN fires.
function H.QUEST_COMPLETE()
    state.completingTitle = GetTitleText and GetTitleText() or nil
end

-- A turn-in is signalled by QUEST_TURNED_IN; it is recorded under the
-- QUEST_COMPLETED type.
function H.QUEST_TURNED_IN(questID, xpReward, moneyReward)
    if IsTaskQuest(questID) then return end
    local cached = questID and state.questCache[questID]
    local title = cached and cached.title
    if not title and questID then
        title = C_QuestLog.GetTitleForQuestID(questID)
    end
    title = title or state.completingTitle
    ST:RecordEvent("QUEST_COMPLETED", {
        questName = title,
        questLevel = cached and cached.level or nil,
        questID = questID,
        xpReward = xpReward,
        moneyReward = moneyReward,
    })
    state.completingTitle = nil
    if questID then
        state.questCache[questID] = nil
        state.turnedIn[questID] = true
    end
end

-- QUEST_REMOVED covers turn-ins, abandons, and failures alike. Capture
-- what we know now, then once QUEST_TURNED_IN has had a chance to fire,
-- record it as abandoned only if it wasn't turned in.
function H.QUEST_REMOVED(questID)
    if not questID or IsTaskQuest(questID) then return end
    -- Leave the cache entry for QUEST_TURNED_IN to read if it fires later.
    local cached = state.questCache[questID]
    if not cached then
        state.turnedIn[questID] = nil
        return
    end

    local function Resolve()
        state.questCache[questID] = nil
        if state.turnedIn[questID] then
            state.turnedIn[questID] = nil
            return
        end
        if C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(questID) then
            return
        end
        ST:RecordEvent("QUEST_ABANDONED", {
            questName = cached.title,
            questLevel = cached.level,
            questID = questID,
        })
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(ABANDON_CHECK_DELAY, Resolve)
    else
        Resolve()
    end
end

------------------------------------------------------------------------
-- Zones, instances, battlegrounds
------------------------------------------------------------------------

local function CheckInstance()
    local inInstance, instanceType = IsInInstance()
    local current = state.instance

    if inInstance and (instanceType == "party" or instanceType == "raid" or instanceType == "pvp") then
        local name, _, _, difficultyName, maxPlayers = GetInstanceInfo()
        if current and current.name == name then return end
        if current then
            -- Zoned directly from one instance to another.
            ST:RecordEvent(current.type == "pvp" and "PVP_BATTLEGROUND_LEFT" or "DUNGEON_LEFT", {
                instanceName = current.name,
                minutesInside = math.floor((time() - current.enteredAt) / 60 + 0.5),
            })
        end
        state.instance = {
            name = name,
            type = instanceType,
            maxPlayers = maxPlayers,
            enteredAt = time(),
        }
        state.bgWinnerRecorded = false
        ST:RecordEvent(instanceType == "pvp" and "PVP_BATTLEGROUND_ENTERED" or "DUNGEON_ENTERED", {
            instanceName = name,
            instanceType = instanceType,
            difficulty = difficultyName ~= "" and difficultyName or nil,
            maxPlayers = maxPlayers,
        })
    elseif current then
        ST:RecordEvent(current.type == "pvp" and "PVP_BATTLEGROUND_LEFT" or "DUNGEON_LEFT", {
            instanceName = current.name,
            minutesInside = math.floor((time() - current.enteredAt) / 60 + 0.5),
        })
        state.instance = nil
    end
end

function H.ZONE_CHANGED_NEW_AREA()
    local zone = GetZoneText()
    if not zone or zone == "" then return end
    if zone ~= state.lastZone then
        state.lastZone = zone
        ST:RecordEvent("ZONE_CHANGED_NEW_AREA", {
            zone = zone,
            subzone = SubZone(),
            continent = Continent(),
        })
    end
    CheckInstance()
end

-- Boss kills don't reliably show up in chat; the encounter events are
-- the dependable signal.
function H.ENCOUNTER_END(encounterID, encounterName, difficultyID, groupSize, success)
    if success ~= 1 and success ~= true then return end
    ST:RecordEvent("DUNGEON_BOSS_KILLED", {
        bossName = encounterName,
        encounterID = encounterID,
        groupSize = groupSize,
        instanceName = state.instance and state.instance.name or nil,
    })
end

local function InBattleground()
    local _, instanceType = IsInInstance()
    return instanceType == "pvp"
end

-- The scoreboard knows which team the player actually fought on, which
-- differs from UnitFactionGroup in mercenary mode and cross-faction BGs.
local function PlayerTeam()
    if playerGUID and C_PvP and C_PvP.GetScoreInfoByPlayerGuid then
        local info = C_PvP.GetScoreInfoByPlayerGuid(playerGUID)
        if info and FACTION_BY_INDEX[info.faction] then
            return FACTION_BY_INDEX[info.faction]
        end
    end
    return UnitFactionGroup("player")
end

-- nil when the client can't tell us the match state.
local function MatchIsComplete()
    local complete = Enum and Enum.PvPMatchState and Enum.PvPMatchState.Complete
    if not (complete and C_PvP and C_PvP.GetActiveMatchState) then return nil end
    return C_PvP.GetActiveMatchState() == complete
end

-- Winner index from the scoreboard, or nil if the match isn't over.
local function ScoreboardWinner()
    if MatchIsComplete() == false then return nil end
    if not GetBattlefieldWinner then return nil end
    return GetBattlefieldWinner()
end

local function RecordBattlegroundResult(winner)
    if state.bgWinnerRecorded or winner == nil or not InBattleground() then return end
    state.bgWinnerRecorded = true
    local winnerName = FACTION_BY_INDEX[winner] or "Draw"
    ST:RecordEvent("PVP_BATTLEGROUND_ENDED", {
        battleground = state.instance and state.instance.name or GetZoneText(),
        winner = winnerName,
        won = winnerName == PlayerTeam(),
    })
end

-- Primary signal: fires once when the match ends, with the winning team.
function H.PVP_MATCH_COMPLETE(winner)
    RecordBattlegroundResult(winner or ScoreboardWinner())
end

-- Fallbacks in case PVP_MATCH_COMPLETE is missed (e.g. a /reload during
-- the end-of-match screen): read the result off the scoreboard.
function H.UPDATE_BATTLEFIELD_SCORE()
    RecordBattlegroundResult(ScoreboardWinner())
end

function H.UPDATE_BATTLEFIELD_STATUS(index)
    if index and GetBattlefieldStatus then
        local status = GetBattlefieldStatus(index)
        if status ~= "active" then return end
    end
    RecordBattlegroundResult(ScoreboardWinner())
end

local HONOR_PATTERN = FormatToPattern(COMBATLOG_HONORGAIN)

function H.CHAT_MSG_COMBAT_HONOR_GAIN(msg)
    local data = { text = msg }
    if HONOR_PATTERN then
        local victim, rank, honor = msg:match(HONOR_PATTERN)
        if victim then
            data.victim = victim
            data.rank = rank
            data.estimatedHonor = tonumber(honor)
            data.text = nil
        end
    end
    ST:RecordEvent("PVP_HONORABLE_KILL", data)
end

------------------------------------------------------------------------
-- Levels
------------------------------------------------------------------------

function H.PLAYER_LEVEL_UP(level, healthDelta, powerDelta, talentPoints)
    level = tonumber(level)
    ST:RecordEvent("PLAYER_LEVEL_UP", {
        level = level,
        healthGained = healthDelta,
        powerGained = powerDelta,
        talentPoints = talentPoints,
        subzone = SubZone(),
    })
    if ST.char then ST.char.level = level end
end

-- Group members' dings. There's no system message for these, so watch
-- UNIT_LEVEL on party/raid units.
function H.UNIT_LEVEL(unit)
    if not IsGroupUnit(unit) then return end
    local name = FullUnitName(unit)
    local level = UnitLevel(unit)
    if not name or not level or level <= 0 then return end
    local previous = state.unitLevels[name]
    state.unitLevels[name] = level
    if previous and level > previous then
        ST:RecordEvent("PARTY_LEVEL_UP", { name = name, level = level })
    end
end

------------------------------------------------------------------------
-- Achievements
------------------------------------------------------------------------

function H.ACHIEVEMENT_EARNED(achievementID, alreadyEarned)
    if not achievementID then return end
    local _, name, points, _, _, _, _, description, _, _, _, isGuild = GetAchievementInfo(achievementID)
    ST:RecordEvent("ACHIEVEMENT_EARNED", {
        achievementID = achievementID,
        achievementName = name,
        points = points,
        description = description,
        isGuild = isGuild or nil,
        alreadyEarned = alreadyEarned or nil,
    })
end

------------------------------------------------------------------------
-- Combat: deaths and notable kills
------------------------------------------------------------------------

-- Midnight (12.x) removed the combat log for addons. Kills are detected
-- with a unit-filtered UNIT_DIED on the target, and killers come from
-- the death recap.

-- Midnight can hand addons "secret" values that must not be stored or
-- compared; drop them rather than persisting them.
local function Plain(value)
    if issecretvalue and issecretvalue(value) then return nil end
    return value
end

local function StopWatchingTarget()
    state.notableTarget = nil
    ST.frame:UnregisterEvent("UNIT_DIED")
end

-- Watch an elite/rare/world boss the player targets so its death can be
-- recorded. Elites inside dungeons are skipped (that's just trash;
-- bosses come through ENCOUNTER_END). Only the current target is
-- watched: switching away from a notable enemy stops tracking it.
function H.PLAYER_TARGET_CHANGED()
    StopWatchingTarget()
    if not UnitExists("target") or UnitIsPlayer("target") or UnitIsDead("target") then return end
    if not UnitCanAttack("player", "target") then return end
    local classification = UnitClassification("target")
    if not NOTABLE_CLASSIFICATIONS[classification] then return end
    local inInstance = IsInInstance()
    if inInstance and classification == "elite" then return end
    local guid = Plain(UnitGUID("target"))
    if not guid then return end
    -- RegisterUnitEvent takes unit tokens, not GUIDs; the GUID is checked
    -- when the event fires. Older clients have no UNIT_DIED event.
    if not pcall(ST.frame.RegisterUnitEvent, ST.frame, "UNIT_DIED", "target") then return end
    state.notableTarget = {
        guid = guid,
        name = Plain(UnitName("target")),
        classification = classification,
        level = Plain(UnitLevel("target")),
    }
end

-- Registered per unit by PLAYER_TARGET_CHANGED, never globally.
function H.UNIT_DIED(unit)
    local notable = state.notableTarget
    if not notable then return end
    local guid = unit == notable.guid and unit or Plain(UnitGUID(unit or "target"))
    if guid ~= notable.guid then return end
    StopWatchingTarget()
    -- A tapped mob was killed by someone else's group; the combat log's
    -- "we damaged it" check is gone, so tap ownership stands in for it.
    if UnitIsTapDenied and Plain(UnitIsTapDenied(unit or "target")) then return end
    ST:RecordEvent("NOTABLE_KILL", {
        name = notable.name,
        classification = notable.classification,
        level = notable.level,
    })
end
ST.unitEvents = ST.unitEvents or {}
ST.unitEvents.UNIT_DIED = true

-- Fill killer fields from the most recent death recap. Entry 1 is the
-- killing blow; fields may be missing or secret, in which case they're
-- left out.
local function AddKillerFromRecap(data)
    if not (C_DeathRecap and C_DeathRecap.GetRecapEvents) then return end
    if C_DeathRecap.HasRecapEvents and not C_DeathRecap.HasRecapEvents() then return end
    local ok, events = pcall(C_DeathRecap.GetRecapEvents)
    local hit = ok and type(events) == "table" and events[1]
    if type(hit) ~= "table" then return end
    local subevent = Plain(hit.event)
    if subevent == "ENVIRONMENTAL_DAMAGE" then
        data.killer = "Environment"
        data.killingBlow = Plain(hit.environmentalType)
    else
        data.killer = Plain(hit.sourceName)
        data.killingBlow = Plain(hit.spellName) or (subevent == "SWING_DAMAGE" and "Melee" or nil)
    end
    data.damage = Plain(hit.amount)
end

function H.PLAYER_DEAD()
    local data = { subzone = SubZone(), level = UnitLevel("player") }
    if state.instance then
        data.instanceName = state.instance.name
    end
    ST:RecordEvent("PLAYER_DEAD", data)
    -- The recap may not be built yet when PLAYER_DEAD fires; fill the
    -- already-recorded entry in shortly after.
    if C_Timer and C_Timer.After then
        C_Timer.After(KILLER_RECAP_DELAY, function() AddKillerFromRecap(data) end)
    else
        AddKillerFromRecap(data)
    end
end

------------------------------------------------------------------------
-- Loot, gear, and collections
------------------------------------------------------------------------

local SELF_LOOT_PATTERNS = {}
for _, fmt in ipairs({
    LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_SELF,
    LOOT_ITEM_PUSHED_SELF_MULTIPLE, LOOT_ITEM_PUSHED_SELF,
    LOOT_ITEM_CREATED_SELF_MULTIPLE, LOOT_ITEM_CREATED_SELF,
}) do
    local pattern = FormatToPattern(fmt)
    if pattern then table.insert(SELF_LOOT_PATTERNS, pattern) end
end

local function ParseSelfLoot(msg)
    for _, pattern in ipairs(SELF_LOOT_PATTERNS) do
        local link, count = msg:match(pattern)
        if link then return link, tonumber(count) or 1 end
    end
    return nil
end

-- Mount items aren't recorded here: on Retail a mount is only learned
-- once the item is used, which NEW_MOUNT_ADDED reports.
function H.CHAT_MSG_LOOT(msg)
    local link, count = ParseSelfLoot(msg)
    if not link or not link:find("|Hitem:") then return end

    local quality = ItemQuality(link)
    if not quality or quality < MIN_LOOT_QUALITY then return end
    ST:RecordEvent("CHAT_MSG_LOOT", {
        itemName = ItemNameFromLink(link),
        itemID = ItemIDFromLink(link),
        itemLink = link,
        quality = quality,
        qualityName = _G["ITEM_QUALITY" .. quality .. "_DESC"],
        count = count,
    })
end

local function SnapshotEquipment()
    state.equipment = {}
    for slot in pairs(EQUIPMENT_SLOTS) do
        local link = GetInventoryItemLink("player", slot)
        state.equipment[slot] = link
        local itemID = ItemIDFromLink(link)
        if itemID then state.equippedSeen[itemID] = true end
    end
end

-- Record gear the player puts on for the first time this session; swapping
-- back and forth between known pieces (gear sets, specs) is ignored.
function H.PLAYER_EQUIPMENT_CHANGED(slot)
    local slotToken = EQUIPMENT_SLOTS[slot]
    if not slotToken then return end
    local link = GetInventoryItemLink("player", slot)
    local previous = state.equipment[slot]
    state.equipment[slot] = link
    if not link or link == previous then return end
    local itemID = ItemIDFromLink(link)
    if not itemID or state.equippedSeen[itemID] then return end
    state.equippedSeen[itemID] = true
    ST:RecordEvent("ITEM_EQUIPPED", {
        slot = slot,
        slotName = _G[slotToken] or slotToken,
        itemName = ItemNameFromLink(link),
        itemID = itemID,
        itemLink = link,
        itemLevel = ItemLevel(link),
        quality = ItemQuality(link),
        previousItemLink = previous,
    })
end

function H.NEW_MOUNT_ADDED(mountID)
    if not mountID then return end
    local name, spellID
    if C_MountJournal and C_MountJournal.GetMountInfoByID then
        name, spellID = C_MountJournal.GetMountInfoByID(mountID)
    end
    ST:RecordEvent("MOUNT_LEARNED", {
        mountName = name,
        mountID = mountID,
        spellID = spellID,
        source = "journal",
    })
end

-- Fires once per newly collected appearance source.
function H.TRANSMOG_COLLECTION_SOURCE_ADDED(sourceID)
    if not sourceID or not (C_TransmogCollection and C_TransmogCollection.GetSourceInfo) then return end
    local info = C_TransmogCollection.GetSourceInfo(sourceID)
    if not info then return end
    local link
    if C_TransmogCollection.GetAppearanceSourceInfo then
        link = select(6, C_TransmogCollection.GetAppearanceSourceInfo(sourceID))
    end
    ST:RecordEvent("TRANSMOG_COLLECTED", {
        itemName = info.name or ItemNameFromLink(link),
        itemID = info.itemID,
        itemLink = link,
        sourceID = sourceID,
        appearanceID = info.visualID,
        categoryID = info.categoryID,
        quality = info.quality,
    })
end

------------------------------------------------------------------------
-- Reputation
------------------------------------------------------------------------

local function StandingLabel(standingID)
    return _G["FACTION_STANDING_LABEL" .. tostring(standingID)]
end

-- Returns name, standingID, barValue, isHeader, hasRep for a reputation
-- list row. 11.0.2 replaced GetFactionInfo with C_Reputation.
local function FactionAt(index)
    if C_Reputation and C_Reputation.GetFactionDataByIndex then
        local data = C_Reputation.GetFactionDataByIndex(index)
        if not data then return nil end
        return data.name, data.reaction, data.currentStanding, data.isHeader, data.isHeaderWithRep
    end
    local name, _, standingID, _, _, barValue, _, _, isHeader, _, hasRep = GetFactionInfo(index)
    return name, standingID, barValue, isHeader, hasRep
end

local function NumFactions()
    if C_Reputation and C_Reputation.GetNumFactions then
        return C_Reputation.GetNumFactions()
    end
    return GetNumFactions()
end

-- Only factions under expanded headers are visible in the reputation
-- list; collapsed ones are simply not compared until expanded.
local function SnapshotFactions()
    local snapshot = {}
    for i = 1, NumFactions() do
        local name, standingID, barValue, isHeader, hasRep = FactionAt(i)
        if name and (not isHeader or hasRep) then
            snapshot[name] = { standingID = standingID, value = barValue }
        end
    end
    return snapshot
end

function H.UPDATE_FACTION()
    local current = SnapshotFactions()
    local previous = state.factions
    state.factions = current
    if not previous then return end
    for name, now in pairs(current) do
        local before = previous[name]
        if not before then
            ST:RecordEvent("UPDATE_FACTION", {
                faction = name,
                change = "discovered",
                standing = StandingLabel(now.standingID),
                standingID = now.standingID,
            })
        elseif before.standingID ~= now.standingID then
            ST:RecordEvent("UPDATE_FACTION", {
                faction = name,
                change = now.standingID > before.standingID and "increased" or "decreased",
                standing = StandingLabel(now.standingID),
                standingID = now.standingID,
                previousStanding = StandingLabel(before.standingID),
            })
        end
    end
end

------------------------------------------------------------------------
-- Professions
------------------------------------------------------------------------

local PROFESSIONS_HEADER = TRADE_SKILLS or "Professions"
local SECONDARY_HEADER = SECONDARY_SKILLS or "Secondary Skills"

local PROFESSION_HEADERS = {
    [PROFESSIONS_HEADER] = true,
    [SECONDARY_HEADER] = true,
    ["Professions"] = true,
    ["Secondary Skills"] = true,
}

-- Returns [name] = { rank, max, header }. Retail has no skill-line list,
-- only the player's profession slots.
local function SnapshotSkills()
    local snapshot = {}
    if not (GetProfessions and GetProfessionInfo) then return snapshot end
    local prof1, prof2, archaeology, fishing, cooking = GetProfessions()
    local slots = {
        { prof1, PROFESSIONS_HEADER },
        { prof2, PROFESSIONS_HEADER },
        { archaeology, SECONDARY_HEADER },
        { fishing, SECONDARY_HEADER },
        { cooking, SECONDARY_HEADER },
    }
    for _, slot in ipairs(slots) do
        local index, header = slot[1], slot[2]
        if index then
            local name, _, rank, maxRank = GetProfessionInfo(index)
            if name then
                snapshot[name] = { rank = rank, max = maxRank, header = header }
            end
        end
    end
    return snapshot
end

function H.SKILL_LINES_CHANGED()
    local current = SnapshotSkills()
    local previous = state.skills
    state.skills = current
    if not previous then return end
    for name, now in pairs(current) do
        local before = previous[name]
        local isProfession = PROFESSION_HEADERS[now.header or ""]
        if not before then
            ST:RecordEvent("SKILL_LEARNED", {
                skill = name,
                category = now.header,
                rank = now.rank,
                maxRank = now.max,
            })
        elseif isProfession and now.rank > before.rank then
            ST:RecordEvent("SKILL_LINES_CHANGED", {
                skill = name,
                rank = now.rank,
                previousRank = before.rank,
                maxRank = now.max,
            })
        elseif isProfession and now.max > before.max then
            ST:RecordEvent("SKILL_LINES_CHANGED", {
                skill = name,
                rank = now.rank,
                maxRank = now.max,
                previousMaxRank = before.max,
                change = "rank_up",
            })
        end
    end
end

------------------------------------------------------------------------
-- Gold
------------------------------------------------------------------------

function H.PLAYER_MONEY()
    local money = GetMoney()
    local previous = state.money
    state.money = money
    if not previous then return end
    local delta = money - previous
    if delta == 0 then return end

    local session = ST:CurrentSession()
    if session then
        if delta > 0 then
            session.moneyEarned = (session.moneyEarned or 0) + delta
        else
            session.moneySpent = (session.moneySpent or 0) - delta
        end
    end

    if math.abs(delta) >= MONEY_EVENT_THRESHOLD then
        ST:RecordEvent("PLAYER_MONEY", {
            delta = delta,
            total = money,
            direction = delta > 0 and "earned" or "spent",
        })
    end
end

------------------------------------------------------------------------
-- Social: guild and group
------------------------------------------------------------------------

local function CheckGuild()
    local char = ST.char
    local inGuild = IsInGuild()
    local guildName, rankName = GetGuildInfo("player")
    -- In a guild but roster not loaded yet: nothing reliable to compare.
    if inGuild and not guildName then return end
    local newGuild = inGuild and guildName or nil

    if not state.guildBaselined then
        state.guildBaselined = true
        -- Compare against what we stored last session, if we know it.
        if not char.guildKnown then
            char.guild = newGuild
            char.guildKnown = true
            return
        end
    end

    local oldGuild = char.guild
    if oldGuild == newGuild then return end
    if oldGuild then
        ST:RecordEvent("GUILD_LEFT", { guild = oldGuild })
    end
    if newGuild then
        ST:RecordEvent("GUILD_JOINED", { guild = newGuild, rank = rankName })
    end
    char.guild = newGuild
    char.guildKnown = true
end

H.GUILD_ROSTER_UPDATE = CheckGuild
H.PLAYER_GUILD_UPDATE = CheckGuild

local function GroupSnapshot()
    local kind = (IsInRaid() and "raid") or (IsInGroup() and "party") or nil
    local members = {}
    local count = 0
    if kind then
        local prefix = kind == "raid" and "raid" or "party"
        local total = kind == "raid" and GetNumGroupMembers() or GetNumSubgroupMembers()
        for i = 1, total do
            local unit = prefix .. i
            local name = FullUnitName(unit)
            if name and not UnitIsUnit(unit, "player") then
                members[name] = true
                count = count + 1
                local level = UnitLevel(unit)
                if level and level > 0 and not state.unitLevels[name] then
                    state.unitLevels[name] = level
                end
            end
        end
    end
    return { kind = kind, members = members, count = count }
end

local function SortedKeys(t)
    local list = {}
    for k in pairs(t) do table.insert(list, k) end
    table.sort(list)
    return list
end

function H.GROUP_ROSTER_UPDATE()
    local current = GroupSnapshot()
    local previous = state.group
    state.group = current
    if not previous then return end

    local joined, left = {}, {}
    for name in pairs(current.members) do
        if not previous.members[name] then joined[name] = true end
    end
    for name in pairs(previous.members) do
        if not current.members[name] then
            left[name] = true
            state.unitLevels[name] = nil
        end
    end

    local action
    if not previous.kind and current.kind then
        action = "formed"
    elseif previous.kind and not current.kind then
        action = "disbanded"
    elseif previous.kind ~= current.kind then
        action = "converted"
    elseif next(joined) or next(left) then
        action = "changed"
    end
    if not action then return end

    ST:RecordEvent("GROUP_ROSTER_UPDATE", {
        action = action,
        groupType = current.kind or previous.kind,
        size = current.count + (current.kind and 1 or 0),
        joined = next(joined) and SortedKeys(joined) or nil,
        left = next(left) and SortedKeys(left) or nil,
    })
end

------------------------------------------------------------------------
-- System messages
------------------------------------------------------------------------

local playerName = UnitName("player")

-- Mounts learned as spells also land in the mount journal, so they are
-- recorded by NEW_MOUNT_ADDED rather than here.
local function OnSpellLearned(spell, kind)
    ST:RecordEvent("SPELL_LEARNED", { spell = spell, kind = kind })
end

local function OnDuel(winner, loser, how)
    if winner ~= playerName and loser ~= playerName then return end
    ST:RecordEvent("PVP_DUEL", {
        winner = winner,
        loser = loser,
        won = winner == playerName,
        result = how,
    })
end

-- { pattern, handler(captures...) }. Built from Blizzard's localized
-- format strings so they work on non-English clients.
local SYSTEM_PATTERNS = {}
local function AddSystemPattern(fmt, fn)
    local pattern = FormatToPattern(fmt)
    if pattern then table.insert(SYSTEM_PATTERNS, { pattern, fn }) end
end

AddSystemPattern(ERR_LEARN_RECIPE_S, function(recipe)
    ST:RecordEvent("RECIPE_LEARNED", { recipe = recipe })
end)
AddSystemPattern(ERR_LEARN_SPELL_S, function(spell) OnSpellLearned(spell, "spell") end)
AddSystemPattern(ERR_LEARN_ABILITY_S, function(spell) OnSpellLearned(spell, "ability") end)
AddSystemPattern(ERR_ZONE_EXPLORED_XP, function(area, xp)
    ST:RecordEvent("ZONE_EXPLORED", { area = area, xp = tonumber(xp) })
end)
AddSystemPattern(ERR_ZONE_EXPLORED, function(area)
    ST:RecordEvent("ZONE_EXPLORED", { area = area })
end)
AddSystemPattern(INSTANCE_SAVED, function()
    ST:RecordEvent("INSTANCE_SAVED", {
        instanceName = state.instance and state.instance.name or GetZoneText(),
    })
end)
AddSystemPattern(DUEL_WINNER_KNOCKOUT, function(winner, loser) OnDuel(winner, loser, "knockout") end)
AddSystemPattern(DUEL_WINNER_RETREAT, function(loser, winner) OnDuel(winner, loser, "retreat") end)

function H.CHAT_MSG_SYSTEM(msg)
    if type(msg) ~= "string" then return end
    for _, entry in ipairs(SYSTEM_PATTERNS) do
        -- Patterns without captures return the whole match.
        local c1, c2, c3 = msg:match(entry[1])
        if c1 then
            entry[2](c1, c2, c3)
            return
        end
    end
end

------------------------------------------------------------------------
-- Baselines
------------------------------------------------------------------------

-- On login/reload, snapshot everything we diff against so the first real
-- change is recorded but the initial state is not. Loading screens
-- within a session also fire this; there we only re-check the zone.
function H.PLAYER_ENTERING_WORLD()
    playerGUID = UnitGUID("player")
    playerName = UnitName("player")

    if ST.sessionStarting then
        state.money = GetMoney()
        state.factions = SnapshotFactions()
        state.skills = SnapshotSkills()
        state.group = GroupSnapshot()
        state.lastZone = GetZoneText()
        ScanQuestLog()
        SnapshotEquipment()
        CheckGuild()
        -- Record where the session began, plus dungeon state if we logged
        -- in inside one.
        CheckInstance()
    else
        H.ZONE_CHANGED_NEW_AREA()
    end
end

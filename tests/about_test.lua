-- Plain-Lua check for /storytracker about (no WoW client needed).
-- Run from the repo root: lua tests/about_test.lua
local out = {}
print = function(s) table.insert(out, s) end -- luacheck: ignore

local frame = { RegisterEvent = function() end, UnregisterEvent = function() end, SetScript = function() end }
CreateFrame = function() return frame end
SlashCmdList = {}
C_AddOns = { GetAddOnMetadata = function(name, field)
    assert(name == "StoryTracker", "unexpected addon name " .. tostring(name))
    return ({ Version = "9.9.9", Title = "StoryTracker (Retail)", Notes = "Test notes" })[field]
end }
GetBuildInfo = function() return "12.0.1", "65000", "Oct 1 2026", 120001 end
GetLocale = function() return "enUS" end

local chunk = assert(loadfile("core.lua"))
chunk("StoryTracker", {})
SlashCmdList.STORYTRACKER("About")

local text = table.concat(out, "\n")
local function expect(s) assert(text:find(s, 1, true), "missing: " .. s .. "\n--- output ---\n" .. text) end
expect("StoryTracker (Retail)|r 9.9.9")
expect("Test notes")
expect("Made by Nine Point Labs. Created 2026-10-02.")
expect("MIT License")
expect("help@ninepointlabs.com")
expect("StoryTracker (Retail) 9.9.9, WoW 12.0.1 build 65000 (interface 120001), enUS")
expect("SavedVariables/StoryTracker.lua")
expect("No player chat is read or saved.")
assert(not text:find("Ninepoint", 1, true), "misspelled Nine Point Labs")
io.stdout:write(text, "\n\nabout_test: ok\n")

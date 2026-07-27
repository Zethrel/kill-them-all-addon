-- KillThemAll test suite. Run from the repository root:
--   lua5.1 Tests/run.lua
--
-- Lua 5.1 is required, not merely preferred: Libraries/Cerberus sandboxes every
-- file with setfenv/getfenv, which 5.4 removed.
--
-- The client stub models Midnight 12.0.7, so anything Blizzard removed is
-- absent and calling it fails here rather than in the game.

package.path = "Tests/?.lua;" .. package.path
local stub = require("wow_stub")

--------------------------------------------------------------------------------
-- Tiny test framework
--------------------------------------------------------------------------------

local passed, failed = 0, 0
local failures = {}

local function check(name, ok, detail)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		failures[#failures + 1] = name
		io.write("  FAIL  ", name, "\n")
		if detail then io.write("        ", detail, "\n") end
	end
end

local function eq(name, actual, expected)
	check(name, actual == expected,
		string.format("expected %s, got %s", tostring(expected), tostring(actual)))
end

local function ok(name, value, detail)
	check(name, value and true or false, detail)
end

local function section(title)
	io.write("\n", title, "\n")
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------

stub.install(_G)
stub.trackMissingGlobals(_G)

-- A load failure is fatal rather than a recorded failure: nothing below can
-- run, and the traceback is the useful output.
local loadOK, ns = pcall(stub.loadAddon, "KillThemAll.toc")
if not loadOK then
	io.write("FATAL: the addon did not load\n  ", tostring(ns), "\n")
	os.exit(1)
end

local bootOK, bootErr = pcall(function() return stub.login({ Version = "1.7.0" }) end)
local core = stub.coreFrame()

--------------------------------------------------------------------------------
section("Loading")
--------------------------------------------------------------------------------

ok("every file in the TOC loads", loadOK)
ok("ADDON_LOADED completes without error", bootOK, tostring(bootErr))
ok("Core.lua installs its event and update handlers", core ~= nil)
ok("Cerberus namespace exists", ns ~= nil)

-- A file on disk but absent from the TOC is not loaded by the game, even though
-- it would load fine here. The two must agree exactly.
do
	local inTOC = {}
	for _, path in ipairs(stub.loadOrder("KillThemAll.toc")) do inTOC[path] = true end

	local onDisk, missing, count = {}, {}, 0
	local pipe = io.popen("find . -name '*.lua' -not -path './.git/*' -not -path './Tests/*' -not -path './tools/*'")
	if pipe then
		for line in pipe:lines() do
			local path = line:gsub("^%./", "")
			onDisk[path] = true
			count = count + 1
			if not inTOC[path] then missing[#missing + 1] = path end
		end
		pipe:close()
	end

	local orphaned = {}
	for path in pairs(inTOC) do
		if not onDisk[path] then orphaned[#orphaned + 1] = path end
	end

	ok(count .. " Lua files on disk, all listed in the TOC", #missing == 0,
		"not in the TOC: " .. table.concat(missing, ", "))
	ok("the TOC lists no files that are missing from disk", #orphaned == 0,
		"missing from disk: " .. table.concat(orphaned, ", "))
end

--------------------------------------------------------------------------------
section("Midnight (12.0.7) compatibility")
--------------------------------------------------------------------------------

-- The three globals retail removed in 11.0. The stub does not define them, so
-- reaching one unguarded would already have failed the boot above; these assert
-- the replacements were actually used.

eq("the settings panel registers exactly one category", #stub.settingsCategories, 1)
eq("it registers under the addon's name", stub.settingsCategories[1] and stub.settingsCategories[1].name, "KillThemAll")

do
	-- Settings.OpenToCategory feeds C_SettingsUtil.OpenSettingsPanel, which
	-- wants a number. The stub raises if handed anything else.
	local opened, err = pcall(function() ns.OpenSettingsPanel() end)
	ok("OpenSettingsPanel opens the Settings category", opened, tostring(err))
	eq("it passes a numeric category ID", type(stub.openedCategories[1]), "number")
end

ok("the addon version came from C_AddOns.GetAddOnMetadata", _G.S_sAddonVersion == "1.7.0",
	"got " .. tostring(_G.S_sAddonVersion))

-- Every global the addon read that did not exist. Anything not accounted for
-- here is either a typo or an API that has been removed underneath us.
do
	local expected = {
		-- Optional global some minimap addons define; LibDBIcon guards it.
		GetMinimapShape = true,
		-- Read once by LibStub before it creates itself.
		LibStub = true,
		-- Saved variables, absent until the first save.
		S_ktaGlobalSettings = true, S_ktaCharSpecificOverrides = true,
		S_sAddonVersion = true, S_AddonVersion = true,
		-- Read by SoundLibraryBase before Cerberus.lua has run.
		g_cerberus = true,
		-- Declared as nil, so Cerberus never stores it and every read falls
		-- through to _G. Harmless, and load-bearing for the override logic.
		g_ktaCurrentCharSettingsOverrides = true,
	}

	local unexpected = {}
	for key in pairs(stub.missing) do
		if not expected[key] then unexpected[#unexpected + 1] = key end
	end
	table.sort(unexpected)

	ok("the addon reads no globals missing from 12.0.7", #unexpected == 0,
		"unexpected: " .. table.concat(unexpected, ", "))
end

--------------------------------------------------------------------------------
section("Defaults and settings")
--------------------------------------------------------------------------------

eq("one god watches by default", #ns.g_currentGods, 1)
eq("and it is Y'Shaarj", ns.g_currentGods[1] and ns.g_currentGods[1].m_sDataName, "Yshaarj")
eq("four gods are available", #ns.g_allSoundLibraries, 4)
eq("the default min delay", ns.g_ktaCurrentSettings.m_iMinDelay, 300)
eq("the default max delay", ns.g_ktaCurrentSettings.m_iMaxDelay, 1200)
eq("the default sound channel", ns.g_ktaCurrentSettings.m_sSoundChannel, "Dialog")
eq("the sound-channel dropdown offers every channel", #stub.dropdownButtons, 5)

--------------------------------------------------------------------------------
section("Playing whispers")
--------------------------------------------------------------------------------

local function soundsAfter(fn)
	local before = #stub.sounds
	fn()
	return #stub.sounds - before
end

do
	local played = soundsAfter(function() core:Fire("PLAYER_DEAD") end)
	eq("dying plays a death whisper", played, 1)

	local last = stub.sounds[#stub.sounds]
	ok("the whisper is a numeric FileDataID", type(last.file) == "number",
		"got " .. type(last.file))
	eq("and plays on the configured channel", last.channel, "Dialog")

	-- The death sound must come from the death list, not the general one.
	local deathIDs = {}
	for _, id in ipairs(ns.g_currentGods[1].m_deathSoundFilesList) do deathIDs[id] = true end
	ok("it is drawn from the death list", deathIDs[last.file] == true)

	core:Fire("PLAYER_ALIVE")
end

eq("no whisper before the delay elapses", soundsAfter(function() core:Tick(1) end), 0)
eq("a whisper once it does", soundsAfter(function() core:Tick(10000) end), 1)

do
	ns.g_ktaCurrentSettings.m_bDeactivated = true
	eq("deactivated silences whispers", soundsAfter(function() core:Tick(10000) end), 0)
	ns.g_ktaCurrentSettings.m_bDeactivated = false

	ns.g_ktaCurrentSettings.m_bMuteDuringCombat = true
	stub.inCombat = true
	eq("mute-during-combat silences whispers", soundsAfter(function() core:Tick(10000) end), 0)
	stub.inCombat = false
	ns.g_ktaCurrentSettings.m_bMuteDuringCombat = false

	core:Fire("PLAYER_DEAD")
	eq("the dead hear nothing on update", soundsAfter(function() core:Tick(10000) end), 0)
	core:Fire("PLAYER_UNGHOST")
end

--------------------------------------------------------------------------------
section("Slash commands")
--------------------------------------------------------------------------------

local function run(command)
	local success, err = pcall(function() SlashCmdList.KillThemAll(command) end)
	return success, err
end

do
	-- Regression: SetOverrideValue committed a value and then re-entered
	-- SetDelay, and its guard only stopped that when no override existed yet.
	-- The second pass always had one, so any delay differing from the saved
	-- global recursed until the stack gave out. Present in upstream 1.6.4.
	local success, err = run("setdelay 10 20")
	ok("/kta setdelay does not recurse", success, tostring(err))
	eq("it applies the new min delay", ns.g_ktaCurrentSettings.m_iMinDelay, 10)
	eq("it applies the new max delay", ns.g_ktaCurrentSettings.m_iMaxDelay, 20)

	ok("/kta setdelay rejects min >= max", run("setdelay 90 5"))
	eq("and leaves the delay alone", ns.g_ktaCurrentSettings.m_iMinDelay, 10)

	ok("/kta setgods all", run("setgods all"))
	eq("all four gods now watch", #ns.g_currentGods, 4)

	ok("/kta setgods none", run("setgods none"))
	eq("and none do", #ns.g_currentGods, 0)

	ok("/kta setgods cthun", run("setgods cthun"))
	eq("names one god", #ns.g_currentGods, 1)
	eq("the one named", ns.g_currentGods[1].m_sDataName, "Cthun")

	ok("/kta setgods with a bad name is handled", run("setgods notagod"))
	ok("/kta display", run("display"))
	ok("/kta help", run("help"))
	ok("/kta with an unknown command", run("nonsense"))
	ok("/kta setsoundchannel master", run("setsoundchannel master"))
	eq("the channel changed", ns.g_ktaCurrentSettings.m_sSoundChannel, "Master")
end

--------------------------------------------------------------------------------
section("Regressions")
--------------------------------------------------------------------------------

do
	-- TryParseSoundChannel tested an undefined `soundChannel` rather than its
	-- own `sSoundChannel` parameter, so "Default" never resolved.
	ns.g_ktaCurrentSettings.m_default.m_sSoundChannel = "Ambience"
	eq("the Default sound channel resolves",
		ns.TryParseSoundChannel("DEFAULT", "Dialog", true), "Ambience")

	eq("a known channel resolves", ns.TryParseSoundChannel("music", "Dialog", true), "Music")
	eq("an unknown channel falls back", ns.TryParseSoundChannel("nope", "Dialog", true), "Dialog")
	eq("a nil channel falls back", ns.TryParseSoundChannel(nil, "Dialog", true), "Dialog")
end

do
	-- CreateCheckButton wired the callback onto an undefined `button`.
	local fired = false
	local button = ns.CreateCheckButton("RegressionCheck", UIParent, 20,
		function() fired = true end, {})
	button:Click()
	ok("CreateCheckButton wires up its OnCheckCallback", fired)
end

do
	-- SaveDefaultVariableAsGlobal read the override off the wrong table, then
	-- reassigned an undefined `value`, wiping what it had just saved.
	ns.SetOverrideDefaultValue("m_iMinDelay", 42)
	eq("a default override is recorded", ns.g_ktaCurrentSettings.m_default.m_iMinDelay, 42)

	ns.SaveDefaultVariableAsGlobal("m_iMinDelay")
	eq("promoting it to global keeps the value", ns.g_ktaCurrentSettings.m_default.m_iMinDelay, 42)
	eq("and writes it to the global settings", _G.S_ktaGlobalSettings.m_default.m_iMinDelay, 42)
end

do
	-- SetDefaultGods read a bSilent that was never in scope, so "setgods
	-- default" always printed.
	ns.g_ktaCurrentSettings.m_default.m_sGods = "Cthun"
	local before = #stub.printed
	ns.SetGods({ "DEFAULT" }, true)
	eq("silent 'setgods default' prints nothing", #stub.printed - before, 0)
	eq("and still applies the default", ns.g_currentGods[1].m_sDataName, "Cthun")
end

--------------------------------------------------------------------------------
section("Saving")
--------------------------------------------------------------------------------

do
	local success, err = pcall(function() core:Fire("PLAYER_LOGOUT") end)
	ok("PLAYER_LOGOUT saves without error", success, tostring(err))
	ok("global settings were written", type(_G.S_ktaGlobalSettings) == "table")
	ok("character overrides were written", type(_G.S_ktaCharSpecificOverrides) == "table")
end

--------------------------------------------------------------------------------
section("TOC metadata")
--------------------------------------------------------------------------------

do
	local fields = {}
	local handle = io.open("KillThemAll.toc", "r")
	for line in handle:lines() do
		local key, value = line:match("^##%s*([%w%-]+):%s*(.-)%s*\r?$")
		if key then fields[key] = value end
	end
	handle:close()

	eq("the interface version targets Midnight", fields.Interface, "120007")
	ok("a version is declared", fields.Version ~= nil and fields.Version ~= "")
	ok("saved variables are declared", (fields.SavedVariables or ""):find("S_ktaGlobalSettings", 1, true) ~= nil)
	eq("the author credit is intact", fields.Author, "Thex")
end

--------------------------------------------------------------------------------

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then
	io.write("\nFailures:\n")
	for _, name in ipairs(failures) do io.write("  - ", name, "\n") end
	os.exit(1)
end
os.exit(0)

-- A stand-in for the WoW client, enough to load KillThemAll outside the game.
--
-- Run with: lua5.1 Tests/run.lua
--
-- Lua 5.1 specifically: Libraries/Cerberus sandboxes every file with
-- setfenv/getfenv, which 5.2 deprecated and 5.4 removed. WoW is 5.1, so this
-- is the version that matters anyway.
--
-- The stub deliberately models *Midnight 12.0.7* rather than "some WoW". Any
-- API Blizzard removed is simply absent here, so code that calls one fails the
-- suite with "attempt to call a nil value" instead of shipping. That is exactly
-- how the addon died in the first place: GetAddOnMetadata was removed in 11.0
-- and the ADDON_LOADED handler took the whole addon down with it.

local stub = {}

stub.ADDON = "KillThemAll"

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

-- SetChecked(nil) should read back as false, not nil.
local function toBool(v)
	return v and true or false
end

-- Every unknown method is a no-op returning the frame, so chained calls in the
-- addon and in LibDBIcon do not need individual stubs.
local function NewFrame(frameType, name, parent)
	local frame = {
		_type = frameType, _name = name, _parent = parent,
		_events = {}, _scripts = {}, _points = {}, _shown = true,
		_width = 100, _height = 100,
	}

	local methods = {
		RegisterEvent = function(self, event) self._events[event] = true end,
		UnregisterEvent = function(self, event) self._events[event] = nil end,
		IsEventRegistered = function(self, event) return self._events[event] == true end,

		SetScript = function(self, which, fn) self._scripts[which] = fn end,
		GetScript = function(self, which) return self._scripts[which] end,
		HookScript = function(self, which, fn) self._scripts[which] = fn end,

		SetPoint = function(self, ...) table.insert(self._points, { ... }) end,
		GetPoint = function(self) return unpack(self._points[1] or {}) end,
		ClearAllPoints = function(self) self._points = {} end,

		SetSize = function(self, w, h) self._width, self._height = w, h end,
		GetSize = function(self) return self._width, self._height end,
		GetWidth = function(self) return self._width end,
		GetHeight = function(self) return self._height end,
		SetWidth = function(self, w) self._width = w end,
		SetHeight = function(self, h) self._height = h end,
		GetCenter = function(self) return 0, 0 end,
		GetEffectiveScale = function() return 1 end,

		Show = function(self) self._shown = true end,
		Hide = function(self) self._shown = false end,
		IsShown = function(self) return self._shown end,
		IsVisible = function(self) return self._shown end,

		SetText = function(self, text) self._text = text end,
		GetText = function(self) return self._text end,
		SetNumber = function(self, n) self._text = tostring(n) end,
		GetNumber = function(self) return tonumber(self._text) or 0 end,

		SetChecked = function(self, v) self._checked = toBool(v) end,
		GetChecked = function(self) return self._checked end,

		CreateFontString = function(self) return NewFrame("FontString", nil, self) end,
		CreateTexture = function(self) return NewFrame("Texture", nil, self) end,

		GetName = function(self) return self._name end,
		GetObjectType = function(self) return self._type end,
		GetParent = function(self) return self._parent end,
		SetParent = function(self, parent) self._parent = parent end,
		GetVertexColor = function() return 1, 1, 1, 1 end,

		-- Drive a registered event handler from a test.
		Fire = function(self, event, ...)
			local handler = self._scripts.OnEvent
			if handler then handler(self, event, ...) end
		end,
		-- Drive OnUpdate with a simulated elapsed time.
		Tick = function(self, elapsed)
			local handler = self._scripts.OnUpdate
			if handler then handler(self, elapsed) end
		end,
		Click = function(self, button)
			local handler = self._scripts.OnClick
			if handler then handler(self, button or "LeftButton") end
		end,
	}

	return setmetatable(frame, {
		__index = function(t, key)
			if methods[key] then return methods[key] end
			-- Widget methods are PascalCase by convention; anything else is a
			-- data field, and an unset field on a real frame reads as nil. That
			-- distinction matters: returning a callable for every miss makes
			-- `frame.someField.x` succeed here and explode in the game.
			if type(key) == "string" and key:match("^%u") then
				return function() return t end
			end
			return nil
		end,
	})
end

--------------------------------------------------------------------------------
-- Install
--------------------------------------------------------------------------------

function stub.install(env)
	env = env or _G

	stub.frames = {}
	stub.sounds = {}          -- every PlaySoundFile call
	stub.printed = {}         -- every print()
	stub.settingsCategories = {}
	stub.openedCategories = {}
	stub.minimapObjects = {}

	env.CreateFrame = function(frameType, name, parent, template)
		local frame = NewFrame(frameType, name, parent)
		frame._template = template
		table.insert(stub.frames, frame)
		if name then env[name] = frame end
		return frame
	end

	env.UIParent = NewFrame("Frame", "UIParent")
	env.Minimap = NewFrame("Minimap", "Minimap")
	env.BackdropTemplateMixin = {}

	-- Flavour detection. Setting both makes LibDBIcon take its retail branch
	-- deliberately rather than by nil == nil coincidence.
	env.WOW_PROJECT_MAINLINE = 1
	env.WOW_PROJECT_ID = 1

	env.GameTooltip = NewFrame("GameTooltip", "GameTooltip")
	env.GameTooltip_Hide = function() end

	-- Cerberus checks the call site is a file's main chunk before it will
	-- setfenv. Real debugstack output would say so; this always does.
	env.debugstack = function() return "Tests/wow_stub.lua: in main chunk\n" end

	env.PlaySoundFile = function(file, channel)
		table.insert(stub.sounds, { file = file, channel = channel })
	end

	env.InCombatLockdown = function() return stub.inCombat == true end
	env.UnitName = function(unit) return unit == "player" and "Tester" or nil end
	env.GetRealmName = function() return "Argent Dawn" end
	env.UnitIsDeadOrGhost = function() return stub.dead == true end

	env.SlashCmdList = {}
	env.SecureCmdOptionParse = function(msg) return msg end
	env.hooksecurefunc = function() end
	env.securecall = function(fn, ...) return fn(...) end
	env.issecurevariable = function() return true end

	-- 11.0 moved the addon metadata accessors into C_AddOns. The bare
	-- GetAddOnMetadata global is intentionally NOT defined.
	env.C_AddOns = {
		GetAddOnMetadata = function(addon, field)
			if addon ~= stub.ADDON then return nil end
			return stub.tocFields and stub.tocFields[field] or nil
		end,
		IsAddOnLoaded = function() return true end,
	}

	-- 11.0 replaced InterfaceOptions_AddCategory with the Settings API. The old
	-- globals are intentionally NOT defined.
	local nextCategoryID = 0
	env.Settings = {
		RegisterCanvasLayoutCategory = function(frame, name)
			nextCategoryID = nextCategoryID + 1
			local id = nextCategoryID
			local category = {
				ID = id,
				name = name,
				frame = frame,
				GetID = function(self) return self.ID end,
				GetName = function(self) return self.name end,
			}
			return category, { AddAnchorPoint = function() end }
		end,
		RegisterAddOnCategory = function(category)
			table.insert(stub.settingsCategories, category)
		end,
		OpenToCategory = function(categoryID)
			-- C_SettingsUtil.OpenSettingsPanel takes a number. Passing the
			-- category name instead is a real and easy mistake; catch it here.
			if type(categoryID) ~= "number" then
				error("Settings.OpenToCategory expects a numeric category ID, got "
					.. type(categoryID) .. " (" .. tostring(categoryID) .. ")", 2)
			end
			table.insert(stub.openedCategories, categoryID)
		end,
	}

	-- Deprecated in favour of the Menu API, but still shipped in 12.0.7, so the
	-- sound-channel dropdown still works. Initialize runs the builder for real
	-- rather than storing it, so a broken builder fails here.
	stub.dropdownButtons = {}
	env.UIDropDownMenu_SetWidth = function(frame, width) frame._ddWidth = width end
	env.UIDropDownMenu_CreateInfo = function() return {} end
	env.UIDropDownMenu_AddButton = function(info)
		table.insert(stub.dropdownButtons, {
			text = info.text, value = info.value, checked = info.checked, func = info.func,
		})
	end
	env.UIDropDownMenu_Initialize = function(frame, initFn)
		frame._ddInit = initFn
		initFn(frame)
	end
	env.UIDropDownMenu_SetSelectedID = function(frame, id) frame._ddSelectedID = id end
	env.UIDropDownMenu_SetSelectedValue = function(frame, v) frame._ddSelectedValue = v end
	env.UIDropDownMenu_SetText = function(frame, text) frame._ddText = text end
	env.CloseDropDownMenus = function() end

	env.C_Timer = {
		After = function(_, fn) table.insert(stub.timers, fn) end,
		NewTicker = function() return { Cancel = function() end } end,
	}
	stub.timers = {}

	env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	env.strsplit = function(sep, str)
		local out = {}
		for piece in string.gmatch(str, "([^" .. sep .. "]+)") do table.insert(out, piece) end
		return unpack(out)
	end
	env.sort = table.sort
	env.tinsert = table.insert
	env.tremove = table.remove

	-- WoW exposes much of the string and math library as bare globals, and the
	-- bundled libraries lean on them heavily.
	env.strmatch, env.strfind, env.strsub = string.match, string.find, string.sub
	env.strlower, env.strupper, env.strrep = string.lower, string.upper, string.rep
	env.strlen, env.strbyte, env.strchar = string.len, string.byte, string.char
	env.format, env.gsub, env.gmatch = string.format, string.gsub, string.gmatch
	env.strtrim = function(s, chars)
		chars = chars or " \t\r\n"
		return (s:gsub("^[" .. chars .. "]+", ""):gsub("[" .. chars .. "]+$", ""))
	end
	env.strjoin = function(sep, ...) return table.concat({ ... }, sep) end
	env.max, env.min, env.abs, env.floor, env.ceil =
		math.max, math.min, math.abs, math.floor, math.ceil
	env.sqrt, env.random, env.mod = math.sqrt, math.random, math.fmod
	env.rad, env.deg, env.cos, env.sin, env.atan2 =
		math.rad, math.deg, math.cos, math.sin, math.atan2

	env.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
		table.insert(stub.printed, table.concat(parts, " "))
	end

	stub.dead = false
	stub.inCombat = false

	return env
end

--------------------------------------------------------------------------------
-- Missing-global tracking
--------------------------------------------------------------------------------
--
-- Cerberus resolves every global the addon touches through _G, and a global
-- that does not exist quietly reads as nil -- which is how a removed API turns
-- into a silent misbehaviour rather than a loud error. Recording those reads
-- turns the compatibility audit into something the suite can assert on.

function stub.trackMissingGlobals(env)
	env = env or _G
	stub.missing = {}
	setmetatable(env, {
		__index = function(_, key)
			if type(key) == "string" then
				stub.missing[key] = (stub.missing[key] or 0) + 1
			end
			return nil
		end,
	})
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------

-- Read the load order straight out of the TOC, expanding the XML files to the
-- Lua they pull in. Deriving it rather than restating it means the suite can
-- never drift from what the game actually loads.
function stub.loadOrder(tocPath)
	local files = {}

	local function addXML(xmlPath)
		local dir = xmlPath:match("^(.*)/[^/]+$") or "."
		local handle = assert(io.open(xmlPath, "r"), "cannot open " .. xmlPath)
		for line in handle:lines() do
			local script = line:match('<Script%s+file="([^"]+)"')
			if script then
				table.insert(files, dir .. "/" .. (script:gsub("\\", "/")))
			end
		end
		handle:close()
	end

	local handle = assert(io.open(tocPath, "r"), "cannot open " .. tocPath)
	for line in handle:lines() do
		line = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
		if line ~= "" and line:sub(1, 1) ~= "#" then
			local path = line:gsub("\\", "/")
			if path:match("%.xml$") then
				addXML(path)
			elseif path:match("%.lua$") then
				table.insert(files, path)
			end
		end
	end
	handle:close()

	return files
end

-- Load every file in TOC order. Returns the Cerberus namespace, which is where
-- the addon's "globals" actually live.
function stub.loadAddon(tocPath)
	for _, path in ipairs(stub.loadOrder(tocPath or "KillThemAll.toc")) do
		local chunk, err = loadfile(path)
		if not chunk then
			error("failed to load " .. path .. ": " .. tostring(err))
		end
		local ok, runErr = pcall(chunk)
		if not ok then
			error("error running " .. path .. ": " .. tostring(runErr))
		end
	end

	local ns = _G.g_cerberus and _G.g_cerberus[stub.ADDON]
	if not ns then
		error("Cerberus namespace missing after load; did SoundLibraryBase register?")
	end
	return ns
end

-- The frame Core.lua drives the addon from: the one with both handlers.
function stub.coreFrame()
	for _, frame in ipairs(stub.frames) do
		if frame._scripts.OnEvent and frame._scripts.OnUpdate then return frame end
	end
	return nil
end

-- Bring the addon up the way the client does.
function stub.login(tocFields)
	stub.tocFields = tocFields or { Version = "1.7.0" }
	local frame = stub.coreFrame()
	if not frame then error("no core frame found; Core.lua did not set up its handlers") end
	frame:Fire("ADDON_LOADED", stub.ADDON)
	return frame
end

return stub

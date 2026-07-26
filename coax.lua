--------------------------------------------------------------------------------
-- Coax remote — the dispatcher
--
-- One command table (M.run) behind three front ends:
--   web  : coaxweb.lua serves the phone remote + a JSON API
--   cli  : `coax full`, `coax ch 113` -> bin/coax -> hs -c 'coax.run(...)'
--   file : `echo full > /tmp/coax_cmd`, watched with hs.pathwatcher
--
-- Coax is driven through its menu bar (hs.application:selectMenuItem) rather
-- than keystrokes wherever a menu item exists — the menus are the only stable
-- handle on the app, since its window is a single Metal-drawn view with no
-- accessible controls. Channel menu titles embed the programme that is on right
-- now ("CH 113: Horror - Nope (6:45PM-9PM)"), so they go stale: every lookup can
-- refetch and retry once.
--
-- Usage from your ~/.hammerspoon/init.lua:
--     coax = require("coax").start()
--------------------------------------------------------------------------------

local BUNDLE   = "com.out-to-lunch.PlexOVision"
local CMD_FILE = "/tmp/coax_cmd"
local LOG_FILE = "/tmp/coax_log"
local SETTLE   = 0.2  -- seconds to let Coax come forward before driving it

-- Every submenu under Watch that holds channels.
local CATEGORIES = { "Genre", "Studio", "Decades", "Recents", "Director",
                     "Collections", "Actors", "Now Playing", "Weather" }

-- Loaded up front so the `hs` CLI doesn't print "-- Loading extension: …" into
-- the reply the phone is about to read.
require("hs.application"); require("hs.audiodevice"); require("hs.eventtap")
require("hs.alert"); require("hs.timer"); require("hs.pathwatcher")

local M = {}

local function log(line)
    local f = io.open(LOG_FILE, "a")
    if f then f:write(os.date("%F %T ") .. line .. "\n"); f:close() end
end

--------------------------------------------------------------------------------
-- app handle
--------------------------------------------------------------------------------

-- Returns Coax, launching and focusing it if needed. `noLaunch` asks about the
-- app without starting it (used by status).
local function app(noLaunch)
    local a = hs.application.get(BUNDLE)
    if not a then
        if noLaunch then return nil end
        hs.application.launchOrFocusByBundleID(BUNDLE)
        for _ = 1, 40 do                     -- up to 10s for a cold launch
            hs.timer.usleep(250000)
            a = hs.application.get(BUNDLE)
            if a then break end
        end
    end
    if not a then return nil end
    if not noLaunch and not a:isFrontmost() then
        a:activate()
        hs.timer.usleep(SETTLE * 1e6)
    end
    return a
end

--------------------------------------------------------------------------------
-- menu plumbing
--------------------------------------------------------------------------------

-- getMenuItems() walks every channel submenu, so cache it for the life of one
-- command instead of paying for it per lookup.
local menuCache, menuCacheAt = nil, 0

local function menus(a, fresh)
    local now = hs.timer.secondsSinceEpoch()
    if fresh or not menuCache or (now - menuCacheAt) > 5 then
        menuCache, menuCacheAt = a:getMenuItems() or {}, now
    end
    return menuCache
end

-- Items under a menu path, e.g. children(a, {"Watch", "Genre"}).
local function children(a, path, fresh)
    local list = menus(a, fresh)
    for _, want in ipairs(path) do
        local hit
        for _, item in ipairs(list or {}) do
            if item.AXTitle == want then hit = item; break end
        end
        if not hit or not hit.AXChildren then return nil end
        list = hit.AXChildren[1]
    end
    return list
end

-- Flat channel list: { num, name, now, title, cat }, sorted by channel number.
local function channels(a, fresh)
    local out = {}
    for _, cat in ipairs(CATEGORIES) do
        for _, item in ipairs(children(a, { "Watch", cat }, fresh) or {}) do
            local num, rest = (item.AXTitle or ""):match("^CH (%d+):%s*(.*)$")
            if num then
                local name = rest:match("^(.-)%s+%-%s+") or rest
                out[#out + 1] = { num = tonumber(num), name = name, cat = cat,
                                  now = rest:sub(#name + 4), title = item.AXTitle }
            end
        end
        fresh = false  -- one refetch covers every category
    end
    table.sort(out, function(x, y) return x.num < y.num end)
    return out
end

-- Tune to the first channel `match` accepts. Retries once against fresh menus,
-- because a title captured a minute ago may name the previous programme.
local function tune(a, match, fresh)
    for _, c in ipairs(channels(a, fresh)) do
        if match(c) then
            if a:selectMenuItem({ "Watch", c.cat, c.title }) then return c end
            break
        end
    end
    if not fresh then return tune(a, match, true) end
    return nil
end

local function describe(c)
    return string.format("CH %d: %s — %s", c.num, c.name, c.now)
end

--------------------------------------------------------------------------------
-- individual actions
--------------------------------------------------------------------------------

-- The View menu carries exactly one of Enter/Exit Full Screen, which is also how
-- we read the current state. `want` = true / false / nil (toggle).
local function fullScreen(a, want)
    local isFull = a:findMenuItem({ "View", "Exit Full Screen" }) ~= nil
    if want == nil then want = not isFull end
    if want ~= isFull then
        a:selectMenuItem({ "View", want and "Enter Full Screen" or "Exit Full Screen" })
    end
    return want and "full screen" or "windowed"
end

local function theme(a, want)
    local items = children(a, { "View", "Theme" }, true) or {}
    local current
    for _, i in ipairs(items) do
        if (i.AXMenuItemMarkChar or "") ~= "" then current = i.AXTitle end
    end
    if not want then want = (current == "Retro") and "Modern" or "Retro" end
    want = want:sub(1, 1):upper() .. want:sub(2):lower()
    if want ~= current then a:selectMenuItem({ "View", "Theme", want }) end
    return "theme " .. want:lower()
end

-- Coax puts the current channel in its window title ("CH 113: Horror"). The
-- on-screen banner says the same thing, but only while windowed, so the title is
-- the one reading that survives full screen.
local function nowPlaying(a)
    for _, w in ipairs(a:allWindows()) do
        local t = w:title()
        if type(t) == "string" and t:match("^CH %d+") then return t end
    end
end

-- A set on HDMI/DisplayPort — the Hisense this Mac drives — owns its own mixer:
-- macOS reports nil for volume and mute and silently drops any set. Say so,
-- rather than reporting back the number we just made up. Switch the output to
-- the MacBook speakers and these come alive on their own.
local function noSoftwareVolume(dev)
    return string.format("%s controls its own volume — use the TV remote", dev:name())
end

local function volume(arg)
    local dev = hs.audiodevice.defaultOutputDevice()
    if not dev then return "no audio output device" end
    local cur = dev:outputVolume()
    if not cur then return noSoftwareVolume(dev) end

    local new
    if arg == "up" or arg == "+" then new = cur + 10
    elseif arg == "down" or arg == "-" then new = cur - 10
    elseif tonumber(arg) then new = tonumber(arg)
    else return string.format("volume %d%%", math.floor(cur + 0.5)) end

    new = math.max(0, math.min(100, new))
    dev:setOutputVolume(new)
    if new > 0 and dev:outputMuted() then dev:setOutputMuted(false) end

    -- Read it back: the device gets the last word, not our arithmetic.
    return string.format("volume %d%%", math.floor((dev:outputVolume() or new) + 0.5))
end

local function mute()
    local dev = hs.audiodevice.defaultOutputDevice()
    if not dev then return "no audio output device" end
    local muted = dev:outputMuted()
    if muted == nil then return noSoftwareVolume(dev) end
    dev:setOutputMuted(not muted)
    return (not muted) and "muted" or "unmuted"
end

-- Match a category the way it would be typed from a phone: "nowplaying", "now
-- playing" and "now" should all land.
local function matchCategory(arg)
    if not arg or arg == "" then return nil end
    local want = arg:lower():gsub("%s+", "")
    for _, cat in ipairs(CATEGORIES) do
        if cat:lower():gsub("%s+", "") == want then return cat end
    end
    for _, cat in ipairs(CATEGORIES) do
        if cat:lower():gsub("%s+", ""):find(want, 1, true) then return cat end
    end
    return nil
end

--------------------------------------------------------------------------------
-- command table
--------------------------------------------------------------------------------

local H = {}

H["u"] = function() hs.eventtap.keyStroke({}, "up");   return "channel up" end
H["d"] = function() hs.eventtap.keyStroke({}, "down"); return "channel down" end

H["full"] = function(a, arg)
    local want = nil
    if arg == "on" or arg == "1" then want = true end
    if arg == "off" or arg == "0" then want = false end
    return fullScreen(a, want)
end

H["ch"] = function(a, arg)
    local n = tonumber(arg)
    if not n then return "usage: ch <number>" end
    local c = tune(a, function(x) return x.num == n end)
    return c and describe(c) or ("no channel " .. n)
end

H["find"] = function(a, arg)
    if arg == "" then return "usage: find <text>" end
    local needle = arg:lower()
    local c = tune(a, function(x) return x.title:lower():find(needle, 1, true) ~= nil end)
    return c and describe(c) or ("nothing matching '" .. arg .. "'")
end

H["chaos"] = function(a, arg)
    local cat = matchCategory(arg)
    if arg ~= "" and not cat then return "unknown category '" .. arg .. "'" end
    -- Skip whatever is already on: a shuffle that lands where you started
    -- reads as a broken button.
    local current = tonumber((nowPlaying(a) or ""):match("^CH (%d+)") or "")
    local pool = {}
    for _, c in ipairs(channels(a)) do
        if (not cat or c.cat == cat) and c.num ~= current then pool[#pool + 1] = c end
    end
    if #pool == 0 then return "no channels found" end
    local pick = pool[math.random(#pool)]
    local c = tune(a, function(x) return x.num == pick.num end)
    return c and ("chaos → " .. describe(c)) or "could not tune"
end

H["cat"] = function(a, arg)
    local cat = matchCategory(arg)
    if not cat then return "usage: cat <" .. table.concat(CATEGORIES, "|"):lower() .. ">" end
    local c = tune(a, function(x) return x.cat == cat end)
    return c and describe(c) or ("no channels under " .. cat)
end

-- The one-of-a-kind channels get their own verbs, so a Shortcut can just say
-- "weather" and the remote can give them a button each.
H["weather"] = function(a) return H["cat"](a, "Weather") end
H["whatson"] = function(a) return H["cat"](a, "Now Playing") end
H["recent"]  = function(a) return H["cat"](a, "Recents") end

H["theme"] = function(a, arg) return theme(a, arg ~= "" and arg or nil) end

H["wt"] = function(a)
    return a:selectMenuItem({ "Watch", "Watch Together" }) and "watch together" or "unavailable"
end

H["multi"] = function(a)
    return a:selectMenuItem({ "View", "Multi-Window" }) and "multi-window" or "unavailable"
end

H["vol"]  = function(_, arg) return volume(arg ~= "" and arg or nil) end
H["mute"] = function() return mute() end

H["open"] = function(a) return a and "Coax is up" or "could not launch Coax" end

H["quit"] = function(a) a:kill(); return "Coax quit" end

H["screenoff"] = function() hs.execute("pmset displaysleepnow"); return "display off" end

H["status"] = function()
    local s = M.state()
    if not s.running then return "Coax is not running" end
    local bits = { s.channel or "no channel playing", s.full and "full screen" or "windowed" }
    if not s.canVolume then
        bits[#bits + 1] = (s.device or "output") .. " volume"
    elseif s.muted then
        bits[#bits + 1] = "muted"
    else
        bits[#bits + 1] = string.format("vol %d%%", s.volume)
    end
    return table.concat(bits, " | ")
end

H["list"] = function(a, arg)
    local cat = matchCategory(arg)
    if arg ~= "" and not cat then return "unknown category '" .. arg .. "'" end
    local lines = {}
    for _, c in ipairs(channels(a)) do
        if not cat or c.cat == cat then
            lines[#lines + 1] = string.format("%d  %s (%s)", c.num, c.name, c.cat)
        end
    end
    return #lines > 0 and table.concat(lines, "\n") or "no channels found"
end

H["help"] = function()
    return table.concat({
        "u | d                channel up / down",
        "full [on|off]        toggle full screen",
        "ch <n>               tune to channel n",
        "find <text>          tune to first channel matching text",
        "chaos [category]     random channel (optionally within a category)",
        "cat <category>       first channel of a category",
        "weather | whatson | recent   the one-off channels",
        "list [category]      list channels",
        "theme [retro|modern] switch theme",
        "wt                   Watch Together",
        "multi                Multi-Window",
        "vol <up|down|0-100>  set volume     mute   toggle mute",
        "status               what's playing, full screen state, volume",
        "open | quit          launch / quit Coax",
        "screenoff            put the display to sleep",
        "categories: " .. table.concat(CATEGORIES, ", "),
    }, "\n")
end

-- Spellings a Shortcut (or a tired thumb) might send, mapped to canonical verbs.
local ALIAS = {
    up = "u", ["ch+"] = "u", chup = "u", next = "u", ["+"] = "u",
    down = "d", ["ch-"] = "d", chdown = "d", prev = "d", ["-"] = "d",
    fs = "full", fullscreen = "full",
    shuffle = "chaos", random = "chaos",
    tune = "ch", channel = "ch",
    search = "find",
    category = "cat", genre = "cat",
    together = "wt", watchtogether = "wt",
    volume = "vol",
    meteo = "weather", forecast = "weather",
    now = "whatson", nowplaying = "whatson", onnow = "whatson",
    recents = "recent", new = "recent",
    guide = "list", channels = "list",
    launch = "open", power = "quit",
    sleep = "screenoff", display = "screenoff",
    ["?"] = "help", h = "help", stat = "status",
}

--------------------------------------------------------------------------------
-- structured accessors (the web remote wants data, not sentences)
--------------------------------------------------------------------------------

-- Neither of these focuses Coax: polling for status shouldn't yank the app
-- forward while you're using the Mac for something else.

function M.state()
    local a = app(true)
    if not a then return { running = false } end
    local dev = hs.audiodevice.defaultOutputDevice()
    local level = dev and dev:outputVolume()
    local channel = nowPlaying(a)
    local num, name = (channel or ""):match("^CH (%d+):%s*(.*)$")
    return {
        running   = true,
        channel   = channel,
        num       = tonumber(num),
        name      = name,
        full      = a:findMenuItem({ "View", "Exit Full Screen" }) ~= nil,
        device    = dev and dev:name() or nil,
        -- nil, not 0: an HDMI set has no software volume at all, and the remote
        -- greys its volume keys out rather than pretending they do something.
        volume    = level and math.floor(level + 0.5) or nil,
        muted     = dev and dev:outputMuted() or false,
        canVolume = level ~= nil,
    }
end

function M.channels(fresh)
    local a = app(true)
    if not a then return {} end
    local out = {}
    for _, c in ipairs(channels(a, fresh)) do
        out[#out + 1] = { num = c.num, name = c.name, cat = c.cat, now = c.now }
    end
    return out
end

--------------------------------------------------------------------------------
-- entry point
--------------------------------------------------------------------------------

-- Runs one command line ("ch 113", "full off"). Always returns a string: the
-- CLI prints it straight back to the phone.
function M.run(line)
    line = tostring(line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return "" end

    local verb, arg = line:match("^(%S+)%s*(.*)$")
    verb = ALIAS[verb:lower()] or verb:lower()
    local handler = H[verb]
    if not handler then
        return "unknown command '" .. verb .. "' — try: help"
    end

    -- status must not resurrect a quit app; everything else launches on demand.
    local a = app(verb == "status")
    if not a and verb ~= "status" then return "could not reach Coax" end

    local ok, result = pcall(handler, a, arg)
    if not ok then
        log("ERROR " .. line .. ": " .. tostring(result))
        return "error: " .. tostring(result)
    end
    result = tostring(result)
    log(line .. " -> " .. result:gsub("\n", " / "):sub(1, 120))
    if verb ~= "list" then hs.alert.show(result, 0.8) end
    return result
end

--------------------------------------------------------------------------------
-- file front end (the original iPhone Shortcuts write here)
--------------------------------------------------------------------------------

local function handleCmd()
    local f = io.open(CMD_FILE, "r"); if not f then return end
    local line = (f:read("*a") or ""):gsub("^%s+", ""):gsub("%s+$", ""); f:close()
    if line == "" then return end
    local w = io.open(CMD_FILE, "w"); if w then w:close() end  -- consume, then act
    M.run(line)
end

-- Starts the file watcher and the web front end. Returns the module so a config
-- can do:  coax = require("coax").start()
function M.start(opts)
    opts = opts or {}
    M.watcher = hs.pathwatcher.new(CMD_FILE, handleCmd):start()
    math.randomseed(math.floor(hs.timer.secondsSinceEpoch() * 1000))
    require("hs.ipc")                        -- lets bin/coax reach this config
    if opts.web ~= false then
        M.web = require("coaxweb").start(M, opts)
    end
    if opts.alert ~= false then hs.alert.show("Coax remote loaded") end
    return M
end

return M

--------------------------------------------------------------------------------
-- Coax remote — web front end
--
-- Serves the phone remote (coax-remote.html) and a small JSON API on top of the
-- same dispatcher the CLI and the file watcher use.
--
--   GET /              the remote, as a Home Screen web app
--   GET /api/status    { running, channel, num, name, full, volume, muted, … }
--   GET /api/guide     [ { num, name, cat, now }, … ]
--   GET /api/cmd?c=…   runs one command, returns { reply, state }
--
-- SECURITY, because this hands anyone who reaches it control of your Mac:
--   * Every route needs the token, as `?t=` or an `X-Coax-Token` header. It is
--     generated on first run into <hs.configdir>/coax-token, chmod 600, and it
--     never expires — the Home Screen bookmark keeps working.
--   * The page drops the token into localStorage and strips it back out of the
--     address bar, so it doesn't survive in browser history or in a screenshot.
--   * Requests whose Host header is a real domain are refused: a browser only
--     ever reaches this over an IP, localhost, .local or a tailnet name, so a
--     domain means someone pointed DNS at your machine to get same-origin
--     access to the API (DNS rebinding).
--   * It is plain HTTP on your LAN. Anyone already sniffing that segment can
--     read the token. Treat it as house-key-grade, not password-grade.
--------------------------------------------------------------------------------

local M = {}

local DEFAULT_PORT = 8765

-- Resolve assets next to this file, so the repo can live wherever you cloned it.
local HERE  = (debug.getinfo(1, "S").source:match("^@(.*/)") or "./")
local PAGE  = HERE .. "coax-remote.html"
-- The token is config, not code: keep it out of the checkout.
local TOKEN = (hs.configdir or os.getenv("HOME") .. "/.hammerspoon") .. "/coax-token"

--------------------------------------------------------------------------------

local function token()
    local f = io.open(TOKEN, "r")
    if f then
        local t = (f:read("*a") or ""):gsub("%s+", ""); f:close()
        if t ~= "" then return t end
    end
    local t = hs.execute("openssl rand -hex 16"):gsub("%s+", "")
    local w = io.open(TOKEN, "w")
    if w then w:write(t); w:close(); hs.execute("chmod 600 '" .. TOKEN .. "'") end
    return t
end

-- Compare without bailing out on the first wrong byte. The timing signal is
-- tiny over a LAN, but there's no reason to hand it over.
local function sameToken(given, want)
    if type(given) ~= "string" or #given ~= #want then return false end
    local diff = 0
    for i = 1, #want do
        diff = diff | (given:byte(i) ~ want:byte(i))
    end
    return diff == 0
end

-- A browser reaches a machine like this by address, not by name. A real domain
-- in the Host header means DNS was pointed here deliberately.
local function hostAllowed(host)
    host = (host or ""):gsub("%s", ""):gsub(":%d+$", ""):gsub("^%[(.*)%]$", "%1"):lower()
    if host == "" then return false end
    if host == "localhost" or host == "::1" then return true end
    if host:match("^%d+%.%d+%.%d+%.%d+$") then return true end   -- IPv4 literal
    if host:match("^[%x:]+$") and host:find(":") then return true end  -- IPv6 literal
    if host:match("%.local$") or host:match("%.ts%.net$") then return true end
    for _, extra in ipairs(M.extraHosts or {}) do
        if host == extra:lower() then return true end
    end
    return false
end

local function unescape(s)
    return (s:gsub("+", " "):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function query(path)
    local q = {}
    for k, v in (path:match("%?(.*)$") or ""):gmatch("([^&=]+)=?([^&]*)") do
        q[unescape(k)] = unescape(v)
    end
    return q
end

local function json(body, status)
    return hs.json.encode(body), status or 200,
           { ["Content-Type"] = "application/json; charset=utf-8",
             ["Cache-Control"] = "no-store" }
end

local function header(headers, name)
    for k, v in pairs(headers or {}) do
        if k:lower() == name then return v end
    end
end

--------------------------------------------------------------------------------

local function handler(method, path, headers, body)
    local route = path:match("^([^?]*)") or "/"
    local q     = query(path)

    if not hostAllowed(header(headers, "host")) then
        return json({ error = "host not allowed" }, 403)
    end
    if not sameToken(header(headers, "x-coax-token") or q.t, M.token) then
        return json({ error = "bad or missing token" }, 403)
    end

    if route == "/" or route == "/index.html" then
        local f = io.open(PAGE, "r")
        if not f then return "coax-remote.html is missing", 500, {} end
        local html = f:read("*a"); f:close()
        return html, 200, { ["Content-Type"] = "text/html; charset=utf-8",
                            ["Cache-Control"] = "no-store",
                            ["Referrer-Policy"] = "no-referrer" }
    end

    if route == "/api/status" then
        return json(M.coax.state())
    end

    if route == "/api/guide" then
        return json(M.coax.channels(q.fresh == "1"))
    end

    if route == "/api/cmd" then
        local cmd = q.c or ""
        if cmd == "" then return json({ error = "no command" }, 400) end
        local reply = M.coax.run(cmd)
        -- The UI repaints from this, so don't make it ask twice.
        return json({ reply = reply, state = M.coax.state() })
    end

    return json({ error = "no such route" }, 404)
end

--------------------------------------------------------------------------------

-- coax: the dispatcher module. opts.port, opts.interface ("localhost" to keep it
-- on this machine only), opts.extraHosts (hostnames you reach it by).
function M.start(coax, opts)
    opts = opts or {}
    M.coax       = coax or _G.coax
    M.port       = opts.port or DEFAULT_PORT
    M.extraHosts = opts.extraHosts
    M.token      = token()

    if M.server then M.server:stop() end
    M.server = hs.httpserver.new(false, false):setPort(M.port):setCallback(handler)
    if opts.interface then M.server:setInterface(opts.interface) end
    M.server:start()
    return M
end

function M.url(host)
    return string.format("http://%s:%d/?t=%s", host or "your-mac.local",
                         M.port or DEFAULT_PORT, M.token)
end

return M

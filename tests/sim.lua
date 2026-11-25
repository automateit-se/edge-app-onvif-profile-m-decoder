-- The simulated edge client used by the tests: cfg, app, log, json, lynx, mq and the clock.
-- All names, serial numbers and ids are made up.

local S = {}

S.json = { null = setmetatable({}, { __tostring = function() return "null" end }) }
function S.json:encode(v)
  local t = type(v)
  if t == "nil" or v == S.json.null then return "null" end
  if t == "boolean" or t == "number" then return tostring(v) end
  if t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"' end
  if #v > 0 then
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = S.json:encode(x) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys, parts = {}, {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do parts[#parts + 1] = S.json:encode(tostring(k)) .. ":" .. S.json:encode(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end
function S.json:decode(s) -- a small but real JSON decoder
  local i = 1
  local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
  local value
  local function str()
    local out = {}
    i = i + 1
    while true do
      local c = s:sub(i, i)
      if c == "" then error("unterminated string") end
      if c == '"' then i = i + 1 break end
      if c == "\\" then
        local n = s:sub(i + 1, i + 1)
        if n == "u" then out[#out + 1] = utf8.char(tonumber(s:sub(i + 2, i + 5), 16)) i = i + 6
        else out[#out + 1] = ({ n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" })[n] or n i = i + 2 end
      else out[#out + 1] = c i = i + 1 end
    end
    return table.concat(out)
  end
  function value()
    ws()
    local c = s:sub(i, i)
    if c == "{" then
      local t = {}
      i = i + 1 ws()
      if s:sub(i, i) == "}" then i = i + 1 return t end
      while true do
        ws() local k = str() ws() i = i + 1
        t[k] = value() ws()
        local d = s:sub(i, i) i = i + 1
        if d == "}" then return t end
        if d ~= "," then error("bad object") end
      end
    elseif c == "[" then
      local t = {}
      i = i + 1 ws()
      if s:sub(i, i) == "]" then i = i + 1 return t end
      while true do
        t[#t + 1] = value() ws()
        local d = s:sub(i, i) i = i + 1
        if d == "]" then return t end
        if d ~= "," then error("bad array") end
      end
    elseif c == '"' then return str()
    elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
    elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
    elseif s:sub(i, i + 3) == "null" then i = i + 4 return S.json.null
    else
      local n = s:match("^-?[%d%.eE+-]+", i)
      if not n then error("bad JSON at " .. i) end
      i = i + #n
      return tonumber(n)
    end
  end
  return value()
end

S.T0 = 1795600000

--- Loads app.lua in a simulated edge client. opts: cfg, devices, functions, create_fails.
function S.load_app(opts)
  opts = opts or {}
  local sim = { created = {}, created_devices = {}, published = {}, logs = {}, handlers = {}, clock = S.T0 }
  local fns, devs = {}, {}
  for _, f in ipairs(opts.functions or {}) do fns[#fns + 1] = f end
  for _, d in ipairs(opts.devices or {}) do devs[#devs + 1] = d end
  local function match(item, filter)
    for k, v in pairs(filter or {}) do
      if k == "type" then if item.type ~= v then return false end
      elseif (item.meta or {})[k] ~= v then return false end
    end
    return true
  end
  local next_id = 5000
  local lynx = {
    getFunctions = function(filter)
      local out = {}
      for _, f in ipairs(fns) do if match(f, filter) then out[#out + 1] = f end end
      return out
    end,
    getDevices = function() return devs end,
    createFunction = function(f)
      if opts.create_fails and opts.create_fails(sim) then error("no connection") end
      next_id = next_id + 1
      f.id = next_id
      fns[#fns + 1] = f
      sim.created[#sim.created + 1] = f
      return f
    end,
    apiCall = function(method, path, body)
      sim.api = sim.api or {}
      sim.api[#sim.api + 1] = { method = method, path = path, body = body }
      local fid = path:match("^/api/v2/functionx/%d+/(%d+)$")
      if method == "PUT" and fid then
        for _, f in ipairs(fns) do if f.id == tonumber(fid) then f.meta = body.meta end end
        return body
      end
      error("unexpected call " .. method .. " " .. path)
    end,
    createDevice = function(d)
      next_id = next_id + 1
      d.id = next_id
      devs[#devs + 1] = d
      sim.created_devices[#sim.created_devices + 1] = d
      return d
    end,
  }
  local mq = {}
  function mq:sub(topic) sim.subscribed = topic end
  function mq:bind(topic, fn) sim.handlers[topic] = fn end
  function mq:pub(topic, payload, retain)
    sim.published[#sim.published + 1] = { topic = topic, payload = payload, retain = retain }
  end
  local function logger(level) return function(f, ...) sim.logs[#sim.logs + 1] = level .. " " .. string.format(f, ...) end end
  local os_fake = setmetatable({ time = function() return sim.clock end }, { __index = os })
  local env = setmetatable({
    MULTISENSOR_TEST = true,
    cfg = opts.cfg or {},
    app = { id = 5, installation_id = 1001, name = "App" },
    json = S.json, lynx = lynx, mq = mq, os = os_fake,
    log = { i = logger("I"), e = logger("E"), d = logger("D") },
  }, { __index = _G })
  local M = assert(loadfile("app.lua", "t", env))()
  env.onStart()
  function sim.send(topic, payload)
    local h = sim.handlers["obj/+/+/onvif-ej/#"]
    assert(h, "not bound")
    h(topic, payload)
  end
  function sim.pubs(topic)
    local out = {}
    for _, p in ipairs(sim.published) do if p.topic == topic then out[#out + 1] = S.json:decode(p.payload) end end
    return out
  end
  function sim.last(topic) local p = sim.pubs(topic) return p[#p] end
  function sim.fn(name) for _, f in ipairs(fns) do if f.meta.name == name then return f end end end
  return M, env, sim
end

return S

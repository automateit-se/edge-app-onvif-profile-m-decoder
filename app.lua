-- Bosch AI camera -> IoT Open.
--
-- Bosch cameras (firmware 9.x) can publish their ONVIF events as JSON over MQTT, on topics like
--   obj/bosch/<serial>/onvif-ej/RuleEngine/LineDetector/Crossed/&1/<rule name>
-- This app turns every rule into IoT Open functions on one device per camera:
--   <rule>              the event itself: the count (counter rules), 1/0 (state rules) or 1 per event
--   <rule> hastighet    the speed of the object that triggered the rule (the camera sends m/s; km/h by default)
--   <rule> objekttyp    the class of that object (person, car, bike ...), the name in msg
--   <rule> sannolikhet  how sure the camera is of the class (%), off by default
--   <rule> <attribute>  any other number the camera adds to the event (new firmware, other rules)
-- Functions made by IoT Open's edge-app-bosch-ai-sensor (type counter, meta bosch_name) are found and used again.

local M = {}

-- ---- settings ------------------------------------------------------------------------------------------------------

local function setting(name, default)
  local c = (type(cfg) == "table") and cfg or {}
  local v = c[name]
  if v == nil or v == "" then return default end
  return v
end

local function enabled(attr)
  local list = setting("attributes", { "speed", "class", "extra" })
  if type(list) ~= "table" then return false end
  for _, v in ipairs(list) do if v == attr then return true end end
  return false
end

-- ---- small helpers -------------------------------------------------------------------------------------------------

function M.split(s, sep)
  local out, i = {}, 1
  while true do
    local j = s:find(sep, i, true)
    if not j then out[#out + 1] = s:sub(i) return out end
    out[#out + 1] = s:sub(i, j - 1)
    i = j + #sep
  end
end

local function num(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then return tonumber(v) end
  return nil
end

local function bool(v)
  if v == true or v == "true" or v == 1 or v == "1" then return true end
  if v == false or v == "false" or v == 0 or v == "0" then return false end
  return nil
end

--- Seconds since 1970 for an ISO time in UTC (2026-11-25T14:08:36.510Z), with the fraction kept.
function M.utc(s)
  if type(s) ~= "string" then return nil end
  local y, mo, d, h, mi, sec = s:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):([%d%.]+)")
  if not y then return nil end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
  -- days from civil (proleptic Gregorian), so the edge client's local time zone does not matter
  y = (mo <= 2) and (y - 1) or y
  local era = (y >= 0 and y or y - 399) // 400
  local yoe = y - era * 400
  local doy = (153 * (mo + (mo > 2 and -3 or 9)) + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  local days = era * 146097 + doe - 719468
  local t = days * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(sec)
  local zh, zm = s:match("([%+%-]%d%d):?(%d%d)$")
  if zh then t = t - (tonumber(zh) * 3600 + (zh:sub(1, 1) == "-" and -1 or 1) * tonumber(zm) * 60) end
  return t
end

--- A topic level of our own: no wildcards or separators from a rule name.
local function level(s) return (tostring(s):gsub("[/#%+]", "_")) end

-- ---- object classes ------------------------------------------------------------------------------------------------

M.CLASSES = {
  { key = "human", value = 1, text = "Person" },
  { key = "car", value = 2, text = "Bil" },
  { key = "truck", value = 3, text = "Lastbil" },
  { key = "bus", value = 4, text = "Buss" },
  { key = "bike", value = 5, text = "Cykel" },
  { key = "motorcycle", value = 6, text = "Motorcykel" },
  { key = "vehicle", value = 7, text = "Fordon" },
  { key = "animal", value = 8, text = "Djur" },
  { key = "face", value = 9, text = "Ansikte" },
  { key = "licenseplate", value = 10, text = "Registreringsskylt" },
  { key = "other", value = 99, text = "Övrigt" },
}
local ALIAS = { person = "human", bicycle = "bike", motorbike = "motorcycle", vehical = "vehicle", plate = "licenseplate" }

function M.class_of(name)
  if type(name) ~= "string" then return nil end
  local k = name:lower():gsub("[^%w]", "")
  k = ALIAS[k] or k
  for _, c in ipairs(M.CLASSES) do if c.key == k then return c end end
  return M.CLASSES[#M.CLASSES]
end

-- ---- parsing -------------------------------------------------------------------------------------------------------

--- The parts of a camera topic, or nil when it is not an ONVIF event from a camera.
function M.parse_topic(topic)
  local p = M.split(topic, "/")
  if p[1] ~= "obj" or p[2] ~= "bosch" or p[4] ~= "onvif-ej" or not p[5] then return nil end
  local amp
  for i = 5, #p do if p[i]:sub(1, 1) == "&" then amp = i break end end
  local event = table.concat(p, "/", 5, (amp or #p + 1) - 1)
  local rule = amp and amp < #p and table.concat(p, "/", amp + 1) or nil
  return { serial = p[3], event = event, source = amp and p[amp] or nil, rule = rule }
end

-- keys that identify or describe an object rather than measure it
local SKIP = { Appearance = true, Color = true, Shape = true, BoundingBox = true, Polygon = true, Transformation = true, Image = true }

--- Everything the app can use from one event payload.
function M.extract(data)
  local out = { extra = {} }
  if type(data) ~= "table" then return out end
  out.count = num(data.Count)
  out.state = bool(data.State)
  if out.state == nil then out.state = bool(data.IsInside) end
  local obj = data.Object
  if type(obj) == "table" and type(obj.Object) == "table" then obj = obj.Object end
  if type(obj) == "table" then
    out.object_id = num(obj["@ObjectId"])
    local cls = type(obj.Appearance) == "table" and obj.Appearance.Class or nil
    if type(cls) == "table" then
      local t = cls.Type or (type(cls.ClassCandidate) == "table" and cls.ClassCandidate) or nil
      if type(t) == "table" and t[1] ~= nil then t = t[1] end -- a list of candidates: the first
      if type(t) == "string" then out.class = t
      elseif type(t) == "table" then
        out.class = t["#text"] or t.Type
        out.likelihood = num(t["@Likelihood"] or t.Likelihood)
      end
    end
    if type(obj.Behaviour) == "table" then out.speed = num(obj.Behaviour.Speed) end
  end
  -- any other number: a path of plain keys, no attributes (@...) and nothing that only describes the object
  local used = { Count = true, State = true, IsInside = true, Speed = true }
  local function walk(t, path, depth)
    if depth > 6 then return end
    for k, v in pairs(t) do
      if type(k) == "string" and k:sub(1, 1) ~= "@" and k ~= "#text" and not SKIP[k] then
        local p = path and (path .. "." .. k) or k
        if type(v) == "table" then walk(v, p, depth + 1)
        elseif num(v) and not (used[k] and (path == nil or k == "Speed")) and k ~= "Likelihood" then
          out.extra[#out.extra + 1] = { path = (p:gsub("^Object%.Object%.", "Object.")), value = num(v) }
        end
      end
    end
  end
  walk(data, nil, 1)
  table.sort(out.extra, function(a, b) return a.path < b.path end)
  return out
end

-- ---- devices and functions -----------------------------------------------------------------------------------------

local devices, functions, failed = {}, {}, {}
local RETRY_S = 60

local function first(list) if type(list) == "table" then return list[1] end end

local function device_for(serial)
  if devices[serial] then return devices[serial] end
  local d
  for _, x in ipairs(lynx.getDevices() or {}) do
    if x.type == "bosch_camera" and x.meta and x.meta.serial == serial then d = x break end
  end
  if not d then
    d = lynx.createDevice({ type = "bosch_camera", installation_id = app and app.installation_id or nil,
      meta = { serial = serial, name = "Bosch Camera " .. serial } })
    log.i("created device for camera %s", serial)
  end
  devices[serial] = d
  return d
end

--- The unit of the speed functions: "km/h" (default, converted) or "m/s" (as the camera sends it).
local function speed_unit() return setting("speed_output", "kmh") == "ms" and "m/s" or "km/h" end
M.speed_unit = speed_unit

local ATTR = {
  speed = { suffix = " hastighet", type = "speed", meta = {} },
  likelihood = { suffix = " sannolikhet", type = "probability", meta = { unit = "%", format = "%d %%" } },
}

local function class_meta()
  local m = {}
  for _, c in ipairs(M.CLASSES) do
    m["state_" .. c.key] = tostring(c.value)
    m["text_" .. c.key] = c.text
  end
  return m
end

--- A speed function made with the other unit gets the unit of the form (the app restarts when the form changes).
local function fit_unit(fn)
  local unit = speed_unit()
  if not fn.meta or fn.meta.unit == unit then return end
  local meta = {}
  for k, v in pairs(fn.meta) do meta[k] = v end
  meta.unit, meta.format = unit, "%.1f " .. unit
  local ok, err = pcall(lynx.apiCall, "PUT", "/api/v2/functionx/" .. tostring(fn.installation_id or (app and app.installation_id)) .. "/" .. tostring(fn.id),
    { type = fn.type, installation_id = fn.installation_id or (app and app.installation_id), meta = meta })
  if ok then fn.meta = meta log.i("speed unit of %s set to %s", tostring(meta.name), unit)
  else log.e("could not set the unit of %s: %s", tostring(meta.name), tostring(err)) end
end

--- The function for one attribute of one rule; found again in IoT Open, or created.
local function function_for(ev, attr, kind)
  local key = ev.serial .. "|" .. ev.name .. "|" .. attr
  if functions[key] then return functions[key] end
  local now = os.time()
  if failed[key] and now - failed[key] < RETRY_S then return nil end
  local dev = device_for(ev.serial)
  local fn = first(lynx.getFunctions({ ["bosch.serial"] = ev.serial, ["bosch.rule"] = ev.name, ["bosch.attr"] = attr }))
  if not fn and attr == "event" then
    -- made by IoT Open's edge-app-bosch-ai-sensor
    fn = first(lynx.getFunctions({ type = "counter", bosch_name = ev.name, device_id = tostring(dev.id) }))
  end
  if not fn then
    local base = "obj/bosch/" .. ev.serial .. "/" .. level(ev.name)
    local meta = {
      device_id = tostring(dev.id), bosch_name = ev.name,
      ["bosch.serial"] = ev.serial, ["bosch.rule"] = ev.name, ["bosch.attr"] = attr, ["bosch.event"] = ev.event,
    }
    local ftype
    if attr == "event" then
      meta.name, meta.topic_read = ev.name, base
      if kind == "count" then ftype = "counter"
      elseif kind == "state" then ftype = "detection" meta.state_detected = "1" meta.text_detected = "Upptäckt" meta.state_none = "0" meta.text_none = "Inget"
      else ftype = "event" meta.format = "%d" end
    elseif attr == "class" then
      ftype = "object_class"
      meta.name, meta.topic_read = ev.name .. " objekttyp", base .. "/class"
      for k, v in pairs(class_meta()) do meta[k] = v end
    elseif ATTR[attr] then
      ftype = ATTR[attr].type
      meta.name, meta.topic_read = ev.name .. ATTR[attr].suffix, base .. "/" .. attr
      for k, v in pairs(ATTR[attr].meta) do meta[k] = v end
      if attr == "speed" then meta.unit, meta.format = speed_unit(), "%.1f " .. speed_unit() end
    else -- extra: attr is the path, e.g. Object.Behaviour.Direction
      ftype = "value"
      meta.name, meta.topic_read = ev.name .. " " .. attr, base .. "/" .. level(attr:lower():gsub("%.", "_"))
    end
    local ok, res = pcall(lynx.createFunction, { type = ftype, installation_id = app and app.installation_id or nil, meta = meta })
    if not ok or type(res) ~= "table" then
      failed[key] = now
      log.e("could not create function %s: %s", meta.name, tostring(res))
      return nil
    end
    fn = res
    log.i("created function %s (%s)", meta.name, ftype)
  end
  if attr == "speed" then fit_unit(fn) end
  functions[key] = fn
  failed[key] = nil
  return fn
end

local function publish(fn, value, ts, msg)
  if not fn or value == nil then return end
  local topic = fn.meta and fn.meta.topic_read
  if not topic or topic == "" then return end
  mq:pub(topic, json:encode({ value = value, timestamp = ts, msg = msg or "" }), false, 0)
end

-- ---- one event -----------------------------------------------------------------------------------------------------

function M.handle(topic, payload)
  local ev = M.parse_topic(topic)
  if not ev then return end
  local ok, data = pcall(json.decode, json, payload)
  if not ok or type(data) ~= "table" then
    log.e("not JSON on %s", topic)
    return
  end
  local src = type(data.Source) == "table" and data.Source or {}
  ev.name = ev.rule or (type(src.Rule) == "string" and src.Rule) or ev.event
  local ts = M.utc(data.UtcTime) or os.time()
  local x = M.extract(data.Data)

  -- the camera sends m/s; by default the app turns it into km/h
  local speed, unit = x.speed, speed_unit()
  if speed and unit == "km/h" then speed = speed * 3.6 end
  local cls = M.class_of(x.class)

  local kind, value = "pulse", 1
  if x.count then kind, value = "count", x.count
  elseif x.state ~= nil then kind, value = "state", (x.state and 1 or 0) end
  local words = {}
  if cls then words[#words + 1] = x.class end
  if speed then words[#words + 1] = string.format("%.1f %s", speed, unit) end
  publish(function_for(ev, "event", kind), value, ts, table.concat(words, " "))

  if speed and enabled("speed") then publish(function_for(ev, "speed"), math.floor(speed * 10 + 0.5) / 10, ts, x.class) end
  if cls and enabled("class") then publish(function_for(ev, "class"), cls.value, ts, x.class) end
  if x.likelihood and cls and enabled("likelihood") then
    publish(function_for(ev, "likelihood"), math.floor(x.likelihood * 100 + 0.5), ts, x.class)
  end
  if enabled("extra") then
    for _, e in ipairs(x.extra) do publish(function_for(ev, e.path), e.value, ts, x.class) end
  end
end

function M.reset() devices, functions, failed = {}, {}, {} end

-- ---- the edge client -----------------------------------------------------------------------------------------------

local TOPIC = "obj/bosch/+/onvif-ej/#"

function onStart()
  mq:sub(TOPIC, 0)
  mq:bind(TOPIC, function(topic, payload)
    local ok, err = pcall(M.handle, topic, payload)
    if not ok then log.e("event on %s: %s", topic, tostring(err)) end
  end)
  log.i("started, listening on %s", TOPIC)
end

if BOSCH_TEST then return M end

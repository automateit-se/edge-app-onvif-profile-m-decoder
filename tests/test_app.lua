-- Tests for app.lua without an edge client: run with `lua5.3 tests/test_app.lua` from the repository root.
-- The payloads follow what multisensors send; all names, serial numbers and ids are made up.

local failures, count = 0, 0
local function check(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if ok then print("ok   " .. name) else failures = failures + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, what)
  if a ~= b then error(string.format("%s: expected %s, got %s", what or "value", tostring(b), tostring(a)), 2) end
end

local S = dofile("tests/sim.lua")
local load_app = S.load_app

local SERIAL = "11112222333344445"
local RULE = "Gata Norr"
local IN = "obj/bosch/" .. SERIAL .. "/onvif-ej/" -- the vendor level the tested firmware uses
local OUT = "obj/multisensor/" .. SERIAL .. "/"
local CROSSED = IN .. "RuleEngine/LineDetector/Crossed/&1/" .. RULE
local BASE = OUT .. RULE

-- firmware 9.8x: the object that crossed the line comes with the event
local WITH_OBJECT = [[{ "UtcTime": "2026-11-25T14:08:36.510Z","Source":{"VideoSource":"1","Rule":"Gata Norr"},"Data":{"Object": {"Object": {"@UUID":"00000000-0000-0000-0000-000000000001","@ObjectId":166,"Appearance": {"Color": {"ColorCluster":[{"Color": {"@Z":58.31,"@Y":58.31,"@X":36.03},"Weight": "0.64"},{"Color": {"@Z":31.88,"@Y":31.88,"@X":31.88},"Weight": "0.22"}]},"Class": {"Type": {"@Likelihood":0.87,"#text":"Car"}}},"Behaviour": {"Speed": 15.94}}}}}]]
-- firmware 9.4x: only the event
local BARE = [[{ "UtcTime": "2026-11-24T14:58:40.793Z","Source":{"VideoSource": "1","Rule": "Gata Norr"}}]]

-- ---- helpers -------------------------------------------------------------------------------------------------------

check("UTC time without the local time zone", function()
  local M = load_app()
  eq(M.utc("1970-01-01T00:00:00Z"), 0, "epoch")
  eq(M.utc("2026-11-25T14:08:36Z"), 1795615716, "a November day")
  eq(M.utc("2024-02-29T12:00:00Z"), 1709208000, "leap day")
  eq(M.utc("2026-11-25T14:08:36.510Z"), 1795615716.51, "fraction kept")
  eq(M.utc("2026-11-25T15:08:36+01:00"), 1795615716, "with an offset")
  eq(M.utc("nonsense"), nil, "invalid")
end)

check("topics: serial, event, source and rule", function()
  local M = load_app()
  local t = M.parse_topic(CROSSED)
  eq(t.serial, SERIAL, "serial")
  eq(t.event, "RuleEngine/LineDetector/Crossed", "event")
  eq(t.source, "&1", "source")
  eq(t.rule, RULE, "rule")
  local m = M.parse_topic(IN .. "VideoSource/MotionAlarm/&1")
  eq(m.event, "VideoSource/MotionAlarm", "event without a rule")
  eq(m.rule, nil, "no rule")
  eq(M.parse_topic(BASE), nil, "our own topics are not events")
  eq(M.parse_topic("obj/acme/" .. SERIAL .. "/onvif-ej/RuleEngine/X/&1/R").rule, "R", "any vendor level")
  eq(M.parse_topic("obj/other/x/status/a"), nil, "not an ONVIF event")
end)

check("classes, with ONVIF and vendor names", function()
  local M = load_app()
  eq(M.class_of("Car").value, 2, "car")
  eq(M.class_of("Human").text, "Person", "human")
  eq(M.class_of("Person").key, "human", "person is human")
  eq(M.class_of("Bicycle").key, "bike", "bicycle is bike")
  eq(M.class_of("Vehical").key, "vehicle", "the ONVIF spelling")
  eq(M.class_of("Spaceship").key, "other", "unknown")
  eq(M.class_of(nil), nil, "no class")
end)

-- ---- events --------------------------------------------------------------------------------------------------------

check("a crossing with an object: event, speed and class", function()
  local _, _, sim = load_app()
  sim.send(CROSSED, WITH_OBJECT)
  eq(#sim.created_devices, 1, "one device")
  eq(sim.created_devices[1].type, "multisensor", "device type")
  eq(sim.fn(RULE).meta["multisensor.attr"], "event", "meta")
  eq(sim.created_devices[1].meta.serial, SERIAL, "device serial")
  local ev = sim.last(BASE)
  eq(ev.value, 1, "one crossing")
  eq(ev.timestamp, 1795615716.51, "camera time")
  eq(ev.msg, "Car 57.4 km/h", "msg")
  eq(sim.last(BASE .. "/speed").value, 57.4, "15.94 m/s is 57.4 km/h")
  eq(sim.last(BASE .. "/class").value, 2, "car")
  eq(sim.last(BASE .. "/class").msg, "Car", "class name")
  eq(sim.fn(RULE).type, "event", "event type")
  eq(sim.fn(RULE .. " hastighet").meta.unit, "km/h", "unit")
  eq(sim.fn(RULE .. " objekttyp").meta.state_car, "2", "class map")
  eq(sim.fn(RULE .. " objekttyp").meta.text_car, "Bil", "class text")
  eq(sim.fn(RULE).meta.device_id, tostring(sim.created_devices[1].id), "on the camera")
  eq(#sim.created, 3, "three functions")
end)

check("no functions for the colours, the object id or the likelihood by default", function()
  local _, _, sim = load_app()
  sim.send(CROSSED, WITH_OBJECT)
  for _, f in ipairs(sim.created) do
    assert(not f.meta.name:find("Color") and not f.meta.name:find("Weight") and not f.meta.name:find("ObjectId"), f.meta.name)
  end
  eq(sim.fn(RULE .. " sannolikhet"), nil, "likelihood off")
end)

check("likelihood when chosen", function()
  local _, _, sim = load_app({ cfg = { attributes = { "speed", "class", "likelihood" } } })
  sim.send(CROSSED, WITH_OBJECT)
  eq(sim.last(BASE .. "/likelihood").value, 87, "percent")
end)

check("speed in m/s as the camera sends it, when chosen", function()
  local _, _, sim = load_app({ cfg = { speed_output = "ms" } })
  sim.send(CROSSED, WITH_OBJECT)
  eq(sim.last(BASE .. "/speed").value, 15.9, "m/s")
  eq(sim.fn(RULE .. " hastighet").meta.unit, "m/s", "unit")
  eq(sim.fn(RULE .. " hastighet").meta.format, "%.1f m/s", "format")
  eq(sim.last(BASE).msg, "Car 15.9 m/s", "msg")
end)

check("a speed function gets the new unit when the form changes", function()
  local _, _, first = load_app()
  first.send(CROSSED, WITH_OBJECT)
  eq(first.fn(RULE .. " hastighet").meta.unit, "km/h", "made with km/h")
  local _, _, sim = load_app({ cfg = { speed_output = "ms" }, devices = first.created_devices, functions = first.created })
  sim.send(CROSSED, WITH_OBJECT)
  eq(#sim.created, 0, "the same function")
  eq(sim.fn(RULE .. " hastighet").meta.unit, "m/s", "unit changed")
  eq(#sim.api, 1, "one update")
  sim.send(CROSSED, WITH_OBJECT)
  eq(#sim.api, 1, "not again")
end)

check("older firmware: only the event", function()
  local _, _, sim = load_app()
  sim.send(CROSSED, BARE)
  eq(sim.last(BASE).value, 1, "crossing")
  eq(sim.last(BASE).msg, "", "nothing more")
  eq(#sim.created, 1, "one function")
end)

check("the next message after a new device is not lost (IoT Open's app dropped it)", function()
  local _, _, sim = load_app()
  sim.send(CROSSED, BARE)
  sim.send(CROSSED, WITH_OBJECT)
  eq(#sim.pubs(BASE), 2, "both crossings")
  eq(#sim.created_devices, 1, "still one device")
  eq(#sim.created, 3, "event, speed, class")
end)

check("functions and devices are found again after a restart", function()
  local _, _, first = load_app()
  first.send(CROSSED, WITH_OBJECT)
  local _, _, sim = load_app({ devices = first.created_devices, functions = first.created })
  sim.send(CROSSED, WITH_OBJECT)
  eq(#sim.created, 0, "nothing new")
  eq(#sim.created_devices, 0, "no new device")
  eq(sim.last(BASE .. "/speed").value, 57.4, "speed published")
end)

check("a counter made by IoT Open's app is used again", function()
  -- the names IoT Open's app used
  local old_topic = "obj/bosch/" .. SERIAL .. "/" .. RULE
  local dev = { id = 300, type = "bosch_camera", meta = { serial = SERIAL, name = "Camera " .. SERIAL } }
  local old = { id = 301, type = "counter", meta = { bosch_name = RULE, name = RULE, device_id = "300", topic_read = old_topic } }
  local _, _, sim = load_app({ devices = { dev }, functions = { old } })
  sim.send(CROSSED, WITH_OBJECT)
  eq(#sim.created_devices, 0, "same device")
  eq(sim.last(old_topic).value, 1, "on the old topic")
  eq(sim.fn(RULE .. " hastighet").meta.device_id, "300", "new functions on the old device")
  eq(#sim.created, 2, "only speed and class are new")
end)

check("counter rules publish the count", function()
  local _, _, sim = load_app()
  local topic = IN .. "RuleEngine/CountAggregation/Counter/&1/Räknare"
  sim.send(topic, [[{"UtcTime":"2026-11-25T14:00:00Z","Source":{"Rule":"Räknare"},"Data":{"Count":"42"}}]])
  eq(sim.last(OUT .. "Räknare").value, 42, "count")
  eq(sim.fn("Räknare").type, "counter", "counter")
end)

check("state rules publish 1 and 0", function()
  local _, _, sim = load_app()
  local topic = IN .. "RuleEngine/FieldDetector/ObjectsInside/&1/Infart"
  sim.send(topic, [[{"UtcTime":"2026-11-25T14:00:00Z","Data":{"IsInside":"true"}}]])
  sim.send(topic, [[{"UtcTime":"2026-11-25T14:00:05Z","Data":{"IsInside":"false"}}]])
  local p = sim.pubs(OUT .. "Infart")
  eq(p[1].value, 1, "inside")
  eq(p[2].value, 0, "gone")
  eq(sim.fn("Infart").meta.state_detected, "1", "state map")
end)

check("events without a rule are named after the event", function()
  local _, _, sim = load_app()
  sim.send(IN .. "VideoSource/MotionAlarm/&1", [[{"UtcTime":"2026-11-25T14:00:00Z","Data":{"State":true}}]])
  eq(sim.fn("VideoSource/MotionAlarm").type, "detection", "named by event")
  eq(sim.last(OUT .. "VideoSource_MotionAlarm").value, 1, "slashes are not topic levels")
end)

check("other numbers the camera adds become functions of their own", function()
  local _, _, sim = load_app()
  sim.send(CROSSED, [[{"UtcTime":"2026-11-25T14:00:00Z","Data":{"Object":{"Object":{"@ObjectId":7,"Behaviour":{"Speed":3.2,"Direction":{"Heading":271}}}}}}]])
  local f = sim.fn(RULE .. " Object.Behaviour.Direction.Heading")
  assert(f, "extra function")
  eq(sim.last(f.meta.topic_read).value, 271, "heading")
  eq(f.meta.topic_read, BASE .. "/object_behaviour_direction_heading", "topic")
end)

check("broken JSON is logged, not thrown", function()
  local _, _, sim = load_app()
  sim.send(CROSSED, "{not json")
  eq(#sim.published, 0, "nothing published")
  assert(sim.logs[#sim.logs]:find("^E "), "logged")
end)

check("a failed create is tried again after a minute, not on every event", function()
  local fail = true
  local _, _, sim = load_app({ create_fails = function() return fail end })
  sim.send(CROSSED, BARE)
  sim.send(CROSSED, BARE)
  local errors = 0
  for _, l in ipairs(sim.logs) do if l:find("could not create") then errors = errors + 1 end end
  eq(errors, 1, "one attempt")
  fail = false
  sim.clock = sim.clock + 61
  sim.send(CROSSED, BARE)
  eq(#sim.pubs(BASE), 1, "published after the retry")
end)

print(string.format("%d tests, %d failed", count, failures))
if failures > 0 then os.exit(1) end

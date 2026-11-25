# IQSIGHT ONVIF Profile M decoder (IoT Open edge app)

An IoT Open edge app that turns the rules of Bosch AI cameras into IoT Open functions: the event itself, and the
speed, class and other values of the object that triggered it.

Based on [IoTOpen/edge-app-bosch-ai-sensor](https://github.com/IoTOpen/edge-app-bosch-ai-sensor) (MIT). Technical
names (metadata keys, topics) are in English; the settings form and function names are in Swedish.

## The camera

Bosch cameras with firmware 9.x can publish their ONVIF events as JSON over MQTT. Point the camera's MQTT client at
the edge client's broker; the events arrive on

```
obj/bosch/<serial>/onvif-ej/<event>/&<source>/<rule name>
```

for example `obj/bosch/<serial>/onvif-ej/RuleEngine/LineDetector/Crossed/&1/Gata Norr`.

Newer firmware (seen with 9.8x) sends the object that triggered the rule with the event: its id, class, colours and
speed. Older firmware (seen with 9.4x) sends only the time and the rule. The app handles both.

## What the app creates

One device per camera (type `bosch_camera`, meta `serial`), and for every rule, the first time it gives an event:

| Function | Type | Topic | Value |
|---|---|---|---|
| *&lt;rule&gt;* | `counter` (counter rules), `detection` (state rules), `event` (others) | `obj/bosch/<serial>/<rule>` | the count, 1/0, or 1 per event; `msg` says the class and speed, e.g. `Car 57.4 km/h` |
| *&lt;rule&gt; hastighet* | `speed` | `.../<rule>/speed` | km/h converted from the camera's m/s (default), or m/s; one decimal |
| *&lt;rule&gt; objekttyp* | `object_class` | `.../<rule>/class` | a number per class, with `state_<class>`/`text_<class>` meta (1 person, 2 car, 3 truck, 4 bus, 5 bike, 6 motorcycle, 7 vehicle, 8 animal, 9 face, 10 licence plate, 99 other); the camera's name in `msg` |
| *&lt;rule&gt; sannolikhet* | `probability` | `.../<rule>/likelihood` | % how sure the camera is of the class (off by default) |
| *&lt;rule&gt; &lt;path&gt;* | `value` | `.../<rule>/<path>` | any other number in the event, e.g. `Object.Behaviour.Direction.Heading` |

Colours, bounding boxes, shapes and ids are left out: they describe one object, not a measurement. Events without a
rule (e.g. `VideoSource/MotionAlarm`) are named after the event. The timestamp is the camera's time (`UtcTime`).

Every function has the meta `bosch.serial`, `bosch.rule`, `bosch.attr` and `bosch.event`, so the app finds them again
after a restart; rename them freely. Counter functions made by IoT Open's app (type `counter`, meta `bosch_name`)
are used again, on their old topic.

## Settings

| Setting | Default | |
|---|---|---|
| Funktioner per regel (`attributes`) | speed, class, other values | which functions to create besides the event |
| Hastighet till IoT Open (`speed_output`) | km/h | `kmh`: the app converts the camera's m/s to km/h (× 3.6); `ms`: m/s as the camera sends it |

The camera sends the speed in m/s: the MetaDataCollector Integration Guide from Bosch/IQSIGHT gives the object speed
in m/s (tables `geo_events`, MQTT geo data), and an event with `"Speed": 15.94` is a car at 57 km/h. The speed
functions get `unit` and `format` after the setting; a function made with the other unit is updated when the app
starts. The speed is only as good as the camera's calibration (height, tilt, focal length): check it once with a
known speed.

## Tests

```
lua5.3 tests/test_app.lua
```

The edge client is simulated in `tests/sim.lua`. GitHub Actions runs the tests, a syntax check and the JSON checks on
every push.

## Licence

MIT, see [LICENSE](LICENSE).

# IQSIGHT ONVIF Profile M decoder (IoT Open edge app)

An IoT Open edge app that turns the analytics rules of a multisensor into IoT Open functions: the event itself, and
the speed, class and other values of the object that triggered it.

In this context, *multisensor* means a camera's analytics metadata only. No images or video streams are needed or
sent: the app reads the ONVIF events (JSON) and publishes numbers.

Based on [IoTOpen/edge-app-bosch-ai-sensor](https://github.com/IoTOpen/edge-app-bosch-ai-sensor) (MIT). Technical
names (metadata keys, topics) are in English; the settings form and function names are in Swedish.

## The multisensor

The multisensor publishes its ONVIF events as JSON over MQTT. Point its MQTT client at the edge client's broker; the
app listens on

```
obj/<vendor>/<serial>/onvif-ej/<event>/&<source>/<rule name>
```

for any vendor level, for example `obj/<vendor>/<serial>/onvif-ej/RuleEngine/LineDetector/Crossed/&1/Gata Norr`.

Tested with Bosch firmware 9.x, which uses the vendor level `bosch`. Newer firmware (seen with 9.8x) sends the object
that triggered the rule with the event: its id, class, colours and speed. Older firmware (seen with 9.4x) sends only
the time and the rule. The app handles both.

## What the app creates

One device per multisensor (type `multisensor`, meta `serial`, name *Multisensor &lt;serial&gt;*), and for every rule, the first time it gives an event:

| Function | Type | Topic | Value |
|---|---|---|---|
| *&lt;rule&gt;* | `counter` (counter rules), `detection` (state rules), `event` (others) | `obj/multisensor/<serial>/<rule>` | the count, 1/0, or 1 per event; `msg` says the class and speed, e.g. `Car 57.4 km/h` |
| *&lt;rule&gt; hastighet* | `speed` | `.../<rule>/speed` | km/h converted from the camera's m/s (default), or m/s; one decimal |
| *&lt;rule&gt; objekttyp* | `object_class` | `.../<rule>/class` | a number per class, with `state_<class>`/`text_<class>` meta (1 person, 2 car, 3 truck, 4 bus, 5 bike, 6 motorcycle, 7 vehicle, 8 animal, 9 face, 10 licence plate, 99 other); the camera's name in `msg` |
| *&lt;rule&gt; sannolikhet* | `probability` | `.../<rule>/likelihood` | % how sure the camera is of the class (off by default) |
| *&lt;rule&gt; &lt;path&gt;* | `value` | `.../<rule>/<path>` | any other number in the event, e.g. `Object.Behaviour.Direction.Heading` |

These come only when chosen in the form (all off by default), and only from rules whose events carry them:

| Function | Type | Topic | Value |
|---|---|---|---|
| *&lt;rule&gt; latitud*, *&lt;rule&gt; longitud* | `latitude`, `longitude` | `.../<rule>/latitude`, `/longitude` | where the object was, in degrees (IVA Pro Perimeter or Traffic in a 3D tracking mode, with the camera's position set); 0,0 is skipped |
| *&lt;rule&gt; färg* | `color` | `.../<rule>/color` | the heaviest colour cluster as a number, with `state_<colour>`/`text_<colour>` meta (1 black, 2 white, 3 grey, 4 red, 5 orange, 6 yellow, 7 green, 8 blue, 9 purple, 10 brown); every cluster in `msg`, e.g. `Svart: #243a3a 64 %, #202020 22 %` |
| *&lt;rule&gt; hjälm*, *&lt;rule&gt; väst* | `ppe` | `.../<rule>/helmet`, `/vest` | 1/0 per person (IVA Pro PPE); the kind of helmet in `msg`; nothing when the camera does not say |
| *&lt;rule&gt; registreringsnummer* | `license_plate` | `.../<rule>/plate` | 1 per plate read; plate, country, make and model and the likelihood in `msg`, e.g. `ABC 123 SE examplebrand x1 92 %` (IVA Pro License Plate Recognition); the plate also leads the event's `msg` |

The colour is named from what the camera sees, light and shade included: a dark car in shade may come out black. The
camera's X, Y, Z are read as red, green and blue (0-255), which fits the examples in Bosch's MQTT whitepaper for
firmware 9.80. A licence plate is personal data: choose it only where its processing has a legal basis. The vehicle
class from a plate read is used for *&lt;rule&gt; objekttyp* whether or not plates are chosen.

Not used: snapshots (Base64 images; the app handles metadata only), the object id and UUID, bounding boxes and shapes,
and the IVA Pro Appearance attributes of people (gender, hair, clothes, glasses, bags). Events without a rule (e.g.
`VideoSource/MotionAlarm`) are named after the event. The timestamp is the camera's time (`UtcTime`).

Every function has the meta fields `multisensor.serial`, `multisensor.rule`, `multisensor.attr` and
`multisensor.event`, which let the app find it again after a restart. The functions and the device can be renamed
freely; keep the `multisensor.*` fields, or the app creates new functions.

Devices and counter functions created by IoT Open's app are reused: devices of type `bosch_camera` (meta `serial`),
and counter functions with meta `bosch_name`, on their original topic. These are the names that app used, and the
only reason the word remains in the code.

## Settings

| Setting | Default | |
|---|---|---|
| Funktioner per regel (`attributes`) | speed, class, other values | which functions to create besides the event: `speed`, `class`, `likelihood`, `geo`, `color`, `ppe`, `lpr`, `extra` |
| Hastighet till IoT Open (`speed_output`) | km/h | `kmh`: the app converts the camera's m/s to km/h (× 3.6); `ms`: m/s as the camera sends it |

The camera sends the speed in m/s: the IQSIGHT MetaDataCollector Integration Guide gives the object speed
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

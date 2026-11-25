# Changelog

## 0.1.0

First version, based on [IoTOpen/edge-app-bosch-ai-sensor](https://github.com/IoTOpen/edge-app-bosch-ai-sensor),
which made one counter function per counter rule.

- One device per multisensor (type `multisensor`) and, for every rule, the event as a function: the count (counter rules), 1/0 (state rules)
  or 1 per event (line crossings and others), with the class and speed in `msg`.
- Speed, object class and (optionally) class likelihood of the object that triggered the rule, as functions of their
  own, when the camera firmware sends the object with the event (seen with 9.8x).
- The camera sends the speed in m/s; by default the app converts it to km/h (form: *Hastighet till IoT Open*).
- Any other number in the event becomes a function too (form: *Andra värden sensorn skickar*).
- The event time is read as UTC whatever the edge client's time zone.
- Listens to any vendor level (`obj/<vendor>/<serial>/onvif-ej/#`); own functions on `obj/multisensor/...` with
  `multisensor.*` meta. Analytics metadata only: no images or video.
- Devices (`bosch_camera`) and counter functions (`bosch_name`) made by IoT Open's app are found and used again.
- A settings form, tests and a CI check.

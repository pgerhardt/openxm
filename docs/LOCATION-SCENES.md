# Location-triggered scenes

OpenXM can save a named place and apply a sound scene on arrival or departure. This adds the location part of automatic sound selection on macOS. Walking/running/transport recognition and Sony-account place sync remain separate gaps; this is not complete Adaptive Sound Control parity.

## Using places

In a scene's editor, choose **Place** under Run Automatically. Give the place a name, select arrival or departure, and choose **Use Current Location** or enter decimal latitude/longitude under Coordinates. Set a radius from 100 to 5,000 metres. Saving an incomplete place is disabled. Saving a place is separate from granting permission; **Allow Location for Scenes** explicitly requests macOS access if needed.

The editor and Scenes page show the authorization/monitoring status. If access is denied or Location Services are disabled, they explain where to change the setting. OpenXM never requests location permission automatically on startup, on headphone connection, or when saving a scene. Replay and demo mode cannot create the location provider, request permission, obtain a fix or run an automation.

Checks run only while OpenXM is running, an enabled valid place scene exists, location access is authorized and headphones are connected. They use one-shot Core Location requests at 30-second intervals. Sleep, disconnect, removal/pausing of all place scenes or permission loss stops monitoring. Waking or reconnecting requires new location evidence. Capture for the editor is a separate explicit one-time request, can run without headphones and stops when it finishes or the editor closes.

The first matching scene in the saved scene order wins when places overlap. Use a scene's More Actions → Move to Top to give it priority. A scene uses the existing capability-checked, write/read-back execution path. No writes are made while another settings/firmware operation reserves the headphones. A pending location event may wait for controls to become available, but stale or contradictory location evidence cannot trigger it later. Failed application is reported through the existing scene result; it is not retried continuously.

## Boundary behavior

- Two distinct fixes must agree for at least 30 seconds. Duplicate/out-of-order fixes do not advance the timer; gaps over two minutes break dwell.
- Fixes must be recent (at most two minutes old, no more than ten seconds into the future), have valid coordinates, and report finite accuracy from 0 to 1,000 metres. The accuracy must also be no larger than half the place radius.
- Arrival requires the entire accuracy circle to fit within the radius. Departure requires it to lie outside the radius plus an additional margin of 50 metres or 10%, whichever is larger.
- Uncertain fixes and failed location requests interrupt the confirmation period. A queued event is withheld while the boundary is uncertain and discarded if a definite movement in the opposite direction is observed.
- Initial presence may apply an arrival scene after confirmation. An initial outside fix never counts as departure; the app must first observe the Mac inside.
- An event runs once per boundary crossing. Manual sound changes while remaining in the same place do not cause the location scene to repeatedly reapply itself.

The Mac's location accuracy and availability determine whether a small radius can trigger. This is coarse place detection, not room detection. No claim of real-world arrival/departure accuracy has yet been established.

## Data and platform evidence

The chosen place name, center, radius and event are saved in the existing local `SoundConnect/scenes.json`, alongside the scene's existing last-application time/result. Live fixes, accuracy and movement history are not persisted or logged. OpenXM sends no coordinates to its own server. macOS Location Services may use network connections; the UI states this. Deleting a scene removes its saved place from the active scene file.

The implementation uses Apple's public [`CLLocationManager.requestLocation()`](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestlocation()) for one-time fixes and [`requestWhenInUseAuthorization()`](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestwheninuseauthorization()) only in explicit UI actions. [`NSLocationUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocationusagedescription) is provided for macOS, along with the when-in-use usage string. The installed SDK marks `.authorizedWhenInUse` unavailable on macOS; the provider handles the Mac's authorized/denied/restricted/not-determined states. No private API or always-on background daemon is used.

Activity recognition requires separate evidence. Although `CMMotionActivityManager` is unavailable on macOS, [`CMHeadphoneActivityManager`](https://developer.apple.com/documentation/coremotion/cmheadphoneactivitymanager) is available from macOS 15 and obtains activity from compatible headphones. Apple's [sample](https://developer.apple.com/documentation/coremotion/getting-motion-activity-data-from-headphones) gives AirPods Pro 2 and AirPods 4 as examples, without establishing WH-1000XM3 support. The installed SDK documents no automotive or cycling support for this headphone API. It is not currently integrated into OpenXM, and no motion permission or sensing session was started in the audit. An available macOS API alone does not establish activity recognition for the XM3.

## Verification — 2026-10-30

Eleven automated tests cover stable arrival/departure, accuracy circles, hysteresis, duplicate/out-of-order/stale/future/invalid fixes, dwell reset, reentry, overlapping priorities, place editing/removal, the date line, file round-trips, invalid saved places, explicit permission behavior, revocation, cancellation and replay refusal. An injected provider exercises permission and capture state without querying a real location or sending headphone writes. The complete suite passes with **109 tests in 18 suites**, including the existing firmware and voice-package checks.

Real macOS permission grant/revocation, Wi-Fi positioning, moving between actual places and resulting headphone changes remain unverified. These require the user's choice to enable location and a connected headset. No real coordinates or permission change were used during development checks.

The signed native scene editor was inspected in replay: Place selection showed arrival/departure and radius controls, location access was disabled explicitly, and an incomplete place disabled Create Scene. Manual latitude 91 was rejected; synthetic coordinates 0/0 with a name enabled the valid draft. Switching to departure worked. The draft was canceled, and the three existing scenes remained unchanged. Move to Top was present in the scene action menu. No location permission or headphone setting was changed.

Final signed build `202610300317` was also opened in normal mode. Selecting Place displayed “Location permission has not been requested” and the explicit Allow Location button, with no system permission prompt. That draft was canceled too. The saved scene file still contained Deep Focus, Out & About and Conversation, with zero location triggers. OpenXM was left in its normal device view with the XM3 disconnected. Build/signature verification and whitespace checks passed without compiler warnings.

# MeshMapper First-Run Guide Design

Date: 2026-09-14

Status: Approved in conversation, pending written-spec review

Target release: 1.4.0

Related ticket: #166

## Problem

MeshMapper has several settings and operating rules that are important for accurate mapping, but the explanations are spread across the Map controls, Settings pages, dialogs, and support conversations. New users can start without understanding regional mode restrictions, antenna reporting, CARpeater handling, background location, automatic uploads, or the difference between coverage data and debug logs.

The guide must also reach existing users when 1.4.0 ships because many of these behaviors are new or have changed since they installed the app.

## Goals

- Show every new and existing mobile user a one-time guide when they first run version 1.4.0.
- Let the user skip the entire guide from the welcome prompt or any guide page.
- Keep the guide available for replay from Settings.
- Explain the normal path from connecting a radio through completing a wardrive.
- Explain settings that protect coverage accuracy and mesh airtime.
- Make clear that online coverage uploads automatically and that debug logs are only for support.
- Use concise, human wording and the app's existing visual language.

## Non-Goals

- Do not change wardriving, upload, account, CARpeater, or radio behavior.
- Do not turn the guide into a required setup wizard.
- Do not require account sign-in, device connection, or CARpeater configuration to finish the guide.
- Do not use live coach marks attached to the MapLibre platform view.
- Do not add custom bitmap artwork for the first version.
- Do not show the guide in the retained web target. The published app is iOS and Android.

## Recommended Presentation

Use a two-stage presentation:

1. A welcome dialog appears after the required location disclosure and initial permission prompts have settled.
2. Start Guide opens a full-screen, swipeable PageView using themed cards, existing Material icons, and small native illustrations.

This is preferred over live coach marks because it is stable across screen sizes, connection states, conditional controls, and the native map view. It is also easier to test and keep accurate.

### Welcome Dialog

Title: `Welcome to MeshMapper`

Copy:

> Take a quick tour before your first wardrive. We'll show you how to connect, what each mode does, how to use the map, and which settings keep coverage data accurate.

> You can skip now and open this guide anytime from Settings.

Actions:

- `Skip Guide`
- `Start Guide`

The dialog is not dismissed by tapping outside it. The user always has a clear Skip action.

### Guide Navigation

- Show `Page X of 12` in the header for the instructional pages.
- Keep `Skip Guide` visible on every page.
- Show `Back` after the first page.
- Show `Next` until the final page.
- Show `Finish Guide` on the final page.
- Allow horizontal swiping between pages.
- If the route is closed or the app is terminated without Skip or Finish, do not mark the guide complete. Offer it again on the next launch.
- Skip and Finish both mark guide version 1 complete before closing.
- Finishing an automatic first-run guide returns to the Map tab. Finishing a
  manual replay returns to About & Support, where the user opened it.

## Guide Order and Content

The order follows the normal user journey: connect, configure, map, understand results, and manage data.

### Page 1: Connect Your MeshCore Radio

Title: `Connect Your MeshCore Radio`

Copy:

> Open the Connect tab and choose how your radio is connected. Bluetooth is the usual choice. TCP and USB may also be available on supported devices.

Three illustrated steps:

1. Tap Scan.
2. Select your MeshCore companion.
3. Wait until the status says Connected.

Supporting copy:

> MeshMapper checks your GPS location, signs into your regional zone, prepares the wardriving channel, and detects your radio model. A previously connected radio will be remembered for quicker reconnection.

> MeshMapper detects and reports the radio's expected power. It never changes the radio's actual transmit power.

Use a simplified bottom navigation illustration with Connect highlighted, followed by a radio result and a green Connected state.

### Page 2: Antenna Placement

Title: `Is Your Antenna Exposed?`

Explain the required `External Antenna: Yes / No` control shown on the Map screen. This page is informational because the correct answer depends on the setup used for that drive.

Choose No when:

> The antenna is inside a metal vehicle cabin, metal box, or another enclosure that can reduce RF reception.

Example: the radio and antenna are inside the car.

Choose Yes when:

> The antenna is not enclosed by metal or another object that significantly blocks RF reception.

Examples: a roof-mounted antenna, a handheld radio, or walking with the radio in a pocket.

Why MeshMapper asks:

> This does not change your radio or its transmit power. It records how the antenna was positioned so the community can interpret the coverage data correctly.

Final instruction:

> Choose Yes or No on the Map screen before starting a mode.

Use a native illustration comparing an antenna inside a vehicle with an exposed or carried antenna.

### Page 3: Wardriving Modes

Title: `Wardriving Modes`

Passive Mode:

> Sends nearby discovery requests and continuously listens for received mesh traffic. It creates useful coverage data with low mesh impact and is the normal choice for mapping most regions.

Hybrid Mode:

> Alternates between Active wardriving pings and discovery requests. Like Active Mode, it only appears where the regional administrator allows flood traffic.

Active Mode:

> Sends regular wardriving messages through the mesh and records which repeaters hear them. Active Mode is disabled and hidden in most regions because it can significantly increase mesh utilization. It only appears when the regional administrator chooses to enable it.

Trace Mode:

> Tests the signal path to one selected repeater. It is useful for antenna alignment or checking a specific node.

Regional availability note:

> Most regions only show Passive and Trace modes. This is expected. Passive Mode still sends discovery requests, listens for received mesh traffic, and does a great job mapping the mesh.

Starting and stopping note:

> Tap a mode to start it and tap the running mode again to stop. Wait for Stopping to finish before disconnecting. Status text explains when the app is waiting for GPS, movement, cooldown, or a regional rule.

### Page 4: Map Controls

Title: `Control What You See`

Use an annotated native representation of the Map screen with these labels:

- Map style: change the map background.
- Coverage: show or hide MeshMapper coverage.
- Repeaters: show or hide repeater markers.
- Regions: show or hide regional boundaries.
- Location: center the map on the GPS position and follow movement.
- Direction: keep north at the top or rotate with the direction of travel.
- Rotation lock: prevent accidental map rotation.
- Legend & Info: explain coverage colors, marker types, and map symbols.

Additional callouts:

> Tap a coverage square to see its mapping details.

> Tap a repeater to see its identity, status, administrators, and management options.

> Use the ? button on the wardriving control panel to reopen help for the antenna and mode buttons.

### Page 5: Smart Pinging

Title: `Put Airtime Where It Helps`

Copy:

> Smart Pinging avoids repeating work in map squares that already have recent coverage. It is enabled by default and may be required by your regional administrator.

Flow:

> Covered square -> ping deferred -> uncovered square -> ping sent

Deferred explanation:

> If the control says Deferred, the app is working normally. It holds one ping and sends it as soon as you enter a square without recent two-way or discovery coverage.

Movement protection:

> MeshMapper also requires at least 25 metres of movement between automatic attempts. If you see Move 25 m, continue travelling and the session will resume automatically.

Listening note:

> Received mesh traffic is always recorded because listening adds coverage without transmitting. Manual pings and Trace Mode are not deferred by Smart Pinging.

Regional enforcement:

> Regional administrators may require Smart Pinging in busy regions to reduce unnecessary airtime and protect normal mesh traffic.

Map note:

> Hollow trail markers show where a ping was deferred. You can adjust the recent-coverage window under Settings > Wardriving.

### Page 6: CARpeater Filtering

Title: `Do You Travel With a Repeater?`

Opening copy:

> A CARpeater is a repeater travelling close to your companion, usually in the same vehicle. Its unusually strong nearby signal can create false coverage.

Applicability note:

> If you do not travel with a repeater, there is nothing to configure.

If the user has a CARpeater:

> Enable the CARpeater Filter and report its full public key in Settings > Wardriving > CARpeater.

Why reporting matters:

> MeshMapper can only use valid data passing through your CARpeater when you have enabled the filter and reported which repeater is yours. The app removes your CARpeater from the route and credits the fixed repeater behind it.

> If your CARpeater is not reported, its signals look like unreliable, excessively strong readings and the data is dropped.

What gets kept:

- A direct reading from only the user's CARpeater is dropped.
- A route through the user's CARpeater can still contribute coverage for the repeater behind it.
- Other reported CARpeaters in the region are filtered from the user's results.

Regional sharing note:

> Your CARpeater public key is shared with MeshMapper while the filter is enabled. This allows other wardrivers in your region to filter the same CARpeater too.

Warning:

> Do not disable the strong-signal RSSI filter unless you are certain there is no co-located repeater nearby. Incorrect settings can create false coverage data.

Use a native illustration showing a companion and repeater inside one vehicle, contrasted with a fixed repeater outside it.

### Page 7: Background Location

Title: `Keep Mapping in the Background`

Common introduction:

> MeshMapper can continue wardriving while the app is minimized or the screen is locked.

iPhone content:

> Background Location is required for reliable background wardriving. Open Settings > General > Background Location and allow location access Always.

Show a `Set Up Background Location` action on iPhone. It uses the existing prominent disclosure and permission flow. Declining or failing to grant permission does not block the guide.

Android content:

> No additional background location permission is required. MeshMapper uses a persistent notification while a wardriving mode is active to keep Bluetooth and GPS running.

> Allow MeshMapper notifications so you can see when the background session is active.

Common closing note:

> Background operation does not start a wardriving session by itself. Stop the mode or disconnect when you are finished.

Do not show the iPhone setup action on Android.

### Page 8: Understand Your Results

Title: `See What You Mapped`

Map introduction:

> New observations appear on the Map as you travel. Tap a marker or coverage square to see its details, route, signal information, and repeaters.

Show the real app colors and shapes for these result types:

- BIDIR: the message routed through the mesh and a repeat was heard back.
- DISC: a repeater answered a discovery request.
- TX: the message routed successfully, but no repeat was heard back.
- RX: the radio heard mesh traffic without transmitting.
- DEAD or DROP: the attempt did not produce confirmed coverage.

Log:

> The Log tab shows every TX, RX, discovery, and trace event. The Errors section explains dropped data, connection problems, and CARpeater filtering.

History:

> The History tab saves automatic wardriving sessions. Open a session to review its route on the map, event timeline, and noise-floor graph.

### Page 9: Online and Offline Mode

Title: `Choose Where Your Data Goes`

Online Mode:

> Coverage is queued and uploaded to MeshMapper while you drive. Online Mode checks your regional rules and can use existing coverage for Smart Pinging.

Offline Mode:

> Coverage is saved locally on your phone instead of being uploaded. Use it when mobile data is poor, MeshMapper is undergoing maintenance, or you want to collect without sending anything yet.

Manual upload reminder:

> Offline sessions are not uploaded automatically. When you are ready, open Settings > Data > Offline Sessions and choose Upload. You can also export or delete a saved session.

Switching note:

> Use Go Offline or Go Online on the Connect tab. You can switch before connecting or during a connected session.

Smart Pinging note:

> Smart Pinging is unavailable in Offline Mode because the app cannot check recent server coverage.

### Page 10: Privacy and Safe Use

Title: `Know What You Share`

Public coverage:

> In Online Mode, GPS-tagged coverage is uploaded to MeshMapper and contributes to the public community map.

Broadcast Coordinates:

> Broadcast Coordinates is off by default. When it is off, your real location goes to the MeshMapper server but is not included in the wardriving message sent over the mesh. Turning it on allows other mesh users to receive the coordinates in that message.

Anonymous Mode:

> Anonymous Mode hides your companion name and removes you from the public leaderboard. It does not make the device anonymous to MeshMapper. Its public key is still used to authenticate and associate the session.

Safety:

> Set up your radio and choose a mode before moving. Do not operate the app while driving.

### Page 11: MyMeshMapper Accounts

Title: `Own and Manage Your Mapping Data`

Introduction:

> Signing in to MyMeshMapper is optional, but linking your companion gives you control over the data it reports.

Link proof:

> When you link a connected companion, the app asks the radio to cryptographically sign a challenge. This proves that you control that companion without sharing its private key.

Account benefits:

- See every companion linked to the account.
- View the data and coverage points they reported.
- Delete coverage points from the MeshMapper servers.
- Track mapping points and awards.
- Claim repeaters the user administers.
- Add build and deployment information for administered repeaters through the MyMeshMapper portal.

Claiming a repeater:

> Select a repeater on the Map, tap Manage, sign in with its admin password, and tap Claim. Your MyMeshMapper identity will then be publicly listed as an administrator of that repeater.

Where to start:

> Open Settings > MeshMapper Account to sign in. Connect your companion afterward to link it.

Do not launch account sign-in from inside the guide because the browser round trip interrupts the walkthrough.

### Page 12: Automatic Uploads and Debug Logs

Title: `Just Choose a Mode and Drive`

Online wardriving:

> When an Online Mode session is running, MeshMapper automatically sends your coverage data to the server. All you need to do is drive with a wardriving mode enabled.

> If your connection is temporarily unavailable, coverage waits in the queue and retries automatically. You do not need to upload it yourself.

Offline exception:

> Offline Mode is the only exception. Upload those saved sessions later from Settings > Data > Offline Sessions.

Debug logs:

> Uploading Debug Logs does not upload your coverage. Debug logs are diagnostic files used to investigate app problems.

> Only upload debug logs when you have experienced an issue or a developer has asked you to provide them.

Visually separate a green `Coverage uploads automatically` path from an orange `Debug logs are for support only` path.

The bottom action is `Finish Guide`. Finishing marks guide version 1 complete.
The automatic flow returns to the Map tab, while a manual replay returns to
About & Support.

## Persistence and Triggering

Use a versioned integer, not a boolean.

- Current guide version: `1`.
- Persisted value: the highest guide version explicitly skipped or finished.
- Missing value means `0`, so both new installs and existing users upgrading to 1.4.0 are eligible.
- Show automatically when the persisted value is less than the current version.
- Do not advance the value merely because the welcome dialog or guide route was displayed.
- A future guide can increment the current version deliberately.

Keep this lifecycle state in `AppStateProvider` and persist it as a separate key in the existing `user_preferences` Hive box. It is application lifecycle metadata, not a wardriving preference, so it should not be added to `UserPreferences`.

Suggested provider surface:

- `bool get onboardingGuideStateLoaded`
- `bool get shouldShowOnboardingGuide`
- `Future<void> completeOnboardingGuide()`

The provider owns the mutation and notification. The guide UI must not write Hive directly.

`MainScaffold` owns automatic presentation because it already sequences the first-run disclosure and global dialogs. Add an open guard so provider notifications cannot schedule the dialog more than once. The guide has priority over account-link and CARpeater re-entry prompts while it is open. Those prompts can appear after the guide closes if still due.

## Manual Replay

Add a `Quick Guide` row to Settings > About & Support with a help icon and a short subtitle such as `Learn connections, modes, mapping, and data`.

Opening the guide manually starts at the first instructional page without showing the welcome dialog. Replaying, closing, or finishing it does not make the guide automatically due again.

## Visual Direction

- Use Material 3 surfaces, the current theme colors, and existing icon vocabulary.
- Use one strong accent color per page, drawn from the existing Map and mode colors.
- Prefer simple containers, arrows, radio waves, map squares, and paired comparison cards built in Flutter.
- Use real app colors for mode and coverage explanations.
- Do not embed screenshots. They become stale as layouts and labels change.
- Avoid decorative animations. A short page transition and progress animation are sufficient.
- Keep each page vertically scrollable for small phones and landscape orientation.
- Provide semantic labels for icon-only illustrations and controls.
- Keep navigation targets at least 48 logical pixels high.

## Error and Edge Cases

- Wait for guide state to load before deciding whether it is due.
- Do not stack the guide on the location disclosure, system permission prompt, account-link prompt, CARpeater re-entry prompt, or another modal.
- A failed persistence write must leave the guide due for the next launch and log a tagged error.
- The iPhone background permission flow may return without Always permission. Continue the guide normally.
- Android system back or an interrupted process does not mark the guide complete.
- Manual replay must work when connected, disconnected, online, or offline and must not change session state.
- The guide must not start, stop, connect, disconnect, or upload anything.

## Verification

Add focused tests for:

- A missing persisted version makes guide version 1 due.
- Persisted version 1 suppresses automatic presentation.
- A lower stored version becomes due when the current guide version increases.
- Skip persists completion and closes the guide.
- Finish persists completion and returns to the Map tab.
- Closing without Skip or Finish does not persist completion.
- Manual replay remains available after completion.
- The automatic prompt waits until permission disclosure handling and guide-state loading finish.
- Repeated provider notifications do not open duplicate dialogs.
- Android receives the explicit `No additional background location permission is required` content and no setup button.
- iPhone receives the Always-permission content and setup button.
- Key copy is present for regional mode restrictions, CARpeater pass-through, Smart Pinging enforcement, automatic uploads, and debug-log use.
- The guide renders without overflow in portrait and landscape at the project's supported phone sizes.

Run:

- `flutter analyze`
- Focused onboarding widget and provider tests
- The full relevant test suite

Review the final diff to confirm that this feature changes only onboarding, help entry points, and guide persistence.

# Changelog

Every release of Printer Hub (app, home bridge, relay and Orca plugin ship together).
Downloads: [GitHub releases](https://github.com/dragonemprorx90/printer-hub/releases).

## 1.23.0 — unreleased

- New alerts: "first layer done" (check it before walking away) and "almost done" (about 10 minutes left). Both are in Settings → Notifications.
- Console: ↑/↓ recall earlier commands (with a Recent list on iPhone), and a button copies the whole output.
- Find models: sign out of Creality Cloud, open a model on its website, a picture counter, pull to refresh, remembered searches per site, and a question before downloading files over 100 MB. Clearer messages when you're offline or a site is slow.
- Files: a weight stat on each file, K2 file details load once and then open instantly, and an empty folder offers Find models.
- Settings → Model sites shows and clears your Creality Cloud sign-in and Thingiverse token. Settings backups no longer include them.
- History: a job printed from several spools is priced at their average, and the CSV export has a grams column. The wall view shows when each print will finish.
- Home bridge: removes camera snapshots older than 180 days (or beyond the newest 3000), says at start whether slicing is ready, and has --version.

## 1.22.0 — 2026-11-09

- Find models online: Files → the globe button searches Printables, Creality Cloud and Thingiverse, or browses MakerWorld. G-code or a 3MF already sliced for your K2 Plus or U1 goes straight to the printer; anything else is sliced on your home bridge first.
- Creality Cloud downloads use your account: sign in once on Creality's own page inside the app. Thingiverse needs a free app token from thingiverse.com/developers.
- K2 Plus files now show print time, filament per slot, colours, layer height and slicer, read from the file itself (the K2 doesn't report them).

## 1.21.0 — 2026-11-09

- Slice from your phone: pick an STL, 3MF or STEP model in Files → Upload, choose quality and filament (one per toolhead on the Snapmaker U1), and the G-code lands on the printer with its preview and Print button. Works at home and away.
- Slicing runs on your home bridge with OrcaSlicer's own K2 Plus and U1 profiles, so your models stay private. Turn it on by re-running the bridge installer, or add slicer to COMPOSE_PROFILES (setup guide, part 5).

## 1.20.1 — 2026-11-09

- DragonBreath: if the heater accepts "Dry filament" but doesn't start drying, the app now says why (its mode, who controls it, or a safety lock) instead of doing nothing.

## 1.20.0 — 2026-11-09

- Faster camera on the Creality K2: the app remembers where the camera is, connects as soon as the first network route is ready, and every view of a printer (preview, fullscreen) shares one live connection that stays warm for 45 seconds, so going back or fullscreen no longer waits for the camera to free up.
- Orca plugin: the camera picture now works for the K2 too, taken from the app's live camera.
- Home bridge: a new one-command setup for any NAS, Raspberry Pi or PC with Docker (deploy/install.sh), with an optional K2 camera helper. Full guide in docs/SETUP.md and a printable PDF.

## 1.19.0 — 2026-11-09

- Motion: switching tabs fades the page in and its cards arrive one after another; printer cards, files and history rows slide in the same way.
- Cards sink slightly when pressed, status pills change colour smoothly, and the "Printing" dot gently pulses.
- Temperatures and progress numbers no longer jiggle as digits change.
- Respects "Reduce motion" in system settings.
- Orca plugin 3.3: buttons respond to hover and press.

## 1.18.1 — 2026-11-09

- iPhone: "Update" asks whether to install with LiveContainer or SideStore and hands the new version straight to it.

## 1.18.0 — 2026-11-09

- Mac: updates install themselves. Printer Hub downloads the new version in the background, installs it, then asks you to restart. (Install this version by hand once; from then on it's automatic.)
- iPhone: "Update" hands the new version straight to SideStore instead of opening a download link.
- Faster: Files and History load in the background as soon as a printer connects, and show at once when you come back to them.

## 1.17.0 — 2026-11-09

- A tidier, more consistent look: one set of corner sizes and text sizes across every screen, and the same style for "nothing here" and error messages.
- Easier to read in light mode: printer status colours are darker on white, and red buttons use a deeper red.
- History: finished prints show in blue like "Complete" elsewhere, cancelled ones in grey.
- Orca plugin 3.2: matches the app's look, with rounded cards and buttons, a red or amber edge on printers that need attention, dimmed offline printers, and colours that suit Orca's light theme.

## 1.16.1 — 2026-11-09

- Orca plugin 3.1: when Orca starts it opens the Printer Hub panel and also shows a notification with an "Open Printer Hub" link, in case the panel didn't open.

## 1.16.0 — 2026-11-09

- Orca plugin 3.0: camera picture, layer / finish time, temperatures with targets, heater status, filament mismatch warnings against Orca's slots, and an "in Orca" badge on each printer.
- Plugin controls: temperatures and preheat (from Orca's filament), home, motors off, E-stop, fans, speed, flow, Z offset, pause at layer, macros, exclude object, DragonBreath drying / filter / fault clear, bed mesh range.
- Plugin History (pictures, success rate, reprint), Spools (grams left, low warning, load into a lane, add a spool) and Rules (on/off).
- Orca notifications when a print finishes, fails or pauses, and when the chamber reaches its temperature; settings for refresh rate, compact cards and problems first.

## 1.15.0 — 2026-11-09

- Orca plugin 2.0: opens by itself when Orca starts; after closing it, click "Open Printer Hub" in Orca's notification to bring it back.
- Removed "Use this printer in Orca". Each printer card shows its Orca connection (127.0.0.1 and port) to enter once; Orca's own Filament sync then loads the colours.

## 1.14.2 — 2026-11-09

- Orca plugin 1.4: fixes the K2 not syncing in Orca (Orca used port 80 instead of Printer Hub's). Save the plugin again, then press "Use this printer in Orca" once more.

## 1.14.1 — 2026-11-09

- Fix: Orca could reach the wrong printer (the K2 got the U1's colours). Each printer now keeps its own local Orca address for good. Press "Use this printer in Orca" once more for each printer.

## 1.14.0 — 2026-11-09

- Orca works with your printers from anywhere: Printer Hub runs a local Moonraker for each printer (127.0.0.1:7130, 7131, …) that reaches it at home or through your home bridge. Orca's device page, filament sync and printing go through it.
- Orca plugin 1.3: "Use this printer in Orca" points Orca at that local address.

## 1.13.0 — 2026-11-09

- Orca plugin 1.2: "Use this printer in Orca" loads the matching Orca printer preset (bed size, nozzles), connects it to the printer with Orca's own Snapmaker or Creality agent, and sets each filament slot to the loaded material. Then Orca's sync button next to Filament loads the colours.

## 1.12.1 — 2026-11-09

- Home bridge: the U1 filament data Orca reads now replaces old entries instead of adding duplicates.

## 1.12.0 — 2026-11-09

- Orca plugin 1.1: each printer's loaded filaments, light / pause / resume / cancel, and "Sync colours to Orca", which sets Orca's filament slots to the printer's colours and materials.
- The home bridge now publishes the U1's lanes in the standard format Orca reads, so Orca's own device tab and Sync filaments work with the U1 (the K2's CFS already works).

## 1.11.0 — 2026-11-09

- Orca Slicer link (Mac): add Printer Hub as a physical printer in Orca (Octo/Klipper, 127.0.0.1:7126). Print or Send opens Printer Hub, which uploads at home or from away and shows print setup.
- Printer Hub plugin for Orca Slicer 2.5+: a live printer panel beside the 3D view (Settings → Orca Slicer → Save the Orca plugin).

## 1.10.0 — 2026-11-09

- U1 Print setup, instead of Snapmaker's cloud-only screen: choose which head prints each filament (with grams), turn on auto bed leveling, flow calibration or timelapse, then print. Works in LAN mode and from away.
- Upload Snapmaker Orca .3mf files: the app takes the sliced plate's G-code (and asks which plate if there are several).

## 1.9.0 — 2026-11-08

- Rules: turn each one on or off, and copy a rule to all your printers.
- Recent alerts: see what your home bridge sent (Tools → Away from home).
- Low-spool alert from the home bridge after a print (under 100 g by default).
- History: filament used per week.
- Bed mesh history: save a mesh and see how its range changes over time.
- Files: long-press to select several, then queue or delete them together.
- A short welcome tour for new installs.

## 1.8.0 — 2026-11-08

- Dryer schedule: a rule like "every day at 02:00 → dry filament 55°C for 6 h".
- Pictures during a print: a rule "every 10 min while printing → save a picture"; History shows them in order.
- Spool QR labels (Spoolman format), and scan a label to load that spool into a lane.

## 1.7.0 — 2026-11-08

- Print sheet shows grams needed per lane against grams left on its spool, and warns when it will run out.
- Lane editor: "Choose spool" after loading a new roll.
- History shows the spool a print used and its real cost from the spool price (when Spoolman tracks it).
- Rules: new triggers (first layer, % progress, paused, heater fault) and a "send me a picture" action.
- Send a test alert and show the alerts topic as a QR (Tools → Away from home).
- Tap a printer's icon to give it its own colour.
- Back up and restore all settings (Settings → Printers).

## 1.6.2 — 2026-11-08

- Add spool: pick a lane and type only the weight. The material and colour come from the lane, and the spool is linked to it.

## 1.6.1 — 2026-11-08

- Send a file to another printer from its file sheet, and start it there.

## 1.6.0 — 2026-11-08

- Rules: "when a print finishes, turn the light off", or every day at a set time. Your home bridge runs them, even with the app closed.
- Pictures of each print: tap a print in History to see its first layer and the end (taken by your home bridge).
- Add spools to Spoolman from the app.
- Printer health: CPU, memory, storage, versions and warnings (Tools).
- Cancelling or restarting from away asks twice.

## 1.5.1 — 2026-11-08

- This screen: see what changed after each update.

## 1.5.0 — 2026-11-08

- Print sheet shows which lane feeds each tool, warns on a mismatch, and lets you remap a tool to another lane.
- DragonBreath panel counts down the drying time.
- Quiet hours for home bridge alerts (QUIET_HOURS).
- Rotate or mirror the camera, per printer.
- Wall can sort problems first.
- Relay delay shown on the "from away" icon.
- Vibrate and sound when a print finishes, fails or pauses.

## 1.4.0 — 2026-11-08

- Spoolman: set the active spool or link a spool to a U1 lane.
- Pause at layer, and heat the chamber before a print.
- Alerts with a camera picture, plus first layer, 10 min left and heater fault alerts.
- DragonBreath filter runs during ABS/ASA/PC/PA prints.

## 1.3.3 — 2026-11-08

- U1 filament lanes, DragonBreath drying and fault clear, timelapse videos.
- Printer screen works from away.

## 1.3.2 — 2026-11-08

- Scan QR codes: remote access code and printer import

## 1.3.1 — 2026-11-08

- Control the Snapmaker U1 cavity light
- Go2rtc: longer ffmpeg timeout so the K2 camera starts first time

## 1.3.0 — 2026-11-08

- Cameras: Snapmaker U1 (camera-streamer WebRTC) and camera from away
- Mac: allow incoming WebRTC video; camera retries when the K2 is busy
- Image job: create bridge/build before compiling
- Ship the Mac app as a DMG
- Publish the home bridge as a Docker image (amd64 + arm64)
- Bridge image: make the binary executable after upload

## 1.2.0 — 2026-11-05

- Point the NAS bridge at the deployed relay
- Alerts with the app closed

## 1.1.0 — 2026-11-05

- First release

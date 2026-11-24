# Printer Hub

[![Latest release](https://img.shields.io/github/v/release/dragonemprorx90/printer-hub?label=release)](https://github.com/dragonemprorx90/printer-hub/releases/latest)
[![Build](https://img.shields.io/github/actions/workflow/status/dragonemprorx90/printer-hub/build.yml?label=build)](https://github.com/dragonemprorx90/printer-hub/actions/workflows/build.yml)
![Platforms](https://img.shields.io/badge/app-iPhone%20%C2%B7%20iPad%20%C2%B7%20Mac-informational)
![Bridge](https://img.shields.io/badge/bridge-Docker%20amd64%20%C2%B7%20arm64-informational)

Watch and control your Klipper / Moonraker 3D printers from your phone or Mac, at home and from anywhere. It works with the Creality K1 / K2 Plus (with CFS), the Snapmaker U1, Voron, and anything else running Moonraker.

**[Setup guide](docs/SETUP.md)** · **[Setup guide (PDF)](docs/Printer-Hub-Setup.pdf)** · **[Changelog](CHANGELOG.md)** · **[Download](https://github.com/dragonemprorx90/printer-hub/releases/latest)**

## Features

**Watch**
- Live camera: Creality K1/K2 and Snapmaker U1 WebRTC, plus MJPEG. Fullscreen zoom, snapshots, and a camera wall for a spare tablet.
- Status, a progress ring with the finish time, and temperatures with a 10-minute graph.
- Alerts with the app closed: finished, failed, paused, CFS humidity and low spool, each with a picture.
- Failure detection: your home bridge spots spaghetti on the camera, alerts you and can pause the print (Obico's open model, on your NAS).

**Control**
- Move, home, extrude, fans, speed and flow, Z baby-stepping, pressure advance.
- Creality CFS: slot colours, humidity, load and unload. Snapmaker U1 tool heads and the printer's own screen.
- Skip a failed object mid-print, bed mesh heat-map, calibration wizards.
- Macros with favourites and parameters, plus a console.

**Files and history**
- Files with thumbnails, folders, a print queue, a 2D layer preview and "start later".
- History with pictures, cost estimates, monthly charts and CSV export. Spool tracking (Spoolman).

**Slice from your phone**
- Pick an STL, 3MF or STEP model and see it on your printer's plate in 3D. Move, turn, scale or lay it on a face, or let Orca auto-orient it.
- Change the print settings you care about (layer height, walls, infill, supports, brim, speed, flow, temperatures, a filament per U1 toolhead), slice, check the time, filament and layers, and print. OrcaSlicer runs on your home bridge, not in someone's cloud.
- Find models online: search Printables, Creality Cloud and Thingiverse, or browse MakerWorld, inside the app. Files already sliced for your printer print straight away; the rest are sliced at home, opened in OrcaSlicer on the Mac, or sent from the iPhone to your Mac's OrcaSlicer.

**Workshop and stats**
- Odometer, records and streaks, a calendar of print days, success rate by material and month, monthly cost, and why prints failed.
- Maintenance log, ready-made task lists, nozzle wear, spare parts and daily reminders.
- Filament inventory (with or without Spoolman), shopping list, colour names, price per gram, drying guide and log, material notes.
- A pre-print checklist, notes on prints, and History search and filters.
- **Needs you**: one list of what's paused, failed, offline, damp, due or running low (also in the Orca panel).
- **Quote** what to charge for a print, and **Calculators** for rotation distance, flow, pressure advance and temperature towers, shrinkage, max speed, spool weight, will-it-fit and more.
- Compare first layers (or finished prints) side by side, a bed screw helper from the mesh, and stats across all your printers.

**Everyday extras**
- Queue: reorder, finish time per job, "bed is clear, start next". Files: tags, tidy up (space, copies, old files), finish-at scheduling, times printed before.
- Camera: brightness, contrast, grid, crosshair, frame rate, stamped snapshots, remembered zoom.
- Overview: pause at a height, print again, pace against the slicer, copy status, keep screen on, heaters off.
- Alerts: quiet hours, mute a printer, nozzle temperature drift. Bridge: run-out, chamber ready, offline, still paused, bed cooled, daily summary, snooze, webhooks, rule days and hours, a status page with Prometheus metrics, and its log in the app.
- iPhone: quick actions, `printerhub://` links, open G-code from Files, Siri Shortcuts. Mac: a menu-bar menu of printers, Dock badge, open at login, keyboard shortcuts.
- Text size, high contrast, °F, 12-hour time, side-by-side on wide screens, VoiceOver labels.

**From anywhere: free and end-to-end encrypted**
- A small home bridge on your NAS, Raspberry Pi or PC, plus a free Cloudflare relay. No open router ports.
- The app switches between home and away by itself.

**OrcaSlicer (Mac)**
- Send prints straight from Orca.
- A live printer panel inside Orca 2.5+ with camera, controls, filaments, history, rules, queue and stats.

## Quick start

1. **App**: install `PrinterHub-x.y.z.ipa` with SideStore or LiveContainer on iPhone, or `PrinterHub-x.y.z.dmg` on the Mac, from the [latest release](https://github.com/dragonemprorx90/printer-hub/releases/latest). Tap **+** and pick your printer.
2. **From anywhere (optional)**: deploy the [relay](docs/SETUP.md#2-relay-once), then on your NAS, Pi or Linux PC run:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/dragonemprorx90/printer-hub/main/deploy/install.sh | sh
   ```
   Paste the pairing code it prints into **Edit printer → Remote access code**.

3. **Find models (optional)**: in **Files**, tap the globe to search Printables, Creality Cloud and Thingiverse, or browse MakerWorld. Ready files print straight away, and for models you choose: slice on your home bridge, open in OrcaSlicer (Mac), or send to your Mac's OrcaSlicer (iPhone).

Every option (NAS web UIs, Docker Desktop, without Docker, alerts, OrcaSlicer, slicing from the app, troubleshooting) is in **[docs/SETUP.md](docs/SETUP.md)**.

## How it works

```
                 at home: direct on your Wi-Fi
   ┌────────┐ ─────────────────────────────────────────▶ ┌─────────┐
   │  App   │                                            │ Printer │
   │ iPhone │      ┌──────────────┐     ┌────────────┐   │Moonraker│
   │  Mac   │ ◀──▶ │ Relay        │ ◀──▶│ Home bridge│◀─▶│         │
   └────────┘      │ (Cloudflare) │     │ NAS/Pi/PC  │   └─────────┘
       away        └──────────────┘     └────────────┘
                   only sealed frames    ChaCha20-Poly1305, keys from
                                         your pairing code
```

The relay only forwards sealed frames. It can't read them or send commands. Only devices with your pairing code can talk to the bridge. See [SECURITY.md](SECURITY.md).

## Project layout

| Folder | What |
|---|---|
| `lib/` | The Flutter app (iOS, iPadOS, macOS) |
| `bridge/` | Home bridge (Dart) and its Docker image |
| `deploy/` | Ready-to-run Docker Compose setup and installer for the bridge |
| `slicer/` | Slicer container for the bridge (OrcaSlicer CLI + a small Python API) |
| `detector/` | Failure detector container for the bridge (Obico's ONNX model, CPU) |
| `relay/` | Cloudflare Worker relay |
| `packages/hub_link/` | Pairing codes and encryption shared by the app and the bridge |
| `orca-plugin/` | OrcaSlicer 2.5+ panel (`printer_hub.py`) |
| `docs/` | Setup guide, PDF, UI style spec (`docs/designs/`) |
| `tool/` | Maintenance scripts (changelog, PDF) |

## Build from source

You need Flutter 3.47+.

```bash
flutter test
flutter build macos            # Mac app
flutter build ios --no-codesign
cd bridge && dart compile exe bin/bridge.dart -o printer-hub-bridge
```

Releases are built by [`.github/workflows/build.yml`](.github/workflows/build.yml). Pushing a `v*` tag publishes the app, the bridge binaries and the multi-arch Docker image (`ghcr.io/dragonemprorx90/printer-hub-bridge`). See [CONTRIBUTING.md](CONTRIBUTING.md) for the release checklist.

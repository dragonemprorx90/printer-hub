# Cloud slicing (design, built in 1.21.0)

Pick a model (STL / 3MF / STEP) on iPhone or Mac, slice it on the home server,
preview it, print it. No desktop slicer needed.

## Recommended: a slicer container next to the home bridge

```
App ──(E2E relay, same as today)──> bridge ──/slicer/*──> slicer container ──> OrcaSlicer CLI
                                                                │
                                                                └─ uploads G-code to Moonraker (LAN)
```

- **New container `printer-hub-slicer`**: OrcaSlicer's CLI (the Linux AppImage,
  unpacked, run headless) plus a small HTTP wrapper (Python stdlib, no extra
  packages). Turned on in `deploy/docker-compose.yml` with
  `COMPOSE_PROFILES=slicer`, the same opt-in pattern as `creality`. It listens only on `127.0.0.1:7070`.
- **Bridge**: one more route in `target()`: `/slicer/...` goes to `SLICER_URL`,
  default `http://127.0.0.1:7070`. This is the same pattern as `/dragonbreath/`. `/hub/*` and every
  existing route stay as they are.
- **Jobs run in the background.** The bridge drops relayed requests after 60 s, and a slice can
  take minutes:
  - `GET  /slicer/presets` lists printer, process and filament presets.
  - `POST /slicer/jobs?printer=…&process=…&filaments=…` takes the model bytes and returns `{id}`.
    Since 1.24 (slice editor), two optional parameters:
    - `settings`: JSON `{"process": {key: value}, "filaments": [{…} or null per toolhead]}` with
      whitelisted Orca keys (`SETTINGS` in `server.py`). They're written into the job's preset stubs on
      top of the chosen preset. `nozzle_temperature` also sets the first layer; `bed_temperature` sets
      every plate type.
    - `arrange=0`: slice the model where it is. The app bakes its placement into the STL it sends.
  - `GET  /slicer/jobs/<id>` returns `{state, progress, error, file, time, filament}`.
  - `POST /slicer/mesh?printer=…&name=…[&orient=1]` (1.24) returns the model as a binary STL centred on
    the plate, for the editor's 3D view: STEP meshed with gmsh, 3MF objects merged, `orient=1` runs
    Orca's auto-orient. It answers synchronously, so a STEP that takes over the bridge's 60 s limit
    fails. Make it a job like slicing if that happens in practice.
  - `/slicer/presets` also returns each printer's `bed` (build volume in mm); the app takes its absence
    to mean a slicer from before the editor and slices the old way.
- **The G-code stays on the LAN.** When a slice finishes, the container uploads the G-code straight to
  the printer (`PRINTER_HOST` from the same `.env`). The phone then uses the
  preview it already has (`lib/gcode.dart`) and the normal "Start print". Large
  G-code files never travel over your hotspot.
- **Presets**: OrcaSlicer's built-in system profiles for the Creality K2 Plus (0.4 nozzle) and the
  Snapmaker U1, plus any of your own. Export them from desktop Orca and drop
  them in `./slicer-profiles/`. On the U1 you pick a filament for each of the 4
  toolheads. A single-colour STL goes to T0. A painted 3MF keeps its own colour
  assignments.

### App flow (Files tab)

"Upload" becomes **Upload G-code** and **Slice a model**. For a model:

1. Pick the file.
2. Choose printer, process and filament (or one filament per toolhead on the U1). The app remembers your last choice.
3. Tap **Slice**. A progress bar shows while the job runs.
4. A result card shows time, filament used and the layer preview, with **Print** and **Keep**.

### Limits and risks

- OrcaSlicer 2.5 ships Linux AppImages for both amd64 and arm64, so the image covers a NAS, a PC and a Pi.
- Orca's CLI can't read STEP. The container meshes STEP to STL with gmsh first.
- Orca's CLI only resolves `inherits` for presets in its user folder, so each
  job writes small stub presets there and deletes them afterwards.
- Image size is about 1 GB. Slicing uses one CPU core for 10 s to a few minutes.
- Models go up through the relay, even at home. That's one path to keep working.
  A direct LAN path can come later if uploads feel slow.

## Alternative: hosted slicing service

Hosted services charge a monthly subscription or a fee per slice, and most
are built for print farms. Your models and printer settings would sit on a
third party's servers, outside the end-to-end encryption. Their K2 Plus and U1 profiles
would be theirs, not your tuned ones, and slicing breaks if the service changes or
shuts down. Not recommended.

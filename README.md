# Printer Hub

Control and watch your Klipper / Moonraker 3D printers from your phone or Mac:
Creality K-series (K1, K2 Plus with CFS), Snapmaker U1, Voron and anything
else running Moonraker.

- Live status, temperatures with a 10-minute graph, progress ring and finish time
- Live camera (including the Creality K2 WebRTC camera), snapshots, fullscreen zoom
- Move, extrude, fans, speed / flow, Z baby-stepping, pressure advance
- Creality CFS: slot colours, humidity alerts, load / unload
- Files with thumbnails, folders, print queue, 2D layer preview, start later
- Skip a failed object mid-print, bed mesh heat-map, calibration wizards
- Macros with favourites and parameters, console
- History with cost estimates, monthly charts and CSV export
- Notifications, Mac menu-bar status, wall view, light / dark themes
- **Remote access from anywhere, free and end-to-end encrypted** (see below)

## Install

Download from the [latest release](../../releases/latest):

| File | For |
|---|---|
| `PrinterHub-x.y.z.ipa` | iPhone / iPad. Unsigned: install with **SideStore** or AltStore, which sign it with your own Apple ID. |
| `PrinterHub-x.y.z-macos.zip` | Mac (Apple Silicon). First launch: right-click → Open. |

The app checks this repo's releases for updates (Settings → Updates).

## Remote access (optional, free)

Printer Hub talks to your printer directly on your Wi-Fi. To use it away from
home without opening router ports:

```
Phone ⇄ your relay (Cloudflare, free) ⇄ home bridge (NAS / Pi / Mac) ⇄ printer
```

Everything between the phone and the bridge is encrypted end to end
(ChaCha20-Poly1305, keys from a pairing code). The relay only forwards sealed
frames: it cannot read them or send commands.

1. **Relay.** With a free Cloudflare account:
   ```bash
   cd relay && npm install && npx wrangler login && npx wrangler deploy
   ```
   Note the `https://printer-hub-relay.<you>.workers.dev` address.
2. **Home bridge.** On an always-on device on the same network as the printer:
   - NAS with Docker: copy `bridge/` with the Linux binary from the release
     into `bridge/build/`, set `RELAY_URL` and `PRINTER_HOST` in
     `bridge/docker-compose.yml`, and start the project.
   - Or run the binary directly:
     `printer-hub-bridge --relay <relay url> --printer <printer ip>`
3. **Pair.** The bridge prints a `PHB1:…` code and QR on first start. Paste it
   into the printer's **Remote access code** (Edit printer). Treat it like a
   password; `--reset` on the bridge issues a new one and locks out old phones.

At home the app connects directly; away it goes through the bridge, and it
switches back automatically when you return.

## Build from source

Flutter 3.47+. `flutter test`, then `flutter build macos` / `flutter build ios
--no-codesign`. The release workflow in `.github/workflows/build.yml` builds
every artifact; push a `v*` tag to publish one.

| Folder | What |
|---|---|
| `lib/` | The app |
| `packages/hub_link/` | Pairing codes and encryption shared by app and bridge |
| `relay/` | Cloudflare Worker relay |
| `bridge/` | Home bridge (Dart) and Docker files |

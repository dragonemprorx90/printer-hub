# Setting up Printer Hub

This takes about 15 minutes. Only part 1 is required. Parts 2–5 add access from away, alerts, OrcaSlicer and slicing from the app.

| Part | What you get | You need |
|---|---|---|
| [1. The app](#1-the-app) | Control and camera at home | iPhone/iPad or a Mac |
| [2. Relay](#2-relay-once) | The cloud mailbox used for access from away | A free Cloudflare account |
| [3. Home bridge](#3-home-bridge) | Access from anywhere, alerts with the app closed | Any always-on box with Docker: NAS, Raspberry Pi (64-bit), PC |
| [4. OrcaSlicer](#4-orcaslicer-mac) | Send prints from Orca, plus a printer panel inside Orca | Mac app + OrcaSlicer 2.5+ |
| [5. Slicing](#5-slicing-from-the-app) | Slice STL / 3MF / STEP models from your phone, no desktop slicer | The home bridge + ~1 GB of disk |

```
Phone ⇄ relay (Cloudflare) ⇄ home bridge (NAS / Pi / PC) ⇄ printer
         sealed frames only    end-to-end encrypted with your pairing code
```

## 1. The app

Download from the [latest release](https://github.com/dragonemprorx90/printer-hub/releases/latest).

**iPhone / iPad**: `PrinterHub-x.y.z.ipa`. The file is unsigned, so install it with **SideStore**, **LiveContainer** or AltStore; they sign it with your own Apple ID. Later updates come through the app (Settings → Updates → Update), which hands the new version to LiveContainer or SideStore.

**Mac (Apple Silicon)**: `PrinterHub-x.y.z.dmg`. Open it and drag Printer Hub to Applications. The first time, right-click the app and choose Open. From 1.18 on, the Mac app installs its own updates and asks you to restart.

**Add a printer.** Tap **+**. Printers on your network are found automatically; otherwise enter the printer's IP address (from the printer's network screen). That's all you need at home.

Supported: anything running Klipper with Moonraker, including Creality K1/K2 (rooted or stock with Moonraker), Snapmaker U1 and Voron.

## 2. Relay (once)

The relay is a tiny Cloudflare Worker that passes sealed messages between your phone and your bridge. It cannot read them. The free plan is plenty.

1. Install [Node.js](https://nodejs.org) (LTS) on any computer.
2. Get the relay: download `printer-hub-relay-x.y.z.tar.gz` from the release and unpack it, or use the `relay/` folder of this repo.
3. In that folder:
   ```bash
   npm install
   npx wrangler login      # opens the browser to sign in to Cloudflare
   npx wrangler deploy
   ```
4. Note the address it prints: `https://printer-hub-relay.<you>.workers.dev`.

## 3. Home bridge

The bridge runs on a device that stays on and is on the same network as the printer. It keeps one outgoing connection to your relay, so you don't open any router ports. It also sends **alerts** (finished, failed, paused, CFS humidity, low spool) to the free **ntfy** app, even when Printer Hub is closed.

The image is published for **amd64** (most NAS units and PCs) and **arm64** (Raspberry Pi 4/5 with a 64-bit OS, ARM NAS units).

### Linux, Raspberry Pi or NAS with SSH: one command

```bash
curl -fsSL https://raw.githubusercontent.com/dragonemprorx90/printer-hub/main/deploy/install.sh | sh
```

It asks for the printer's IP, your relay URL, whether the printer is a Creality K1/K2 (its camera needs a helper to work from away), and whether to turn on [slicing](#5-slicing-from-the-app). It then starts everything in `~/printer-hub-bridge` and prints your **pairing code**. Run it again to change answers; your pairing is kept.

Don't have Docker yet? On a Pi or Linux PC: `curl -fsSL https://get.docker.com | sh`, then log out and back in.

### NAS with a web UI (UGREEN, Synology, QNAP, Unraid, TrueNAS)

1. Make a folder, e.g. `docker/printer-hub-bridge`.
2. Put the two files from [`deploy/`](../deploy) in it: `docker-compose.yml`, and `.env.example` renamed to `.env`.
3. Edit `.env`: set `PRINTER_HOST` and `RELAY_URL`. For a Creality K1/K2, uncomment the two camera lines.
4. In the NAS's Docker app, create a **Project / Stack** from that folder and start it. Synology calls it Container Manager → Project; UGREEN calls it Docker → Project.
5. Open the bridge container's log. The pairing code (`PHB1:…`) and a QR code are printed there.

### Windows or Mac PC with Docker Desktop

1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/). In Settings → Resources → Network, turn on **Enable host networking**.
2. Download `docker-compose.yml` and `.env.example` from [`deploy/`](../deploy) into a folder. Rename the second file to `.env` and edit it as above.
3. In that folder, run `docker compose up -d`, then `docker compose run --rm bridge --show-code`.

A PC only works while it's on and awake. A NAS or Pi is the better home for the bridge.

### Without Docker

Each release has plain binaries (`printer-hub-bridge-x.y.z-linux-x64`, `-linux-arm64`, `-macos-arm64`):

```bash
chmod +x printer-hub-bridge-*
./printer-hub-bridge-* --relay https://printer-hub-relay.<you>.workers.dev --printer 192.168.1.50
```

### Pair the app

In the app, open **Edit printer → Remote access code**. Paste the `PHB1:…` code, or scan the QR code. Treat the code like a password. To lock out every phone and issue a new code, run:

```bash
docker compose down && docker compose run --rm bridge --reset --show-code && docker compose up -d
```

At home the app talks to the printer directly. Away, it goes through the bridge, and it switches back by itself when you return.

### More than one printer

Run one bridge per printer: copy the folder, then change `PRINTER_HOST` in the copy's `.env`. Each copy has its own `data/` and its own pairing code.

### Alerts

On first start the bridge log shows an **ntfy topic**. Install ntfy ([iOS](https://apps.apple.com/app/ntfy/id1625396347), [Android](https://ntfy.sh)) and subscribe to that topic. To set quiet hours, humidity and spool limits, or turn alerts off, see the options in `.env`.

### Updating the bridge

```bash
cd ~/printer-hub-bridge && docker compose pull && docker compose up -d
```

## 4. OrcaSlicer (Mac)

Printer Hub on the Mac runs a small local service on `127.0.0.1:7126` (Settings → Orca Slicer).

**Send prints.** In Orca, open the printer's connection settings:
- Host type: **Octo/Klipper**
- Hostname: `127.0.0.1:7126`. To skip the printer question, add the printer's name, e.g. `127.0.0.1:7126/k2-plus`.

Press **Print** or **Send**. Printer Hub uploads the file (at home or through the bridge) and opens print setup.

**Printer panel** (Orca 2.5+). Download `printer_hub.py` from the release, or save it from Settings → Orca Slicer. Install it from Orca's **Plugins** dialog. A panel opens beside the 3D view with every printer: camera, progress, temperatures, controls, filaments, spools, history and rules.

## 5. Slicing from the app

Pick an **STL, 3MF, STEP or OBJ** model in **Files → Upload** (or drop it on the Mac window). Choose the quality and filament, tap **Slice**, and the G-code lands on the printer with its layer preview and the **Print** button. It works at home and away.

```
App ─(encrypted relay)─▶ home bridge ─▶ slicer container (OrcaSlicer 2.5) ─▶ G-code to the printer (LAN)
```

Slicing runs in a second container next to the bridge, using OrcaSlicer's own Creality K2 Plus and Snapmaker U1 profiles (0.4 mm nozzle). On the U1 you pick a filament for each of the 4 toolheads and which one prints the model. A 3MF with painted colours keeps them. Your model never leaves your home except inside the encrypted relay, and nothing is uploaded to a slicing service.

**Turn it on.** Re-run the installer and answer **y** to "Slice models from the app?". Or add `slicer` to `COMPOSE_PROFILES` in `.env` (e.g. `COMPOSE_PROFILES=slicer`, or `creality,slicer` for a K2), then:

```bash
docker compose pull && docker compose up -d
```

- The image is about 1 GB, for amd64 and arm64. A slice takes 10 s to a few minutes; a NAS or Pi 5 is fine, a Pi 4 is slow.
- **Two printers on one machine:** each bridge folder runs its own slicer. Give the second one `SLICER_PORT=7071` in its `.env`.
- **Your own presets:** in desktop Orca, export a process or filament preset and copy the `.json` into `slicer-profiles/process/` or `slicer-profiles/filament/` in the bridge folder. They show up in the app's lists.
- **Find models online:** in Files, the globe button searches **Printables** (no account), **Creality Cloud** (search is open; downloads ask you to sign in once on Creality's own page inside the app) and **Thingiverse** (paste a free app token from [thingiverse.com/developers](https://www.thingiverse.com/developers)). **MakerWorld** opens as its own website inside the app: sign in there, tap Download on a 3MF, and Printer Hub slices it. G-code or a 3MF already made for your K2 Plus or U1 is sent straight to the printer.
- STEP files are meshed first (fine detail is kept to about 1/36 of a circle), which adds up to a minute for big parts.

## Troubleshooting

| Problem | Fix |
|---|---|
| Printer not found | Phone and printer must be on the same Wi-Fi. Enter the IP by hand. Moonraker must be on port 7125 (or set the port). |
| K2 camera shows "sent no video" | The camera serves one viewer at a time. Close the Creality app or Creality Print on other devices, wait 30 s, then tap Retry. |
| Camera from away is black (K1/K2) | `.env` needs both `COMPOSE_PROFILES=creality` and the `CAMERA_URL` line. Check `docker compose logs go2rtc`. |
| App says the bridge is offline | `docker compose logs bridge`. Check that `RELAY_URL` is your own relay and that the NAS can reach the internet. |
| "The slicer isn't running on your home bridge" | Update the bridge (`docker compose pull && docker compose up -d`) and add `slicer` to `COMPOSE_PROFILES`. Check `docker compose logs slicer`. |
| Find models: Creality download asks you to sign in again | Creality ended the session. Sign in again on its page in the app (Settings → Model sites shows the state). |
| Find models: "Thingiverse refused the token" | Create a new app at thingiverse.com/developers, then use the key button in Find models → Thingiverse to paste its App Token. |
| MakerWorld: tapping Download does nothing | Sign in to MakerWorld on its page first. Printer Hub catches 3MF, STL and STEP downloads only. |
| Lost the pairing code | `docker compose run --rm bridge --show-code` |
| Mac update didn't install | Printer Hub must live in Applications, and your user must be allowed to change it (admin). Otherwise the app opens the download. |

Still stuck? [Open an issue](https://github.com/dragonemprorx90/printer-hub/issues/new/choose) with the printer model, app version and the bridge log.

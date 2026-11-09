# Security

## How remote access is protected

- The **pairing code** (`PHB1:…`) printed by the home bridge holds the relay address, a room id and a secret. The app and the bridge derive their keys from that secret. It is never sent anywhere.
- Every message between the app and the bridge is sealed with **ChaCha20-Poly1305** (`packages/hub_link`). The **relay** (a Cloudflare Worker you deploy yourself) only passes sealed frames between the two sides of a room. It cannot read them, change them without detection, or send commands.
- The bridge only makes **outgoing** connections, so no router ports are opened.
- At home the app talks to Moonraker directly on your LAN, just as Moonraker's own web UIs do.

Treat the pairing code like a password. If it leaks, issue a new one. That locks out every phone paired with the old code:

```bash
docker compose down && docker compose run --rm bridge --reset --show-code && docker compose up -d
```

## Mac app

Since 1.18 the Mac app runs without Apple's app sandbox, so it can install its own updates. Updates are downloaded only from this repository's GitHub releases over HTTPS.

## Model sites

Printer Hub keeps your Creality Cloud session token and your Thingiverse app token on the device only. They are left out of the settings backup file. Settings → Model sites signs out of Creality Cloud and removes the Thingiverse token. Creality Cloud sign-in happens on Creality's own page inside the app, so your password goes only to Creality. MakerWorld is shown as its own website, and its sign-in stays inside that web view.

## Reporting a problem

Please report vulnerabilities privately through GitHub's **Report a vulnerability** button (Security tab), not in a public issue. Include the version and steps to reproduce.

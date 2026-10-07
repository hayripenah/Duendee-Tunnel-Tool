# Duendee Tunnel Tool

Standalone Windows launcher: starts a local web app, opens a Cloudflare quick tunnel, copies the public URL, and optionally sends it over WhatsApp.

This repository is independent — it is not a submodule or dependency of any other project.

## Setup

1. Install [Node.js](https://nodejs.org/) and [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/).
2. Clone this repo anywhere you like.
3. Copy `config.example.json` to `config.json` and set `projectPath` to the local app folder you want to expose (and `port` if needed).
4. `npm install`
5. Edit `scripts/whatsapp-config.json` if you want a different WhatsApp target number.
6. Run `Duendee Tunnel Tool.bat`.

`config.json` is local-only (gitignored).

## Menu

1. Start tunnel service  
2. Check status  
3. Copy public link  
4. Cancel tunnel  
5. Shutdown  
6. Toggle device-start autostart  

Runtime state lives in `.tunnelstate/`. WhatsApp session files live in `.whatsapp-session/` (both gitignored).

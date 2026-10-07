# Duendee Tunnel Tool

Standalone launcher: starts a local web app, opens a Cloudflare quick tunnel, copies the public URL, and optionally sends it over WhatsApp.

This repository is independent — it is not a submodule or dependency of any other project.

## Platforms

| OS | Folder | Entry point |
|----|--------|-------------|
| Windows | [`windows/`](windows/) | `windows/Duendee Tunnel Tool.bat` |
| Linux | [`linux/`](linux/) | `linux/duendee-tunnel-tool.sh` |

Shared pieces (repo root):

- `config.example.json` → copy to `config.json` and set `projectPath` / `port`
- `scripts/send-whatsapp.js` + `scripts/whatsapp-config.json`
- `npm install` (WhatsApp helper)
- Runtime: `.tunnelstate/`, `.whatsapp-session/` (gitignored)

## Quick start

1. Install [Node.js](https://nodejs.org/) and [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/).
2. Clone this repo.
3. `cp config.example.json config.json` and edit `projectPath`.
4. `npm install`
5. Run the entry point for your OS (see platform READMEs).

## Menu

1. Start tunnel service  
2. Check status  
3. Copy public link  
4. **Cancel tunnel** (stops only; never auto-restarts)  
5. Shutdown  
6. Toggle device-start autostart  

# Duendee Tunnel Tool

Standalone launcher: starts a local web app, opens a Cloudflare quick tunnel, copies the public URL, and optionally sends it over WhatsApp.

This repository is independent — it is not a submodule or dependency of any other project.

## Portable downloads

| Platform | Download |
|----------|----------|
| **Windows** | [Duendee-Tunnel-Tool-Windows-portable.zip](https://github.com/hayripenah/Duendee-Tunnel-Tool/releases/latest/download/Duendee-Tunnel-Tool-Windows-portable.zip) |
| **Linux** | [Duendee-Tunnel-Tool-Linux-portable.tar.gz](https://github.com/hayripenah/Duendee-Tunnel-Tool/releases/latest/download/Duendee-Tunnel-Tool-Linux-portable.tar.gz) |

All releases: https://github.com/hayripenah/Duendee-Tunnel-Tool/releases

## Install (one-liner)

Requires [Node.js](https://nodejs.org/) and [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/). After install, `duendee-tunnel` is on your PATH (open a new terminal on Windows if needed).

**Windows (PowerShell):**

```powershell
irm https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-windows.ps1 | iex
```

Installs to `%LOCALAPPDATA%\DuendeeTunnelTool`, adds a `duendee-tunnel` shim to PATH, and creates a desktop shortcut.

**Linux (bash):**

```bash
curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-linux.sh | bash
```

Installs to `~/.local/share/duendee-tunnel-tool` and places `duendee-tunnel` in `~/.local/bin`.

On first run the tool copies `config.example.json` → `config.json` and interactively asks for `projectPath` / `port` if needed. You can also edit `config.json` manually anytime.

## Run

After portable install:

```text
duendee-tunnel
```

From a git clone:

**Windows**

```powershell
& ".\windows\Duendee Tunnel Tool.bat"
```

**Linux**

```bash
./linux/duendee-tunnel-tool.sh
```

## Platforms (repo layout)

| OS | Folder | Entry point |
|----|--------|-------------|
| Windows | [`windows/`](windows/) | `windows/Duendee Tunnel Tool.bat` |
| Linux | [`linux/`](linux/) | `linux/duendee-tunnel-tool.sh` |

Shared pieces (repo root):

- `config.example.json` → auto-copied to `config.json` on first run (or copy manually)
- `scripts/send-whatsapp.js` + `scripts/whatsapp-config.json` (`targetPhone`)
- `npm install` in the tool root (WhatsApp helper; installers / first send also try this)
- Runtime: `.tunnelstate/`, `.whatsapp-session/` (gitignored)

## Quick start (from source)

1. Install [Node.js](https://nodejs.org/) and [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/).
2. Clone this repo.
3. `cp config.example.json config.json` and edit `projectPath`.
4. `npm install`
5. Run the entry point for your OS (see **Run** above).

## Menu

1. Start tunnel service  
2. Check status  
3. Copy public link  
4. **Cancel tunnel** (stops tunnel **and** the tool-started dev server; never auto-restarts)  
5. Shutdown (stops tunnel + dev server + helpers, then exits)  
6. Toggle device-start autostart  

Closing the main tool window, Ctrl+C, or option **[5]** cleans up cloudflared, the dev server, and watchers. Helper processes run hidden in the background.

## Build portable packages (maintainers)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\pack-portable.ps1
```

Outputs under `dist/`:

- `Duendee-Tunnel-Tool-Windows-portable.zip`
- `Duendee-Tunnel-Tool-Linux-portable.tar.gz`

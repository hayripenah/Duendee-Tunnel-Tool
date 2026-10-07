# Duendee Tunnel Tool

Standalone launcher: starts a local web app, opens a Cloudflare quick tunnel, copies the public URL, and optionally sends it over WhatsApp.

This repository is independent — it is not a submodule or dependency of any other project.

## Portable downloads

| Platform | Download |
|----------|----------|
| **Windows** | [Duendee-Tunnel-Tool-Windows-portable.zip](https://github.com/hayripenah/Duendee-Tunnel-Tool/releases/latest/download/Duendee-Tunnel-Tool-Windows-portable.zip) |
| **Linux** | [Duendee-Tunnel-Tool-Linux-portable.tar.gz](https://github.com/hayripenah/Duendee-Tunnel-Tool/releases/latest/download/Duendee-Tunnel-Tool-Linux-portable.tar.gz) |

All releases: https://github.com/hayripenah/Duendee-Tunnel-Tool/releases

## Install + run (same terminal)

Requires [Node.js](https://nodejs.org/) and [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/).

After install, the universal command on both OSes is:

```text
duendee-tunnel
```

### Windows 11 (PowerShell) — install then run in the same session

```powershell
irm https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-windows.ps1 | iex; duendee-tunnel
```

Installs to `%LOCALAPPDATA%\DuendeeTunnelTool`, writes a `duendee-tunnel` shim, updates **User PATH** and **`$env:Path` in the current session**, and creates a desktop shortcut. New terminals pick up User PATH automatically.

### Linux (bash) — install then run in the same session

`curl | bash` runs in a subshell, so PATH must be fixed in the parent. Use this one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-linux.sh | bash; export PATH="$HOME/.local/bin:$PATH"; hash -r; duendee-tunnel
```

Installs to `~/.local/share/duendee-tunnel-tool`, creates `~/.local/bin/duendee-tunnel` (and `/usr/local/bin/duendee-tunnel` when writable), and appends `~/.local/bin` to `~/.bashrc` / `~/.zshrc` / `~/.profile` when missing.

**Alternative (source — PATH applies immediately):**

```bash
source <(curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-linux.sh); duendee-tunnel
```

### Optional: auto-detect OS (`curl` + `bash`)

```bash
curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install.sh | bash; export PATH="$HOME/.local/bin:$PATH"; hash -r; duendee-tunnel
```

On Windows, keep using the PowerShell one-liner above.

### First-run projectPath (Duendee-main)

On first run the tool copies `config.example.json` → `config.json`, then resolves `projectPath`:

1. Searches common locations for a local **Duendee** / **Duendee-main** repo (Desktop, home, Documents, `YEK/Cursor`, git remotes matching `hayripenah/Duendee`).
2. If found: offers that path (Enter accepts #1) and runs a safe `git pull --ff-only` when the tree is clean.
3. If not found: **Enter clones** `https://github.com/hayripenah/Duendee.git` to **Desktop/`Duendee-main`** by default.
4. Always allows a custom directory (typed path; Windows folder browser; Linux `zenity`/`kdialog` when available).

Override with env vars: `DT_DUENDEE_DIR`, `DT_DUENDEE_REPO_URL`, `DT_DUENDEE_CLONE_NAME`.

## Run

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

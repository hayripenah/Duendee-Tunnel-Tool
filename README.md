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

**Docker is not recommended** (and not supported). This tool needs a real desktop session: WhatsApp QR, `gh auth login --web`, Electron shortcuts, host localhost ports, and cloudflared. Use the one-liner installers instead — they download Node, cloudflared, GitHub CLI, and npm deps, then refuse to say “Install OK” until `doctor` passes.

After install, the universal command on both OSes is:

```text
duendee-tunnel
```

Health check anytime:

```text
duendee-tunnel doctor
```

- **Hard fail** (exit 1): missing Node, cloudflared, or WhatsApp npm deps — menu will not open.
- **Soft warning**: no GitHub login — **local tunnel still works**; fleet sync and private repo clone need `gh auth login` or `GH_TOKEN` / `GITHUB_TOKEN`.

### Windows 11 (PowerShell) — install then run in the same session

```powershell
irm https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-windows.ps1 | iex; duendee-tunnel
```

Installs to `%LOCALAPPDATA%\DuendeeTunnelTool`, writes a `duendee-tunnel` shim, updates **User PATH** and **`$env:Path` in the current session**, installs Node / cloudflared / `gh`, runs `npm install`, prompts for GitHub login when interactive, runs `doctor`, and creates a desktop shortcut. New terminals pick up User PATH automatically.

### Linux (bash) — install then run in the same session

`curl | bash` runs in a subshell, so PATH must be fixed in the parent. Use this one-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-linux.sh | bash; export PATH="$HOME/.local/bin:$PATH"; hash -r; duendee-tunnel
```

Installs to `~/.local/share/duendee-tunnel-tool`, creates `~/.local/bin/duendee-tunnel` (and `/usr/local/bin/duendee-tunnel` when writable), appends `~/.local/bin` to `~/.bashrc` / `~/.zshrc` / `~/.profile` when missing, installs core deps fail-hard, prompts for GitHub login when interactive, and runs `doctor`.

**Alternative (source — PATH applies immediately):**

```bash
source <(curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install-linux.sh); duendee-tunnel
```

### Optional: auto-detect OS (`curl` + `bash`)

```bash
curl -fsSL https://raw.githubusercontent.com/hayripenah/Duendee-Tunnel-Tool/main/scripts/install.sh | bash; export PATH="$HOME/.local/bin:$PATH"; hash -r; duendee-tunnel
```

On Windows, keep using the PowerShell one-liner above.

### Product menu (Windows)

The Windows tool opens with a product picker:

| Key | Section | Purpose |
|-----|---------|---------|
| **1** | **DuendeeFM** | Existing publish/tunnel/app tools for **Duendee-fm** (unchanged options 1–6) |
| **2** | **Duendee** | Isolated test tunnel for **Duendee-main** (port **8081**, purple banner, state `.tunnelstate-duendee`) |

DuendeeFM and Duendee use **separate** ports, state dirs, and cloudflared processes so starting/stopping one does not kill the other.

WhatsApp messages are product-tagged too:
- **DuendeeFM tüneli** + URL
- **Duendee tüneli (main)** + URL  

Cancel/retract only removes that product’s messages.

**Duendee** auto-detects `Duendee-main`, fetches origin, and publishes the **newest remote branch** (by committer date). There is no manual path/port/branch menu.

Duendee menu splits local vs public:
- **[1] Test Tüneli** — cloudflared + WhatsApp link  
- **[2] Dev Server** — `http://localhost:8081` Vite HMR only (no tunnel)  
- **[6]** stops the Dev Server without touching a live tunnel

### First-run projectPath (DuendeeFM)

On first run the tool copies `config.example.json` → `config.json`, then resolves `projectPath` (FM):

1. Searches common locations for a local **Duendee-fm** repo (Desktop, home, Documents, `YEK/Cursor`, git remotes matching `hayripenah/Duendee-FM`).
2. If found: offers that path (Enter accepts #1). Every FM tunnel start pulls that repo to the latest `origin/main` before publishing.
3. If not found: **Enter clones** `https://github.com/hayripenah/Duendee-FM.git` to **Desktop/`Duendee-fm`** by default.
4. Always allows a custom directory (typed path; Windows folder browser; Linux `zenity`/`kdialog` when available).

`duendeeProjectPath` / `duendeePort` / `duendeeBranch` are resolved for the **Duendee** section (auto-detect `Duendee-main`, default port `8081`, branch `neo-3d`).

Override FM with: `DT_DUENDEE_DIR`, `DT_DUENDEE_REPO_URL`, `DT_DUENDEE_CLONE_NAME`.  
Override Duendee neo with: `DT_NEO_DUENDEE_DIR`.

## Run

```text
duendee-tunnel
```

Each launch updates this tool from GitHub `main` and restarts it when that branch has moved.

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

- `config.example.json` → auto-copied to `config.json` on first run (`projectPath` = Duendee-fm, optional `appPath` = Duendee-app)
- `scripts/send-whatsapp.js` + `scripts/whatsapp-config.json` (`targetPhone`, optional `targetPhones` list)
- `npm install` in the tool root (WhatsApp helper; installers / first send also try this)
- Runtime: `.tunnelstate/`, `.whatsapp-session/` (gitignored)

## Quick start (from source)

1. Prefer the one-liner installers above (they pull Node / cloudflared / `gh` for you). From a clone: install [Node.js](https://nodejs.org/), [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/), and [GitHub CLI](https://cli.github.com/).
2. Clone this repo.
3. `cp config.example.json config.json` and edit `projectPath`.
4. `npm install`
5. `gh auth login` (needed for fleet + private repos; local tunnel works without it).
6. Run `duendee-tunnel doctor`, then the entry point for your OS (see **Run** above).

## Menu

1. Start tunnel service  
2. Check status  
3. Copy public link  
4. Cancel tunnel  
5. Autostart — **[T]** tool, **[S]** tool and tunnel, **[A]** DuendeeFM desktop app in Startup, **[D]** permanently pack desktop app + Desktop shortcut, **Derleme/Başlatma Tipi** **[1]** browser / **[2]** desktop / **[3]** mobile / **[4]** all, **[K]** tool autostart off  


6. Uninstall — **[1]** tool, **[2]** tool plus Node.js and cloudflared

Closing the window leaves the tunnel running. **[4]** stops it.

Under autostart, **Derleme/Başlatma Tipi** picks what opens on every tunnel start: browser, desktop Electron, Android, or all. Desktop mode packs a permanent **DuendeeFM** app (electron-builder), installs it under the user profile, places a Desktop shortcut, and launches that build against the live tunnel URL. **[A]** adds/removes DuendeeFM from the OS Startup apps list. Mobile mode installs a user-local JDK/Android SDK if needed, builds `DuendeeFM.apk`, and sends it over WhatsApp.

## Tunnel watchdog (auto recovery)

Cloudflare quick tunnels (`*.trycloudflare.com`) are temporary. When the connector loses its edge
connection Cloudflare drops the tunnel on its side (`Unauthorized: Tunnel not found`) and the
hostname disappears from DNS, so every other device fails with `DNS_PROBE_FINISHED_NXDOMAIN`.

`scripts/tunnel-watchdog.js` runs next to the tunnel and watches it the way an outside device
does — public DNS lookup (`1.1.1.1`, `8.8.8.8`) plus a real HTTPS request:

- the hostname leaves DNS or cloudflared dies -> a fresh quick tunnel is opened,
- the local app on `port` is down -> the app is started again,
- the new address is written to `.tunnelstate/tunnel.url`, published to the fleet record and
  sent over WhatsApp (the previous link message is retracted first),
- the live address is written to the fleet record as soon as it resolves publicly, so any other
  device can pick it up without asking,
- a dead link is never handed to another device, so no other machine adopts a broken address.

State files live in `.tunnelstate/`: `tunnel.url`, `tunnel.pid`, `watchdog.pid`, `watchdog.log`,
`recover.lock`, `manual-stop`. The watchdog stops when `manual-stop` exists (menu **[4]**).

The link itself is public — anyone who receives it can open the app from any device and network.
`scripts/whatsapp-config.json` takes a `targetPhone` plus an optional `targetPhones` list, so a
rebuilt tunnel reaches every person the link was shared with (comma separated numbers work too).

Tuning via environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `DT_WATCHDOG_INTERVAL_MS` | `15000` | health check interval |
| `DT_WATCHDOG_MAX_FAILS` | `3` | failed checks before the tunnel is restarted |
| `DT_WATCHDOG_GRACE_MS` | `20000` | quiet period after a restart |
| `DT_WATCHDOG_LOCK_MS` | `90000` | recovery lock lifetime (shared with the fleet) |
| `DT_CF_PROTOCOL` | `http2` | cloudflared transport protocol |

Before opening a quick tunnel, Windows repairs flaky adapter DNS (prefers `1.1.1.1` / `8.8.8.8`),
skips cloudflared connectivity prechecks (`--no-prechecks`), and retries when the local DNS
resolver times out against `region*.v2.argotunnel.com`.

Manual check (no side effects):

```text
node scripts/tunnel-watchdog.js --root . --check
```

## Uninstall

From the menu, choose **[6]**. From a terminal:

```text
duendee-tunnel uninstall
duendee-tunnel uninstall 1
duendee-tunnel uninstall 2
```

`1` removes the tool. `2` also removes Node.js and cloudflared. Both ask for confirmation. `duendee-tunnel 6` opens the same prompt.

## Build portable packages (maintainers)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\pack-portable.ps1
```

Outputs under `dist/`:

- `Duendee-Tunnel-Tool-Windows-portable.zip`
- `Duendee-Tunnel-Tool-Linux-portable.tar.gz`

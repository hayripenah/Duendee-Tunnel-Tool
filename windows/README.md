# Duendee Tunnel Tool — Windows

## Run

Double-click **`Duendee Tunnel Tool.bat`**, or from a terminal:

```bat
"Duendee Tunnel Tool.bat"
```

The `.bat` is an ASCII-only launcher. The real UI is `duendee-tunnel-tool.ps1` (UTF-8), so Turkish text stays correct after every menu action (`cls`, pause, redraw).

Optional desktop shortcut target:

```text
…\Duendee-Tunnel-Tool\windows\Duendee Tunnel Tool.bat
```

Working directory: the `windows\` folder (or repo root — the script resolves the parent itself).

## Layout

- `Duendee Tunnel Tool.bat` — launcher
- `duendee-tunnel-tool.ps1` — menu + tunnel logic
- `Duendee Tunnel Logo.ico` — shortcut icon
- `scripts\` — `extract-tunnel-url.ps1`, `tunnel-watcher.ps1`, `get-tool-pid.ps1`

Config, npm deps, and WhatsApp live in the **repo root**.

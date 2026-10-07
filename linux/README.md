# Duendee Tunnel Tool — Linux

## Run

```bash
chmod +x duendee-tunnel-tool.sh scripts/*.sh
./duendee-tunnel-tool.sh
```

Clipboard needs `wl-copy` (Wayland) or `xclip`/`xsel` (X11). Autostart uses a systemd user unit.

## Layout

- `duendee-tunnel-tool.sh` — menu + tunnel logic
- `scripts\` — `extract-tunnel-url.sh`, `tunnel-watcher.sh`

Config, npm deps, and WhatsApp live in the **repo root**.

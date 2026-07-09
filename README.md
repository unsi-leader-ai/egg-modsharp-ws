# Modsharp WS — Pterodactyl Egg for CS2 + ModSharp

> [!WARNING]
> **Private project — not for third-party use.** This repository, the egg, its
> scripts and the container image `ghcr.io/unsi-leader-ai/egg-modsharp` are
> published solely for our own infrastructure. **Use by anyone else is not
> permitted** — see [LICENSE](LICENSE). Everything is provided **AS IS**,
> without warranty of any kind, and we accept **no liability whatsoever** for
> any damage or loss arising from it. Among other things it modifies game
> files (`gameinfo.gi`), installs third-party software and self-updates —
> running it can break your server. If you use it anyway, contrary to the
> license, you do so entirely at your own risk.

A Pterodactyl egg and Docker image for running a Counter-Strike 2 dedicated
server with the [ModSharp](https://github.com/Kxnrl/modsharp-public) framework
on Steam RT3 (sniper).

## Contents

| Path | Purpose |
|---|---|
| `egg/egg-modsharp-ws.json` | PTDL_v2 egg — import this in the panel (Admin → Nests → Import Egg) |
| `docker/Dockerfile` | Runtime image based on Valve's `steamrt/sniper/platform` |
| `docker/entrypoint.sh` | Start logic (see below) |
| `install/install.sh` | Install script (also embedded in the egg JSON) |
| `.github/workflows/publish.yml` | Builds and pushes `ghcr.io/unsi-leader-ai/egg-modsharp:latest` |

## What happens on every server start

1. **CS2 update** via SteamCMD — skipped when `SRCDS_STOP_UPDATE=1`
2. **`gameinfo.gi` re-patch** — adds `Game sharp` after `Game_LowViolence`
   (idempotent; CS2 updates overwrite the file)
3. **ModSharp binaries + extensions** — installed only when `MODSHARP_VERSION`
   differs from the installed version (marker file `.ms-version`).
   `sharp/configs/` and `sharp/modules/` are **never touched** by updates.
4. **Gamedata refresh** — when `MODSHARP_GAMEDATA_UPDATE=1`, the six
   `*.games.jsonc` files are fetched fresh from the `modsharp-public` master
   branch (plain JSON, no build required)
5. **.NET runtime** — the portable runtime lives in `game/sharp/runtime`
   (Steam RT3 cannot use a system-wide .NET); reinstalled only when
   `DOTNET_CHANNEL` changes
6. The startup line is assembled: `-dual_addon <id>` is appended only when
   `DUAL_ADDON` is non-empty, `-authkey` only when `STEAM_AUTHKEY` is set,
   and `EXTRA_ARGS` verbatim at the end

A failed download in steps 3–5 keeps the existing installation and the server
still starts.

## Variables

| Variable | Default | Meaning |
|---|---|---|
| `STEAM_ACC` | – | GSLT → `+sv_setsteamaccount` |
| `SRCDS_MAXPLAYERS` | `32` | `-maxplayers` |
| `SRCDS_MAP` | `de_dust2` | `+map` |
| `SRCDS_STOP_UPDATE` | `0` | `1` = skip the CS2 update on start |
| `SRCDS_VALIDATE` | `0` | SteamCMD `validate` (may reset modified files) |
| `SRCDS_APPID` | `730` | not editable |
| `MODSHARP_VERSION` | `git-132` | pinned release tag; change + restart to update |
| `MODSHARP_GAMEDATA_UPDATE` | `1` | gamedata refresh from master on every start |
| `DOTNET_CHANNEL` | `10.0` | .NET runtime channel (set `11.0` to switch later) |
| `DUAL_ADDON` | – | one workshop ID (digits only); empty = flag omitted |
| `STEAM_AUTHKEY` | – | `-authkey` for workshop content (32-hex Steam Web API key) |
| `SRCDS_LOGIN` / `SRCDS_LOGIN_PASS` | – | SteamCMD login (start + install); empty = anonymous |
| `EXTRA_ARGS` | – | appended to the startup line; charset limited to `A-Za-z0-9_+-.:/ ` because the startup line is eval'd |

## Updating ModSharp

The binaries are pinned deliberately: set `MODSHARP_VERSION` to a new release
tag (e.g. `git-140`) in the Startup tab and restart. The entrypoint downloads
`ModSharp-<tag>-linux.zip` and `...-extensions.zip`, mirrors `bin/` and `core/`
(stale framework files are removed), merges `shared/ locales/ gamedata/`
(custom shared libraries survive) and leaves `configs/` and `modules/`
alone. The version marker is only written after a complete deploy, so a
failed or interrupted update is retried on the next start. Gamedata stays
current automatically in the meantime.

## Building the image locally

```bash
docker build -f docker/Dockerfile -t ghcr.io/unsi-leader-ai/egg-modsharp:latest .
```

CI builds and pushes the image on every push to `main`
(and via manual workflow dispatch).

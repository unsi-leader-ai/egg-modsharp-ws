# Modsharp WS — container image for CS2 + ModSharp on Pterodactyl

> [!WARNING]
> **Private project — not for third-party use.** This repository, its scripts
> and the container image `ghcr.io/unsi-leader-ai/egg-modsharp` are
> published solely for our own infrastructure. **Use by anyone else is not
> permitted** — see [LICENSE](LICENSE). Everything is provided **AS IS**,
> without warranty of any kind, and we accept **no liability whatsoever** for
> any damage or loss arising from it. Among other things it modifies game
> files (`gameinfo.gi`), installs third-party software and self-updates —
> running it can break your server. If you use it anyway, contrary to the
> license, you do so entirely at your own risk.

The Docker image for running a Counter-Strike 2 dedicated server with the
[ModSharp](https://github.com/Kxnrl/modsharp-public) framework on Steam RT3
(sniper) under Pterodactyl. This repository holds only what builds the image.
The egg that uses it (egg JSON, install script, tooling) is maintained
privately in `unsi-leader-ai/egg-modsharp-ws-private` and is not published;
the revisions up to September 2026 remain in this repository's history.

## Contents

| Path | Purpose |
|---|---|
| `docker/Dockerfile` | Runtime image based on Valve's `steamrt/sniper/platform` |
| `docker/entrypoint.sh` | Start logic (see below) |
| `docker/Dockerfile.installer` | Install container for the egg's install script: official `debian:trixie-slim` with the script's tools baked in, so no `apt-get` runs while a server installs |
| `.github/workflows/publish.yml` | Builds and pushes `ghcr.io/unsi-leader-ai/egg-modsharp:latest` and `ghcr.io/unsi-leader-ai/egg-modsharp-installer:latest` |

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
6. The startup line is finalized: all parameters (`GAME_TYPE`, `GAME_MODE`,
   `DUAL_ADDON`, `EXTRA_ARGS`, …) live as placeholders in the panel's startup
   command, so changing a variable is reflected there immediately. Values are
   format-validated, flags whose variable is empty are dropped (no dangling
   `-dual_addon`), and `-authkey` is appended shell-escaped only when
   `STEAM_AUTHKEY` is set (kept out of the visible line on purpose)

A failed download in steps 3–5 keeps the existing installation and the server
still starts.

## Variables

Set by the egg; the entrypoint reads them from the environment.

| Variable | Default | Meaning |
|---|---|---|
| `STEAM_ACC` | – | GSLT → `+sv_setsteamaccount` |
| `SRCDS_MAXPLAYERS` | `32` | `-maxplayers` |
| `SRCDS_MAP` | `de_dust2` | `+map` |
| `SRCDS_STOP_UPDATE` | `0` | `1` = skip the CS2 update on start |
| `SRCDS_VALIDATE` | `0` | SteamCMD `validate` (may reset modified files) |
| `SRCDS_APPID` | `730` | not editable |
| `GAME_TYPE` / `GAME_MODE` | `0` / `0` | `+game_type` / `+game_mode` (0/0 casual, 0/1 competitive, 0/2 wingman, 1/0 arms race, 1/2 deathmatch, 3/0 custom) |
| `MODSHARP_VERSION` | `git-132` | pinned release tag; change + restart to update |
| `MODSHARP_GAMEDATA_UPDATE` | `1` | gamedata refresh from master on every start |
| `MODSHARP_SKIP_DEFAULTS` | `0` | `1` = install/update ModSharp without its default modules and shared defaults (incl. extensions); `modules/` and `shared/` are created empty for your own deploy, configs (incl. the boot-required `core.json`) still seed ModSharp cannot init without at least one loadable module, so as long as `sharp/modules` holds none the entrypoint starts plain CS2 (removes `Game sharp` from `gameinfo.gi` for that run, says so in the console) and switches ModSharp back on at the first start that finds a module. |
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

## Building the images locally

```bash
docker build -f docker/Dockerfile -t ghcr.io/unsi-leader-ai/egg-modsharp:latest .
docker build -f docker/Dockerfile.installer -t ghcr.io/unsi-leader-ai/egg-modsharp-installer:latest .
```

CI builds and pushes both images on every push to `main`
(and via manual workflow dispatch).

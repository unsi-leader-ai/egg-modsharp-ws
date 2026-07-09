#!/bin/bash
# Modsharp WS — entrypoint for the Pterodactyl egg (CS2 + ModSharp).
#
# Runs on every server start, in this fixed order:
#   1. CS2 update via SteamCMD          (skipped when SRCDS_STOP_UPDATE=1)
#   2. gameinfo.gi re-patch             (idempotent; CS2 updates overwrite it)
#   3. ModSharp binaries + extensions   (only when MODSHARP_VERSION != marker;
#                                        sharp/configs + sharp/modules are never
#                                        overwritten, only seeded when missing)
#   4. gamedata refresh from master     (when MODSHARP_GAMEDATA_UPDATE=1)
#   5. .NET runtime                     (only when DOTNET_CHANNEL != marker)
#   6. build the final startup line and run the server
#
# Steps 3-5 are transactional: downloads are staged and only swapped in on
# success, and version markers are only written after a complete deploy — a
# GitHub/CDN outage or full disk never prevents the server from starting with
# the previously installed versions.

cd /home/container || exit 1

MS_REPO="Kxnrl/modsharp-public"
MS_MARKER="/home/container/.ms-version"
DOTNET_MARKER="/home/container/.dotnet-channel"
SHARP_DIR="/home/container/game/sharp"
GAMEDATA_FILES=(core engine server tier0 log EntityEnhancement)
CR=$(printf '\r')

# Make internal Docker IP address available to processes.
INTERNAL_IP=$(ip route get 1 | awk '{print $NF;exit}')
export INTERNAL_IP

msg() { echo "[modsharp-ws] $*"; }

# ---------------------------------------------------------------------------
# 1. CS2 update via SteamCMD
# ---------------------------------------------------------------------------
if [ "${SRCDS_STOP_UPDATE:-0}" != "1" ]; then
    if [ -f ./steamcmd/steamcmd.sh ]; then
        login=(anonymous)
        if [ -n "${SRCDS_LOGIN}" ]; then
            login=("${SRCDS_LOGIN}")
            [ -n "${SRCDS_LOGIN_PASS}" ] && login+=("${SRCDS_LOGIN_PASS}")
        fi

        validate=()
        if [ "${SRCDS_VALIDATE:-0}" = "1" ]; then
            msg "SteamCMD validate enabled — this may reset modified game files (gameinfo.gi is re-patched below)."
            validate=(validate)
        fi

        msg "Updating CS2 (AppID ${SRCDS_APPID:-730}) via SteamCMD..."
        ./steamcmd/steamcmd.sh +force_install_dir /home/container \
            +login "${login[@]}" \
            +app_update "${SRCDS_APPID:-730}" "${validate[@]}" +quit

        # Wings can't follow symlinks here; copy the updated steamclient on every start.
        mkdir -p ./.steam/sdk32 ./.steam/sdk64
        cp -f ./steamcmd/linux32/steamclient.so ./.steam/sdk32/steamclient.so
        cp -f ./steamcmd/linux64/steamclient.so ./.steam/sdk64/steamclient.so
    else
        msg "WARNING: steamcmd not found, skipping CS2 update."
    fi
else
    msg "CS2 update disabled (SRCDS_STOP_UPDATE=1)."
fi

# ---------------------------------------------------------------------------
# 2. gameinfo.gi re-patch (Game sharp after Game_LowViolence)
# ---------------------------------------------------------------------------
GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"
GAMEINFO_ENTRY="			Game	sharp"
GAMEINFO_MATCH="^[[:blank:]]*Game[[:blank:]]+sharp[[:blank:]]*${CR}?$"
if [ -f "${GAMEINFO_FILE}" ]; then
    if grep -qE "${GAMEINFO_MATCH}" "${GAMEINFO_FILE}"; then
        msg "gameinfo.gi already contains 'Game sharp'."
    else
        awk -v new_entry="${GAMEINFO_ENTRY}" '
            BEGIN { found=0 }
            {
                if (found) { print new_entry; found=0 }
                print
            }
            /Game_LowViolence/ { found=1 }
        ' "${GAMEINFO_FILE}" > "${GAMEINFO_FILE}.tmp" && mv "${GAMEINFO_FILE}.tmp" "${GAMEINFO_FILE}"

        if grep -qE "${GAMEINFO_MATCH}" "${GAMEINFO_FILE}"; then
            msg "gameinfo.gi patched ('Game sharp' added)."
        else
            msg "WARNING: 'Game_LowViolence' marker not found — gameinfo.gi NOT patched, ModSharp will not load!"
        fi
    fi
else
    msg "WARNING: ${GAMEINFO_FILE} not found — is CS2 installed?"
fi

# ---------------------------------------------------------------------------
# 3. ModSharp binaries + extensions (pinned via MODSHARP_VERSION)
# ---------------------------------------------------------------------------
MODSHARP_VERSION="${MODSHARP_VERSION:-git-132}"
installed_ms="$(cat "${MS_MARKER}" 2>/dev/null || echo none)"

if [ "${installed_ms}" = "none" ] && [ -d "${SHARP_DIR}/bin" ]; then
    msg "WARNING: existing ModSharp install found without a version marker (egg switch without reinstall?)."
    msg "WARNING: framework files (bin/core/shared/locales/gamedata) will be overwritten with ${MODSHARP_VERSION}."
    msg "WARNING: if a newer/custom build is installed, write its tag into .ms-version instead to keep it."
fi

if [ "${MODSHARP_VERSION}" = "${installed_ms}" ]; then
    msg "ModSharp ${installed_ms} already installed."
else
    msg "Installing ModSharp ${MODSHARP_VERSION} (installed: ${installed_ms})..."
    asset="ModSharp-${MODSHARP_VERSION//-/}-linux"
    base_url="https://github.com/${MS_REPO}/releases/download/${MODSHARP_VERSION}"
    work="$(mktemp -d)"

    if curl -fsSL --connect-timeout 10 --max-time 300 -o "${work}/main.zip" "${base_url}/${asset}.zip" \
       && curl -fsSL --connect-timeout 10 --max-time 300 -o "${work}/ext.zip" "${base_url}/${asset}-extensions.zip" \
       && unzip -qo "${work}/main.zip" -d "${work}/main" \
       && unzip -qo "${work}/ext.zip" -d "${work}/ext"; then

        mkdir -p "${SHARP_DIR}"
        deploy_ok=1

        # Framework directories: bin/ and core/ are fully framework-owned →
        # mirror them (--delete) so renamed/removed files don't go stale.
        # shared/, locales/ and gamedata/ may contain user additions → merge only.
        for d in bin core shared locales gamedata; do
            if [ -d "${work}/main/sharp/${d}" ]; then
                mkdir -p "${SHARP_DIR}/${d}"
                del=()
                case "${d}" in bin|core) del=(--delete) ;; esac
                rsync -a "${del[@]}" "${work}/main/sharp/${d}/" "${SHARP_DIR}/${d}/" || deploy_ok=0
            fi
        done

        # configs/ and modules/: NEVER overwritten on update — only seeded when
        # they don't exist yet (fresh volume without install script).
        for d in configs modules; do
            if [ ! -d "${SHARP_DIR}/${d}" ] && [ -d "${work}/main/sharp/${d}" ]; then
                rsync -a "${work}/main/sharp/${d}/" "${SHARP_DIR}/${d}/" || deploy_ok=0
            fi
        done

        # Extensions (CommandManager, EntityHookManager, GameEventManager)
        # follow the shared-library layout: one folder per extension in shared/.
        # Mirror each framework extension folder, never the whole shared/ tree.
        for extdir in "${work}/ext"/*/; do
            [ -d "${extdir}" ] || continue
            name="$(basename "${extdir}")"
            rsync -a --delete "${extdir}" "${SHARP_DIR}/shared/${name}/" || deploy_ok=0
        done

        if [ "${deploy_ok}" = "1" ]; then
            echo "${MODSHARP_VERSION}" > "${MS_MARKER}"
            msg "ModSharp ${MODSHARP_VERSION} installed."
        else
            msg "WARNING: ModSharp ${MODSHARP_VERSION} deploy incomplete (rsync failed) — marker NOT updated, install is retried on next start."
        fi
    else
        msg "WARNING: download/extract of ModSharp ${MODSHARP_VERSION} failed — keeping ${installed_ms}."
    fi
    rm -rf "${work}"
fi

# ---------------------------------------------------------------------------
# 4. gamedata refresh from master (no build required)
# ---------------------------------------------------------------------------
if [ "${MODSHARP_GAMEDATA_UPDATE:-1}" = "1" ]; then
    mkdir -p "${SHARP_DIR}/gamedata"
    updated=0
    for f in "${GAMEDATA_FILES[@]}"; do
        url="https://raw.githubusercontent.com/${MS_REPO}/master/.asset/gamedata/${f}.games.jsonc"
        # Stage next to the target (same filesystem) so mv is an atomic rename
        # and a failed/killed download can never truncate a live gamedata file.
        tmp="${SHARP_DIR}/gamedata/.${f}.games.jsonc.tmp"
        if curl -fsSL --connect-timeout 5 --max-time 30 -o "${tmp}" "${url}"; then
            mv -f "${tmp}" "${SHARP_DIR}/gamedata/${f}.games.jsonc"
            updated=$((updated + 1))
        else
            rc=$?
            rm -f "${tmp}"
            msg "WARNING: gamedata ${f}.games.jsonc not downloadable — keeping existing file."
            # 7 = connection refused/unreachable, 28 = timeout: don't stall the
            # start by retrying the same dead network five more times.
            if [ "${rc}" -eq 7 ] || [ "${rc}" -eq 28 ]; then
                msg "WARNING: network unreachable — skipping remaining gamedata files."
                break
            fi
        fi
    done
    msg "gamedata refreshed from master (${updated}/${#GAMEDATA_FILES[@]} files)."
else
    msg "gamedata auto-update disabled (MODSHARP_GAMEDATA_UPDATE=0)."
fi

# ---------------------------------------------------------------------------
# 5. .NET runtime (portable, inside the volume — RT3 cannot use a system .NET)
# ---------------------------------------------------------------------------
DOTNET_CHANNEL="${DOTNET_CHANNEL:-10.0}"
installed_dotnet="$(cat "${DOTNET_MARKER}" 2>/dev/null || echo none)"

if [ "${DOTNET_CHANNEL}" = "${installed_dotnet}" ] && [ -x "${SHARP_DIR}/runtime/dotnet" ]; then
    msg ".NET channel ${installed_dotnet} already installed."
else
    msg "Installing .NET runtime channel ${DOTNET_CHANNEL} (installed: ${installed_dotnet})..."
    if curl -fsSL --connect-timeout 10 --max-time 60 -o /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh; then
        # Install into a staging dir on the same volume and swap in only after
        # success — the old runtime survives every failure mode, and exactly
        # one channel remains after the rename.
        rm -rf "${SHARP_DIR}/runtime.new"
        if bash /tmp/dotnet-install.sh --channel "${DOTNET_CHANNEL}" --runtime dotnet \
            --install-dir "${SHARP_DIR}/runtime.new" --no-path; then
            rm -rf "${SHARP_DIR}/runtime"
            mv "${SHARP_DIR}/runtime.new" "${SHARP_DIR}/runtime"
            echo "${DOTNET_CHANNEL}" > "${DOTNET_MARKER}"
            msg ".NET ${DOTNET_CHANNEL} installed to game/sharp/runtime."
        else
            rm -rf "${SHARP_DIR}/runtime.new"
            msg "WARNING: dotnet-install failed — keeping existing runtime."
        fi
    else
        msg "WARNING: could not fetch dotnet-install.sh — keeping existing runtime."
    fi
fi

# ---------------------------------------------------------------------------
# 6. build the final startup line and run the server
# ---------------------------------------------------------------------------
# The startup line goes through eval below — every panel-set variable that is
# expanded into it is format-validated first (defense in depth on top of the
# egg's Laravel rules), so panel values can't inject commands. Values that
# fail their allowlist are blanked and the dangling flag is dropped further
# down.
if [ -n "${DUAL_ADDON}" ] && ! [[ "${DUAL_ADDON}" =~ ^[0-9]+$ ]]; then
    msg "WARNING: DUAL_ADDON '${DUAL_ADDON}' is not a numeric workshop ID — omitting -dual_addon."
    DUAL_ADDON=""
fi
if [ -n "${GAME_TYPE}" ] && ! [[ "${GAME_TYPE}" =~ ^[0-9]{1,2}$ ]]; then
    msg "WARNING: GAME_TYPE '${GAME_TYPE}' is not numeric — using 0."
    GAME_TYPE="0"
fi
if [ -n "${GAME_MODE}" ] && ! [[ "${GAME_MODE}" =~ ^[0-9]{1,2}$ ]]; then
    msg "WARNING: GAME_MODE '${GAME_MODE}' is not numeric — using 0."
    GAME_MODE="0"
fi
EXTRA_ARGS_RE='^[A-Za-z0-9_+.:/ -]*$'
if [ -n "${EXTRA_ARGS}" ] && ! [[ "${EXTRA_ARGS}" =~ ${EXTRA_ARGS_RE} ]]; then
    msg "WARNING: EXTRA_ARGS contains characters outside [A-Za-z0-9_+.:/ -] — ignored."
    EXTRA_ARGS=""
fi

MODIFIED_STARTUP=$(eval echo "$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')")

# Drop any value-flag whose panel variable ended up empty — a dangling
# "-dual_addon" or "+game_type" would swallow the following argument. This
# also cleans stale lines from a previous egg whose variables no longer exist.
read -ra tokens <<< "${MODIFIED_STARTUP}"
cleaned=()
i=0
while [ "${i}" -lt "${#tokens[@]}" ]; do
    tok="${tokens[${i}]}"
    next="${tokens[$((i + 1))]:-}"
    case "${tok}" in
        -dual_addon|-authkey|+sv_setsteamaccount|+game_type|+game_mode|+map|-maxplayers)
            if [ -z "${next}" ] || [[ "${next}" == [-+]* ]]; then
                msg "startup: '${tok}' has no value — flag dropped."
                i=$((i + 1))
                continue
            fi
            ;;
    esac
    cleaned+=("${tok}")
    i=$((i + 1))
done
MODIFIED_STARTUP="${cleaned[*]}"

# The authkey is a Steam Web API key — kept out of the visible startup line
# on purpose; appended shell-escaped instead.
if [ -n "${STEAM_AUTHKEY}" ]; then
    MODIFIED_STARTUP="${MODIFIED_STARTUP} -authkey $(printf '%q' "${STEAM_AUTHKEY}")"
fi

echo ":/home/container$ ${MODIFIED_STARTUP}"
eval "${MODIFIED_STARTUP}"

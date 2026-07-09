#!/bin/bash
# Modsharp WS — Pterodactyl install script.
# Runs once in the installer container (ghcr.io/pterodactyl/installers:debian).
# Server files live in /mnt/server.
#
#   1. SteamCMD into the volume, install CS2 (AppID 730), steamclient.so links
#   2. ModSharp (MODSHARP_VERSION) + extensions
#   3. Portable .NET runtime (DOTNET_CHANNEL) into game/sharp/runtime
#   4. Patch gameinfo.gi ('Game sharp')
#   5. Write version markers for the entrypoint

set -e

apt-get update -qq
apt-get install -y -qq curl unzip rsync ca-certificates lib32gcc-s1 >/dev/null

MS_REPO="Kxnrl/modsharp-public"
MODSHARP_VERSION="${MODSHARP_VERSION:-git-132}"
DOTNET_CHANNEL="${DOTNET_CHANNEL:-10.0}"
SRCDS_APPID="${SRCDS_APPID:-730}"
SHARP_DIR="/mnt/server/game/sharp"
CR=$(printf '\r')

# Empty SRCDS_LOGIN = anonymous. The anonymous login gets no password
# argument at all — steamcmd misparses a bare empty string.
login=(anonymous)
if [ -n "${SRCDS_LOGIN:-}" ]; then
    login=("${SRCDS_LOGIN}")
    [ -n "${SRCDS_LOGIN_PASS:-}" ] && login+=("${SRCDS_LOGIN_PASS}")
fi

# ---------------------------------------------------------------------------
# 1. SteamCMD + CS2
# ---------------------------------------------------------------------------
echo "== Installing SteamCMD..."
mkdir -p /mnt/server/steamcmd /mnt/server/steamapps
cd /tmp
curl -fsSL --connect-timeout 10 --max-time 300 -o steamcmd.tar.gz \
    https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz
tar -xzf steamcmd.tar.gz -C /mnt/server/steamcmd
cd /mnt/server/steamcmd

chown -R root:root /mnt
export HOME=/mnt/server

echo "== Installing CS2 (AppID ${SRCDS_APPID}) — this takes a while..."
./steamcmd.sh +force_install_dir /mnt/server \
    +login "${login[@]}" \
    +app_update "${SRCDS_APPID}" validate +quit

mkdir -p /mnt/server/.steam/sdk32 /mnt/server/.steam/sdk64
cp -f linux32/steamclient.so /mnt/server/.steam/sdk32/steamclient.so
cp -f linux64/steamclient.so /mnt/server/.steam/sdk64/steamclient.so

# ---------------------------------------------------------------------------
# 2. ModSharp + extensions
# ---------------------------------------------------------------------------
echo "== Installing ModSharp ${MODSHARP_VERSION}..."
asset="ModSharp-${MODSHARP_VERSION//-/}-linux"
base_url="https://github.com/${MS_REPO}/releases/download/${MODSHARP_VERSION}"
work="$(mktemp -d)"

curl -fsSL --connect-timeout 10 --max-time 300 -o "${work}/main.zip" "${base_url}/${asset}.zip"
curl -fsSL --connect-timeout 10 --max-time 300 -o "${work}/ext.zip" "${base_url}/${asset}-extensions.zip"

# Main zip contains the sharp/ folder → extract straight into game/.
mkdir -p /mnt/server/game
unzip -qo "${work}/main.zip" -d /mnt/server/game

# Extensions follow the shared-library layout: one folder per extension.
mkdir -p "${SHARP_DIR}/shared"
unzip -qo "${work}/ext.zip" -d "${work}/ext"
rsync -a "${work}/ext/" "${SHARP_DIR}/shared/"
rm -rf "${work}"

# ---------------------------------------------------------------------------
# 3. Portable .NET runtime (RT3 cannot use a system-wide .NET)
# ---------------------------------------------------------------------------
echo "== Installing .NET runtime channel ${DOTNET_CHANNEL}..."
curl -fsSL --connect-timeout 10 --max-time 60 -o /tmp/dotnet-install.sh https://dot.net/v1/dotnet-install.sh
bash /tmp/dotnet-install.sh --channel "${DOTNET_CHANNEL}" --runtime dotnet \
    --install-dir "${SHARP_DIR}/runtime" --no-path

# ---------------------------------------------------------------------------
# 4. gameinfo.gi patch ('Game sharp' after Game_LowViolence)
# ---------------------------------------------------------------------------
GAMEINFO_FILE="/mnt/server/game/csgo/gameinfo.gi"
GAMEINFO_ENTRY="			Game	sharp"
GAMEINFO_MATCH="^[[:blank:]]*Game[[:blank:]]+sharp[[:blank:]]*${CR}?$"
if [ -f "${GAMEINFO_FILE}" ]; then
    if grep -qE "${GAMEINFO_MATCH}" "${GAMEINFO_FILE}"; then
        echo "== gameinfo.gi already patched."
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
            echo "== gameinfo.gi patched ('Game sharp' added)."
        else
            echo "== WARNING: 'Game_LowViolence' marker not found — gameinfo.gi NOT patched!"
        fi
    fi
else
    echo "== WARNING: gameinfo.gi not found!"
fi

# ---------------------------------------------------------------------------
# 5. Version markers for the entrypoint
# ---------------------------------------------------------------------------
echo "${MODSHARP_VERSION}" > /mnt/server/.ms-version
echo "${DOTNET_CHANNEL}" > /mnt/server/.dotnet-channel

echo "== Install complete: CS2 + ModSharp ${MODSHARP_VERSION} + .NET ${DOTNET_CHANNEL}."

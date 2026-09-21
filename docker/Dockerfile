# Modsharp WS — Steam RT3 (sniper) runtime image for CS2 + ModSharp
# ModSharp requires the Steam Runtime 3 environment on Linux, so the image
# is based on Valve's sniper platform image (same base as 1zc/CS2-Pterodactyl).
FROM registry.gitlab.steamos.cloud/steamrt/sniper/platform:latest-container-runtime-depot

LABEL author="wase7@wase7.com" maintainer="wase7@wase7.com"
LABEL org.opencontainers.image.source="https://github.com/unsi-leader-ai/egg-modsharp-ws"
LABEL org.opencontainers.image.description="Steam RT3 (sniper) image for CS2 + ModSharp Pterodactyl servers"
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# iproute2: INTERNAL_IP in the entrypoint; unzip and rsync are used by the
# ModSharp/.NET/gamedata update logic in entrypoint.sh. curl and
# ca-certificates ship with the sniper image and are deliberately NOT listed:
# naming them makes apt upgrade them from bullseye-security.
#
# sniper is Debian 11 (bullseye), and its security pocket lists versions whose
# .deb answers 404 (2026-09-21 — this build failed on unzip, rsync, libbpf0,
# ca-certificates). So: try the newest versions, fall back to the base
# release (-t bullseye), and fail the build if a tool is still missing.
RUN apt-get update \
 && { apt-get install -y --no-install-recommends iproute2 unzip rsync \
      || apt-get install -y --no-install-recommends -t bullseye iproute2 unzip rsync; } \
 && command -v ip && command -v unzip && command -v rsync && command -v curl \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# The sniper image may or may not ship a "container" user depending on the tag.
RUN id -u container >/dev/null 2>&1 || useradd -m -d /home/container -s /bin/bash container

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

COPY docker/entrypoint.sh /entrypoint.sh
CMD ["/bin/bash", "/entrypoint.sh"]

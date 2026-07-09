# Modsharp WS — Steam RT3 (sniper) runtime image for CS2 + ModSharp
# ModSharp requires the Steam Runtime 3 environment on Linux, so the image
# is based on Valve's sniper platform image (same base as 1zc/CS2-Pterodactyl).
FROM registry.gitlab.steamos.cloud/steamrt/sniper/platform:latest-container-runtime-depot

LABEL author="wase7@wase7.com" maintainer="wase7@wase7.com"
LABEL org.opencontainers.image.source="https://github.com/unsi-leader-ai/egg-modsharp-ws"
LABEL org.opencontainers.image.description="Steam RT3 (sniper) image for CS2 + ModSharp Pterodactyl servers"
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# iproute2: INTERNAL_IP in the entrypoint; the rest is used by the
# ModSharp/.NET/gamedata update logic in entrypoint.sh.
RUN apt-get update \
 && apt-get install -y --no-install-recommends iproute2 curl ca-certificates unzip rsync \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# The sniper image may or may not ship a "container" user depending on the tag.
RUN id -u container >/dev/null 2>&1 || useradd -m -d /home/container -s /bin/bash container

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

COPY docker/entrypoint.sh /entrypoint.sh
CMD ["/bin/bash", "/entrypoint.sh"]

#!/usr/bin/env bash
# clean-room.sh -- prove setup-host.sh on a machine that has nothing: a
# fresh ros:humble container with this checkout's tools/setup-host.sh and
# nothing else. Takes ten to twenty minutes (clones, builds, benches).
#
#   tools/clean-room.sh            # run the setup in a fresh container
#   tools/clean-room.sh --shell    # then drop into a shell in it to poke around
#
# Needs docker (apt install docker.io; add yourself to the docker group).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
command -v docker >/dev/null || { echo "docker not found: sudo apt install docker.io && sudo usermod -aG docker $USER (then log out and in)"; exit 1; }
IMG=ros:humble-ros-base
docker pull -q "$IMG" >/dev/null
echo "clean-room: fresh $IMG, running setup-host.sh as a normal user with sudo"
CMD='set -e; apt-get update -qq && apt-get install -y -qq sudo git >/dev/null
useradd -m -s /bin/bash argus && echo "argus ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/argus
cp /setup-host.sh /home/argus/ && chown argus /home/argus/setup-host.sh
su - argus -c "ARGUS_HOME=/home/argus/Documents bash /home/argus/setup-host.sh"'
if [ "${1:-}" = "--shell" ]; then
  docker run -it --rm -v "$HERE/setup-host.sh:/setup-host.sh:ro" "$IMG" bash -c "$CMD; su - argus"
else
  docker run --rm -v "$HERE/setup-host.sh:/setup-host.sh:ro" "$IMG" bash -c "$CMD"
fi

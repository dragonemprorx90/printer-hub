#!/bin/sh
# Printer Hub bridge installer for any Linux box with Docker (NAS, Raspberry
# Pi, PC). Usage:
#   curl -fsSL https://raw.githubusercontent.com/dragonemprorx90/printer-hub/main/deploy/install.sh | sh
# Re-run it to change settings; your pairing in ./data is kept.
set -e
BASE=https://raw.githubusercontent.com/dragonemprorx90/printer-hub/main/deploy
DIR=${PRINTER_HUB_DIR:-$HOME/printer-hub-bridge}

command -v docker >/dev/null || { echo "Docker is not installed: https://docs.docker.com/engine/install/"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 is missing (docker compose)."; exit 1; }

mkdir -p "$DIR" && cd "$DIR"
curl -fsSL "$BASE/docker-compose.yml" -o docker-compose.yml
[ -f .env ] || curl -fsSL "$BASE/.env.example" -o .env

ask() { # ask VAR "question" default
  printf '%s [%s]: ' "$2" "$3" >/dev/tty
  read -r a </dev/tty || a=
  eval "$1=\${a:-\$3}"
}
current() { sed -n "s/^$1=//p" .env | head -n1; }
set_env() { # set_env KEY value  (uncomments or adds the line)
  if grep -qE "^#?$1=" .env; then
    sed -i.bak -E "s|^#?$1=.*|$1=$2|" .env && rm -f .env.bak
  else
    echo "$1=$2" >> .env
  fi
}

echo "Printer Hub bridge setup ($DIR)"
ask HOST "Printer IP address" "$(current PRINTER_HOST)"
ask RELAY "Relay URL (https://printer-hub-relay.<you>.workers.dev)" "$(current RELAY_URL)"
ask K2 "Creality K1/K2 camera from away? (y/n)" "n"
ask SLICE "Slice models from the app? Needs ~1 GB of disk (y/n)" "n"
ask DETECT "Spot failed prints (spaghetti) on the camera? Needs ~600 MB (y/n)" "n"
set_env PRINTER_HOST "$HOST"
set_env RELAY_URL "$RELAY"
PROFILES=
if [ "$K2" = y ] || [ "$K2" = Y ]; then
  PROFILES=creality
  set_env CAMERA_URL "http://127.0.0.1:1984/api/stream.mjpeg?src=cam_jpeg"
fi
if [ "$SLICE" = y ] || [ "$SLICE" = Y ]; then
  case $(uname -m) in
    x86_64|amd64|aarch64|arm64) PROFILES=${PROFILES:+$PROFILES,}slicer ;;
    *) echo "Slicing needs a 64-bit Intel/AMD or ARM system; skipped on $(uname -m)." ;;
  esac
fi
if [ "$DETECT" = y ] || [ "$DETECT" = Y ]; then
  case $(uname -m) in
    x86_64|amd64|aarch64|arm64) PROFILES=${PROFILES:+$PROFILES,}detector ;;
    *) echo "Failure detection needs a 64-bit Intel/AMD or ARM system; skipped on $(uname -m)." ;;
  esac
fi
[ -n "$PROFILES" ] && set_env COMPOSE_PROFILES "$PROFILES"

docker compose pull -q
docker compose up -d
echo
# Let the bridge write its pairing first, so show-code reads the same one.
for i in 1 2 3 4 5 6 7 8 9 10; do [ -f data/pairing.json ] && break; sleep 1; done
echo "Running. Pair the app: Edit printer -> Remote access code ->"
docker compose run --rm bridge --show-code
echo "Logs: cd $DIR && docker compose logs -f bridge"
case ",$(current COMPOSE_PROFILES)," in
  *,slicer,*) ;;
  *) echo "Slicing from the app is off. To turn it on later, run this installer again and answer y." ;;
esac

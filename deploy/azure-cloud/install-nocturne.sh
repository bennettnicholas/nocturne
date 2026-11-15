#!/usr/bin/env bash
# install-nocturne.sh - install or update Nocturne on any Ubuntu / Debian server.
#
# Runs Nocturne's official Docker Compose release bundle (PostgreSQL, API, web app, YARP gateway,
# Caddy for automatic HTTPS, Watchtower for automatic updates). Works on any cloud or on your own
# hardware: x64 or Arm64, 2 GB RAM minimum (4 GB recommended), ports 80 and 443 reachable.
#
# Usage:
#   sudo ./install-nocturne.sh --domain nocturne.example.com
#   sudo ./install-nocturne.sh --secrets-file secrets.env      # pre-made secrets (see below)
#
# Options:
#   --domain NAME           BASE_DOMAIN: the hostname Nocturne serves (at least two labels, not an IP).
#                           Point NAME and *.NAME at this server in DNS for tenant subdomains.
#   --secrets-file FILE     KEY=value lines to use instead of generated secrets:
#                           BASE_DOMAIN, INSTANCE_KEY, POSTGRES_PASSWORD, POSTGRES_APP_PASSWORD,
#                           POSTGRES_MIGRATOR_PASSWORD, POSTGRES_WEB_PASSWORD
#   --remove-secrets-file   Delete the secrets file once .env has been written.
#   --dir DIR               Install folder (default /opt/nocturne).
#   --release-url URL       Where to download the bundle (default: latest GitHub release).
#   --timeout MINUTES       How long to wait for the containers to become healthy (default 15).
#   -h, --help              Show this help.
#
# Safe to re-run: an existing .env is kept (the database was created with its passwords) and the
# bundle is refreshed to the latest release.
#
# Log: /var/log/nocturne-install.log. The last line is NOCTURNE_INSTALL_DONE on success.

set -euo pipefail

DIR=/opt/nocturne
DOMAIN="${NOCTURNE_DOMAIN:-}"
SECRETS_FILE=""
REMOVE_SECRETS=0
RELEASE_URL="https://github.com/nightscout/nocturne/releases/latest/download"
TIMEOUT_MIN=15
MIN_COMPOSE=2.23.1          # the release bundle uses compose "configs: content:"
LOG=/var/log/nocturne-install.log
REQUIRED_KEYS="BASE_DOMAIN INSTANCE_KEY POSTGRES_PASSWORD POSTGRES_APP_PASSWORD POSTGRES_MIGRATOR_PASSWORD POSTGRES_WEB_PASSWORD"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------ helpers (unit-tested)

# version_ge A B: true when version A >= B.
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# random_secret N: N random letters and digits. Reads a fixed amount from /dev/urandom so no
# command in the pipeline is cut off early (which would trip pipefail).
random_secret() {
  local s
  s="$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c "1-$1")"
  [ "${#s}" -eq "$1" ] || die "could not generate a random secret"
  printf '%s' "$s"
}

# valid_domain NAME: at least two labels, letters/digits/hyphens, not an IP address.
valid_domain() {
  local d="$1"
  [[ "$d" =~ ^[0-9.]+$ ]] && return 1
  [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

# build_env TEMPLATE SECRETS OUT: copy the release .env template and set each KEY=value from
# SECRETS, replacing the template's line or appending it.
build_env() {
  cp "$1" "$3"
  while IFS='=' read -r key value; do
    [ -z "$key" ] && continue
    case "$key" in \#*) continue ;; esac
    if grep -q "^${key}=" "$3"; then
      # | as the sed delimiter; secret values are letters and digits only.
      sed -i "s|^${key}=.*|${key}=${value}|" "$3"
    else
      echo "${key}=${value}" >> "$3"
    fi
  done < "$2"
  chmod 600 "$3"
}

# env_value FILE KEY: print KEY's value from a KEY=value file.
env_value() { sed -n "s/^$2=//p" "$1" | head -n1; }

compose_ok() {
  command -v docker >/dev/null 2>&1 || return 1
  local v
  v="$(docker compose version --short 2>/dev/null)" || return 1
  version_ge "${v#v}" "$MIN_COMPOSE"
}

# ------------------------------------------------------------------ steps

install_docker() {
  if compose_ok; then log "Docker $(docker --version | cut -d' ' -f3 | tr -d ,) and Compose $(docker compose version --short) already installed"; return; fi
  export DEBIAN_FRONTEND=noninteractive
  log "installing Docker"
  apt-get update -y
  apt-get install -y ca-certificates curl
  # The distro's packages first (Ubuntu ships a new enough compose)...
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    apt-get install -y docker.io docker-compose-v2 || true
  fi
  # ...otherwise Docker's official repository (e.g. Debian, whose compose is too old).
  if ! compose_ok; then
    log "using Docker's official apt repository"
    # shellcheck source=/dev/null
    . /etc/os-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  fi
  systemctl enable --now docker
  compose_ok || die "Docker Compose $MIN_COMPOSE or newer is required"
  log "Docker $(docker compose version --short) ready"
}

download() {  # download FILE: fetch from the release, with retries (networking can lag after boot)
  local i
  for i in 1 2 3 4 5 6; do
    if curl -fsSL -o "$1.new" "$RELEASE_URL/$1"; then mv "$1.new" "$1"; return 0; fi
    log "download of $1 failed (attempt $i), retrying in 10s"; sleep 10
  done
  die "could not download $RELEASE_URL/$1"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    log "ufw is active: allowing 80/tcp, 443/tcp, 443/udp"
    ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw allow 443/udp >/dev/null
  fi
}

write_env() {
  if [ -f .env ]; then
    log ".env already exists; keeping it (the database was created with its passwords)"
    local current; current="$(env_value .env BASE_DOMAIN)"
    if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "$current" ]; then
      warn "--domain $DOMAIN differs from BASE_DOMAIN=$current in .env; edit .env to change it, then re-run"
    fi
    return
  fi

  local secrets; secrets="$(mktemp)"; chmod 600 "$secrets"
  if [ -n "$SECRETS_FILE" ]; then
    [ -f "$SECRETS_FILE" ] || die "secrets file not found: $SECRETS_FILE"
    grep -v '^BASE_DOMAIN=' "$SECRETS_FILE" > "$secrets" || true
    [ -z "$DOMAIN" ] && DOMAIN="$(env_value "$SECRETS_FILE" BASE_DOMAIN)"
  else
    {
      echo "INSTANCE_KEY=$(random_secret 64)"
      echo "POSTGRES_PASSWORD=$(random_secret 40)"
      echo "POSTGRES_APP_PASSWORD=$(random_secret 40)"
      echo "POSTGRES_MIGRATOR_PASSWORD=$(random_secret 40)"
      echo "POSTGRES_WEB_PASSWORD=$(random_secret 40)"
    } > "$secrets"
    log "generated INSTANCE_KEY and the four Postgres passwords"
  fi

  if [ -z "$DOMAIN" ] && [ -t 0 ]; then read -r -p "Domain for Nocturne (e.g. nocturne.example.com): " DOMAIN; fi
  [ -n "$DOMAIN" ] || { rm -f "$secrets"; die "no domain: pass --domain NAME (or BASE_DOMAIN in --secrets-file)"; }
  valid_domain "$DOMAIN" || { rm -f "$secrets"; die "'$DOMAIN' is not a valid domain (needs at least two labels, not an IP)"; }
  echo "BASE_DOMAIN=$DOMAIN" >> "$secrets"

  local key
  for key in $REQUIRED_KEYS; do
    grep -q "^${key}=." "$secrets" || { rm -f "$secrets"; die "missing $key"; }
  done

  build_env default.env.example "$secrets" .env
  rm -f "$secrets"
  log ".env written for https://$DOMAIN"
}

wait_healthy() {
  local deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 )) last="" now pending line
  log "waiting for containers to become healthy (up to ${TIMEOUT_MIN} min)"
  while true; do
    now="$(docker compose ps -a --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null | sort)"
    [ "$now" != "$last" ] && { printf '%s\n' "$now" | awk '{ print "    " $0 }'; last="$now"; }
    # Not ready: anything starting, unhealthy, restarting or exited.
    pending="$(echo "$now" | awk '$2!="running" || $3=="starting" || $3=="unhealthy"')"
    if [ -n "$now" ] && [ -z "$pending" ]; then log "all containers are running"; return 0; fi
    if echo "$now" | awk '$2=="exited" || $2=="restarting" || $2=="dead"' | grep -q .; then
      line="$(echo "$now" | awk '$2=="exited" || $2=="restarting" || $2=="dead" {print $1; exit}')"
      if [ "$(date +%s)" -gt $(( deadline - TIMEOUT_MIN * 60 + 120 )) ]; then
        docker compose logs --tail 30 --no-color "$line" || true
        die "container '$line' is not staying up (logs above)"
      fi
    fi
    [ "$(date +%s)" -gt "$deadline" ] && { docker compose logs --tail 30 --no-color || true; die "containers not healthy after ${TIMEOUT_MIN} minutes"; }
    sleep 10
  done
}

main() {
  local orig_args="$*"
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain) DOMAIN="${2:?}"; shift 2 ;;
      --secrets-file) SECRETS_FILE="${2:?}"; shift 2 ;;
      --remove-secrets-file) REMOVE_SECRETS=1; shift ;;
      --dir) DIR="${2:?}"; shift 2 ;;
      --release-url) RELEASE_URL="${2:?}"; shift 2 ;;
      --timeout) TIMEOUT_MIN="${2:?}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
  done

  [ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo $0 $orig_args" >&2; exit 1; }
  touch "$LOG"; chmod 600 "$LOG"
  exec > >(tee -a "$LOG") 2>&1

  log "Nocturne install starting ($(uname -m))"
  # shellcheck source=/dev/null
  [ -r /etc/os-release ] && . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*) ;;
    *) die "unsupported OS '${PRETTY_NAME:-unknown}': this script needs Ubuntu or Debian (apt)" ;;
  esac
  local mem_mb; mem_mb=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
  [ "$mem_mb" -lt 1800 ] && warn "only ${mem_mb} MB RAM; Nocturne needs 2 GB (4 GB recommended)"

  install_docker
  open_firewall
  mkdir -p "$DIR"; chmod 700 "$DIR"; cd "$DIR"
  log "downloading the release bundle"
  download docker-compose.yaml
  download default.env.example
  write_env
  [ "$REMOVE_SECRETS" -eq 1 ] && [ -n "$SECRETS_FILE" ] && rm -f "$SECRETS_FILE"

  log "pulling images (a few minutes on first install)"
  docker compose pull
  log "starting containers"
  docker compose up -d --remove-orphans
  wait_healthy

  log "Nocturne is running: https://$(env_value .env BASE_DOMAIN)"
  log "Back up $DIR/.env somewhere safe: without INSTANCE_KEY, stored connector secrets are lost."
  log "Updates install automatically (Watchtower). Re-run this script to refresh the bundle."
  log "NOCTURNE_INSTALL_DONE"
}

# Run main unless sourced (lets the tests load the helper functions).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi

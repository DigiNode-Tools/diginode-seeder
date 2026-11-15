#!/usr/bin/env bash
#
# DigiNode Seeder - run DNS seeders for DigiByte on your own server.
#
#   curl -sSL https://seedsetup.diginode.tools | sudo bash
#
# Sets up one or more DNS seeders (DigiByte mainnet and/or testnet) on one
# server with one IP address. dnsdist answers DNS on port 53 and passes each
# seed name to its own seeder; each seeder runs as a locked-down systemd
# service. Run it again at any time to update, change settings or check status.
#
# Guide: https://diginode.tools/diginode-seeder/
# Part of DigiNode Tools: https://diginode.tools
# Copyright (c) 2026 Oliver Stedall. Licensed under the PolyForm Perimeter
# License 1.0.0 - see LICENCE.md.

set -Eeuo pipefail
trap 'printf "\n[✗] Stopped unexpectedly at line %s. Please report this: https://github.com/DigiNode-Tools/diginode-seeder/issues\n" "$LINENO" >&2' ERR

DGNS_VERSION="0.2.4"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
CONF_DIR="/etc/diginode-seeder"            # settings + one .conf per seeder
INSTALL_DIR="/opt/diginode-seeder"         # bin/ and src/
STATE_BASE="/var/lib/diginode-seeder"      # each seeder's crawl database
RUN_USER="diginode-seeder"
UNIT_FILE="/etc/systemd/system/diginode-seeder@.service"
DNSDIST_CONF="/etc/dnsdist/dnsdist.conf"
DNSDIST_MARK="-- Written by DigiNode Seeder"
CMD_LINK="/usr/local/bin/diginode-seeder"  # the diginode-seeder command
MOTD_FILE="/etc/update-motd.d/50-diginode-seeder"   # the login message
UPDATES_CONF="/etc/apt/apt.conf.d/52diginode-seeder-auto-updates"   # automatic updates: restarts, config files
APT_PERIODIC_CONF="/etc/apt/apt.conf.d/20auto-upgrades"            # turns daily updates on or off
DGNT_UPDATES_CONF="/etc/apt/apt.conf.d/52diginode-auto-updates"    # DigiNode Tools' own, if it's on this server
RESTART_TIME="03:30"                                               # automatic restarts, server time
RELEASES_URL="https://github.com/DigiNode-Tools/diginode-seeder/releases"
GUIDE_URL="https://diginode.tools/diginode-seeder/"

# ---------------------------------------------------------------------------
# Chains and networks
#
# Each seeder is "<chain>-<network>". To add a chain (e.g. Bitcoin), add its
# entries here; nothing else in the script is chain-specific.
# ---------------------------------------------------------------------------
CHAINS=(digibyte)
declare -A CHAIN_NAME=([digibyte]="DigiByte")
declare -A CHAIN_REPO=([digibyte]="https://github.com/DigiNode-Tools/digibyte-seeder.git")
declare -A CHAIN_BRANCH=([digibyte]="master")
declare -A CHAIN_NETWORKS=([digibyte]="mainnet testnet")

declare -A NET_LABEL=(
  [digibyte-mainnet]="DigiByte mainnet"
  [digibyte-testnet]="DigiByte testnet (v9, testnet26)"
)
declare -A NET_SHORT=(                      # short name for the status table
  [digibyte-mainnet]="DigiByte mainnet"
  [digibyte-testnet]="DigiByte testnet"
)
declare -A NET_ARGS=(                       # extra seeder arguments
  [digibyte-mainnet]=""
  [digibyte-testnet]="--testnet"
)
declare -A NET_DNS_PORT=(                   # local port dnsdist forwards to
  [digibyte-mainnet]=5301
  [digibyte-testnet]=5302
)
declare -A NET_P2P_PORT=(                   # for information only
  [digibyte-mainnet]=12024
  [digibyte-testnet]=12033
)
declare -A NET_SEED_PREFIX=(                # suggested seed name
  [digibyte-mainnet]="seed"
  [digibyte-testnet]="testnetseed"
)
# Where the chain's node software lists its seeds, for the "add it to DigiByte Core" step.
declare -A CHAIN_CORE_NAME=([digibyte]="DigiByte Core")
declare -A CHAIN_CORE_FILE=([digibyte]="src/kernel/chainparams.cpp")
declare -A CHAIN_CORE_RAW=([digibyte]="https://raw.githubusercontent.com/DigiByte-Core/digibyte/develop/src/kernel/chainparams.cpp")
declare -A NET_CORE_LIST=(                  # the list in that file the seed goes into
  [digibyte-mainnet]="mainnet list"
  [digibyte-testnet]="testnet list"
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; CYN=$'\e[36m'; R=$'\e[0m'
else
  B=""; DIM=""; RED=""; GRN=""; YLW=""; CYN=""; R=""
fi
say()   { printf '%s\n' "$*"; }
info()  { printf '%s[i]%s %s\n' "$CYN" "$R" "$*"; }
ok()    { printf '%s[✓]%s %s\n' "$GRN" "$R" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$YLW" "$R" "$*"; }
fail()  { printf '%s[✗]%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }
title() { printf '\n%s%s%s\n' "$B" "$*" "$R"; }

# The DigiNode logo, as in DigiNode Tools' login message.
show_logo() {
  printf '%s' "$B"
  cat <<'LOGO'
       ____   _         _   _   __            __
      / __ \ (_)____ _ (_) / | / /____   ____/ /___
     / / / // // __ '// / /  |/ // __ \ / __  // _ \
    / /_/ // // /_/ // / / /|  // /_/ // /_/ //  __/
   /_____//_/ \__, //_/ /_/ |_/ \____/ \__,_/ \___/
              /____/       https://diginode.tools
LOGO
  printf '%s' "$R"
}

# Run a slow command with a spinner and the time so far, so it never looks frozen.
# Its output goes to a log, shown only if it fails.
spin() { # spin "Message" command [args...]
  local msg="$1"; shift
  local log rc=0; log=$(mktemp)
  if [[ -t 1 ]]; then
    "$@" >"$log" 2>&1 &
    local pid=$! s=0 i=0 chars='|/-\'
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r%s[%s]%s %s  %s%dm %02ds%s ' "$CYN" "${chars:i%4:1}" "$R" "$msg" "$DIM" $((s / 60)) $((s % 60)) "$R"
      i=$((i + 1)); sleep 1; s=$((s + 1))
    done
    wait "$pid" || rc=$?
    printf '\r\e[K'
  else
    say "... $msg"
    "$@" >"$log" 2>&1 || rc=$?
  fi
  if (( rc != 0 )); then tail -25 "$log" >&2; fi
  rm -f "$log"
  return "$rc"
}

# The command to show users: the installed one, or the curl one if it isn't installed.
cmd_hint() { # cmd_hint [--option]
  if [[ -x $CMD_LINK ]]; then
    printf '%s%s' "diginode-seeder" "${1:+ $1}"
  else
    printf 'curl -sSL https://seedsetup.diginode.tools | sudo bash%s' "${1:+ -s -- $1}"
  fi
}

# Questions read from the terminal, so the script also works with curl | bash.
TTY="/dev/tty"
ASSUME_YES=0
# /dev/tty can exist without a terminal behind it (e.g. ssh without one), so try opening it.
has_tty() { { : < "$TTY"; } 2>/dev/null; }
ask() { # ask "Question" "default" -> REPLY
  local q="$1" def="${2:-}"
  if [[ $ASSUME_YES -eq 1 ]]; then REPLY="$def"; return; fi
  has_tty || fail "No terminal to ask questions on. Use the command-line options (see --help)."
  if [[ -n $def ]]; then printf '%s %s[%s]%s: ' "$q" "$DIM" "$def" "$R" > "$TTY"
  else printf '%s: ' "$q" > "$TTY"; fi
  IFS= read -r REPLY < "$TTY" || true
  REPLY="${REPLY:-$def}"
}
confirm() { # confirm "Question" [default y|n]
  local def="${2:-y}" hint="[Y/n]"
  [[ $def == n ]] && hint="[y/N]"
  if [[ $ASSUME_YES -eq 1 ]]; then [[ $def == y ]]; return; fi
  has_tty || fail "No terminal to ask questions on. Use --yes to accept the defaults."
  printf '%s %s ' "$1" "$hint" > "$TTY"
  local a; IFS= read -r a < "$TTY" || true
  a="${a:-$def}"
  [[ $a =~ ^[Yy] ]]
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
valid_hostname() {
  [[ $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

# SOA records hold an email address with the @ replaced by a dot.
email_to_mbox() {
  local e="$1" user domain
  [[ $e =~ ^([^@[:space:]]+)@([^@[:space:]]+)$ ]] || return 1
  user="${BASH_REMATCH[1]}"; domain="${BASH_REMATCH[2]}"
  [[ $user == *.* ]] && return 2       # a dot here would need escaping
  valid_hostname "$domain" || return 1
  printf '%s.%s' "$user" "$domain"
}

need_root() {
  [[ $EUID -eq 0 ]] && return 0
  if [[ $AS_COMMAND -eq 1 ]]; then
    # The installed command asks for administrator rights itself, so users never need to type sudo.
    command -v sudo >/dev/null || fail "This needs administrator rights. Log in as root and run it again."
    exec sudo "$0" "${ORIG_ARGS[@]}"
  else fail "Please run as root, for example: curl -sSL https://seedsetup.diginode.tools | sudo bash"; fi
}

check_system() {
  need_root
  [[ -r /etc/os-release ]] || fail "Can't tell which Linux this is (no /etc/os-release)."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ok "System: $PRETTY_NAME" ;;
    debian:*|ubuntu:*) warn "$PRETTY_NAME hasn't been tested. Debian 12/13 or Ubuntu 22.04/24.04 are recommended."
                       confirm "Carry on anyway?" n || exit 1 ;;
    *) fail "$PRETTY_NAME isn't supported. Use Debian 12/13 or Ubuntu 22.04/24.04." ;;
  esac
  command -v systemctl >/dev/null || fail "systemd is needed."
  MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  (( MEM_MB >= 400 )) || warn "Only ${MEM_MB} MB of memory. Each seeder uses about 50-150 MB."
}

# Small servers (under 1 GB) get a 1 GB swap file, so building the seeder
# can't run out of memory. Nothing is changed if any swap already exists.
ensure_swap() {
  (( MEM_MB < 1000 )) || return 0
  [[ -z $(swapon --noheadings 2>/dev/null) ]] || return 0
  local free_mb; free_mb=$(df -Pm / | awk 'NR==2{print $4}')
  if (( free_mb < 3000 )); then warn "Low memory and little disk space: no swap file added."; return 0; fi
  title "Adding a 1 GB swap file (this server has ${MEM_MB} MB of memory)"
  fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
  chmod 600 /swapfile
  mkswap -q /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap file /swapfile added"
}

# The address other computers reach this server on, and the local address
# dnsdist listens on (the same unless the server is behind NAT).
detect_addresses() {
  LOCAL_V4=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
  PUBLIC_V4=$(curl -4 -fsS -m 10 https://ipv4.diginode.tools/my-ip 2>/dev/null | sed -n 's/.*"ip":"\([0-9.]*\)".*/\1/p' || true)
  [[ -n $PUBLIC_V4 ]] || PUBLIC_V4="$LOCAL_V4"
  LOCAL_V6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | sed -n 's/.* src \([0-9a-fA-F:]*\).*/\1/p' | head -1)
  # Only a public IPv6 address is any use (not link-local fe80::, or private fc00::/7).
  case "${LOCAL_V6,,}" in fe80:*|fc*|fd*) LOCAL_V6="" ;; esac
  [[ -n $LOCAL_V4 || -n $LOCAL_V6 ]] || fail "Couldn't find this server's IP address."
  if [[ -n $LOCAL_V4 && $LOCAL_V4 != "$PUBLIC_V4" ]]; then
    warn "This server is behind NAT (local $LOCAL_V4, public $PUBLIC_V4)."
    warn "Make sure UDP port 53 is forwarded to $LOCAL_V4."
  fi
}

# Anything else answering on port 53 of the address dnsdist needs?
check_port53() {
  local busy
  busy=$(ss -Hlnup 2>/dev/null | awk '$4 ~ /:53$/' | grep -v '"dnsdist"' || true)
  [[ -z $busy ]] && return 0
  local addr clash=0
  while read -r line; do
    addr=$(awk '{print $4}' <<<"$line")
    case "$addr" in
      127.0.0.53%*:53|127.0.0.53:53|127.0.0.54:53|"[::1]:53"|127.0.0.1:53) ;;  # local resolver stubs: no clash
      *) clash=1; warn "Port 53 is already in use: $line" ;;
    esac
  done <<<"$busy"
  [[ $clash -eq 0 ]] || fail "Another DNS server is using port 53. Stop it (or use a separate server) and run this again."
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
load_settings() {
  NS_HOST=""; SOA_EMAIL=""; SETUP_DATE=""; MOTD=""; AUTO_UPDATES=""; AUTO_RESTART=""; ENABLED=()
  declare -gA SEED_HOST=()
  [[ -r $CONF_DIR/settings ]] || return 1
  # shellcheck disable=SC1091
  . "$CONF_DIR/settings"
  local f id
  for f in "$CONF_DIR"/*.conf; do
    [[ -e $f ]] || continue
    id=$(basename "$f" .conf)
    [[ -n ${NET_LABEL[$id]:-} ]] || continue
    SEED_HOST[$id]=$(sed -n 's/^SEED_HOST="\(.*\)"$/\1/p' "$f")
    ENABLED+=("$id")
  done
  return 0
}

write_settings_file() {
  install -d -m 755 "$CONF_DIR"
  cat > "$CONF_DIR/settings" <<EOF
# DigiNode Seeder settings. Run the setup again to change them.
NS_HOST="$NS_HOST"
SOA_EMAIL="$SOA_EMAIL"
SETUP_DATE="${SETUP_DATE:-$(date -u +%F)}"
MOTD="${MOTD:-yes}"
AUTO_UPDATES="${AUTO_UPDATES:-yes}"
AUTO_RESTART="${AUTO_RESTART:-yes}"
EOF
}

# Keep the setup date and login message choice when the settings come from the command line.
keep_saved_extras() {
  [[ -r $CONF_DIR/settings ]] || return 0
  [[ -n $SETUP_DATE ]] || SETUP_DATE=$(sed -n 's/^SETUP_DATE="\(.*\)"$/\1/p' "$CONF_DIR/settings")
  [[ -n $MOTD ]] || MOTD=$(sed -n 's/^MOTD="\(.*\)"$/\1/p' "$CONF_DIR/settings")
  [[ -n $AUTO_UPDATES ]] || AUTO_UPDATES=$(sed -n 's/^AUTO_UPDATES="\(.*\)"$/\1/p' "$CONF_DIR/settings")
  [[ -n $AUTO_RESTART ]] || AUTO_RESTART=$(sed -n 's/^AUTO_RESTART="\(.*\)"$/\1/p' "$CONF_DIR/settings")
}

save_settings() {
  write_settings_file
  local id mbox
  mbox=$(email_to_mbox "$SOA_EMAIL")
  # Remove seeders that were turned off
  for f in "$CONF_DIR"/*.conf; do
    [[ -e $f ]] || continue
    id=$(basename "$f" .conf)
    if [[ " ${ENABLED[*]} " != *" $id "* ]]; then
      systemctl disable --now "diginode-seeder@$id" >/dev/null 2>&1 || true
      mv "$f" "$f.off"
      info "Turned off ${NET_LABEL[$id]:-$id}."
    fi
  done
  for id in "${ENABLED[@]}"; do
    cat > "$CONF_DIR/$id.conf" <<EOF
# ${NET_LABEL[$id]} seeder. Written by DigiNode Seeder - run the setup again to change it.
CHAIN="${id%%-*}"
SEED_HOST="${SEED_HOST[$id]}"
NS_HOST="$NS_HOST"
SOA_MBOX="$mbox"
DNS_PORT="${NET_DNS_PORT[$id]}"
SEEDER_ARGS="${NET_ARGS[$id]}"
EOF
  done
}

ask_settings() {
  local id chain net def
  title "Which seeders?"
  say "Each seeder needs its own name (e.g. seed.example.com). One server can run them all."
  local new_enabled=()
  for chain in "${CHAINS[@]}"; do
    for net in ${CHAIN_NETWORKS[$chain]}; do
      id="$chain-$net"
      def=n; [[ " ${ENABLED[*]} " == *" $id "* || ${#ENABLED[@]} -eq 0 ]] && def=y
      if confirm "Run a ${B}${NET_LABEL[$id]}${R} seeder?" "$def"; then new_enabled+=("$id"); fi
    done
  done
  [[ ${#new_enabled[@]} -gt 0 ]] || fail "No seeders chosen."
  ENABLED=("${new_enabled[@]}")

  title "Names"
  say "You need a domain you control, with access to its DNS records."
  local domain_guess=""
  [[ -n $NS_HOST ]] && domain_guess="${NS_HOST#*.}"
  if [[ -z $domain_guess ]]; then
    ask "Your domain (e.g. example.com)" ""
    domain_guess="$REPLY"
  fi
  for id in "${ENABLED[@]}"; do
    def="${SEED_HOST[$id]:-${NET_SEED_PREFIX[$id]}.$domain_guess}"
    while :; do
      ask "Seed name for ${NET_LABEL[$id]}" "$def"
      valid_hostname "$REPLY" && break
      warn "That isn't a valid name."
    done
    SEED_HOST[$id]="${REPLY,,}"
  done
  say ""
  say "The nameserver name points at this server. The seed names are handed to it."
  while :; do
    ask "Nameserver name for this server" "${NS_HOST:-dnsseed.$domain_guess}"
    if ! valid_hostname "$REPLY"; then warn "That isn't a valid name."; continue; fi
    local clash=""
    for id in "${ENABLED[@]}"; do
      [[ ${REPLY,,} == "${SEED_HOST[$id]}" || ${REPLY,,} == *".${SEED_HOST[$id]}" ]] && clash="${SEED_HOST[$id]}"
    done
    [[ -z $clash ]] && break
    warn "The nameserver name can't be $clash or inside it. Use a different name, e.g. dnsseed.$domain_guess."
  done
  NS_HOST="${REPLY,,}"
  while :; do
    ask "Contact email (shown in the seed's DNS records)" "${SOA_EMAIL:-}"
    local rc=0; email_to_mbox "$REPLY" >/dev/null || rc=$?
    [[ $rc -eq 0 ]] && break
    if [[ $rc -eq 2 ]]; then warn "Please use an address without a dot before the @ (DNS can't show those simply)."
    else warn "That isn't a valid email address."; fi
  done
  SOA_EMAIL="$REPLY"
  ask_motd
  ask_updates
}

ask_updates() {
  title "System updates"
  say "A seeder is a small public server that's easy to forget about, so it's safest when it"
  say "installs security updates by itself."
  local def=y; [[ $AUTO_UPDATES == no ]] && def=n
  if confirm "Install security updates automatically?" "$def"; then AUTO_UPDATES=yes; else AUTO_UPDATES=no; AUTO_RESTART=no; return; fi
  say "Some updates (such as a new Linux kernel) only take effect after a restart. The seeders"
  say "start again by themselves, so it's only down for a minute or so."
  def=y; [[ $AUTO_RESTART == no ]] && def=n
  if confirm "Restart automatically when an update needs it (at $RESTART_TIME server time)?" "$def"; then AUTO_RESTART=yes; else AUTO_RESTART=no; fi
}

ask_motd() {
  title "Login message"
  say "When you log in over SSH, it can show the DigiNode logo and the command to manage your"
  say "seeders (diginode-seeder), so you don't need to remember anything."
  local def=y; [[ $MOTD == no ]] && def=n
  if confirm "Show the DigiNode Seeder login message?" "$def"; then MOTD=yes; else MOTD=no; fi
}

show_summary() {
  title "Summary"
  local id
  for id in "${ENABLED[@]}"; do
    printf '  %-36s %s  %s(nodes on port %s)%s\n' "${NET_LABEL[$id]}" "${SEED_HOST[$id]}" "$DIM" "${NET_P2P_PORT[$id]}" "$R"
  done
  printf '  %-36s %s\n' "Nameserver (this server)" "$NS_HOST"
  printf '  %-36s %s\n' "Contact email" "$SOA_EMAIL"
  printf '  %-36s %s\n' "Login message" "${MOTD:-yes}"
  local upd="no"
  [[ ${AUTO_UPDATES:-yes} == yes ]] && upd="yes, restarting at $RESTART_TIME when needed"
  [[ ${AUTO_UPDATES:-yes} == yes && ${AUTO_RESTART:-yes} == no ]] && upd="yes, without automatic restarts"
  printf '  %-36s %s\n' "Automatic security updates" "$upd"
  printf '  %-36s %s\n' "Server address" "${PUBLIC_V4:-none}${LOCAL_V6:+, $LOCAL_V6}"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
apt_install() {
  apt-get update -qq
  apt-get install -y -qq build-essential libssl-dev libboost-dev git dnsdist dnsutils curl ca-certificates
}
install_packages() {
  title "Installing packages"
  export DEBIAN_FRONTEND=noninteractive
  spin "Installing build tools, dnsdist and dig (usually 1-2 minutes)" apt_install || fail "Installing packages failed."
  ok "build tools, dnsdist and dig installed"
}

build_seeders() {
  local chain src commit
  install -d -m 755 "$INSTALL_DIR/bin" "$INSTALL_DIR/src"
  local chains_needed=()
  for id in "${ENABLED[@]}"; do
    chain="${id%%-*}"
    [[ " ${chains_needed[*]} " == *" $chain "* ]] || chains_needed+=("$chain")
  done
  for chain in "${chains_needed[@]}"; do
    title "Building the ${CHAIN_NAME[$chain]} seeder"
    src="$INSTALL_DIR/src/$chain-seeder"
    if [[ -d $src/.git ]]; then
      spin "Checking for seeder updates" git -C "$src" fetch -q origin "${CHAIN_BRANCH[$chain]}" || fail "Couldn't reach GitHub."
      git -C "$src" reset -q --hard "origin/${CHAIN_BRANCH[$chain]}"
    else
      spin "Downloading the seeder's source code" git clone -q --branch "${CHAIN_BRANCH[$chain]}" "${CHAIN_REPO[$chain]}" "$src" || fail "Couldn't download the seeder from GitHub."
    fi
    commit=$(git -C "$src" rev-parse --short HEAD)
    # Same code as the program already built: nothing to do. (Builds aren't byte-identical, so rebuilding would
    # make the seeder look changed and restart it, and a restarted seeder hands out few nodes for a while.)
    if [[ -x $INSTALL_DIR/bin/$chain-seeder ]] && [[ $(cat "$INSTALL_DIR/bin/$chain-seeder.commit" 2>/dev/null) == "$commit" ]]; then
      ok "${CHAIN_NAME[$chain]} seeder is up to date (${CHAIN_REPO[$chain]%.git} @ $commit)"
      continue
    fi
    make -C "$src" -s clean >/dev/null 2>&1 || true
    local jobs; jobs=$(nproc); (( MEM_MB < 1500 )) && jobs=1
    spin "Building the ${CHAIN_NAME[$chain]} seeder (usually 2-5 minutes)" make -C "$src" -s -j"$jobs" || fail "The build failed."
    install -m 755 "$src/dnsseed" "$INSTALL_DIR/bin/$chain-seeder.new"
    mv -f "$INSTALL_DIR/bin/$chain-seeder.new" "$INSTALL_DIR/bin/$chain-seeder"
    echo "$commit" > "$INSTALL_DIR/bin/$chain-seeder.commit"
    ok "${CHAIN_NAME[$chain]} seeder built (${CHAIN_REPO[$chain]%.git} @ $commit)"
  done
}

install_service() {
  id -u "$RUN_USER" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir "$STATE_BASE" --shell /usr/sbin/nologin "$RUN_USER"
  install -d -m 755 "$STATE_BASE"

  # Starts one seeder from its .conf file.
  cat > "$INSTALL_DIR/bin/run-seeder" <<'EOF'
#!/bin/sh
# Started by diginode-seeder@<id>.service. Reads /etc/diginode-seeder/<id>.conf.
set -eu
. "/etc/diginode-seeder/$1.conf"
# shellcheck disable=SC2086
exec "/opt/diginode-seeder/bin/$CHAIN-seeder" -h "$SEED_HOST" -n "$NS_HOST" -m "$SOA_MBOX" \
  -a 127.0.0.1 -p "$DNS_PORT" $SEEDER_ARGS
EOF
  chmod 755 "$INSTALL_DIR/bin/run-seeder"

  cat > "$UNIT_FILE" <<EOF
# Written by DigiNode Seeder $DGNS_VERSION
[Unit]
Description=DigiNode Seeder (%i)
Documentation=https://diginode.tools/diginode-seeder/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
Group=$RUN_USER
ExecStart=$INSTALL_DIR/bin/run-seeder %i
StateDirectory=diginode-seeder/%i
WorkingDirectory=$STATE_BASE/%i
Restart=always
RestartSec=10
LimitNOFILE=8192
# Lock it down: it only needs the network and its own folder.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
CapabilityBoundingSet=
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallErrorNumber=EPERM
ProtectProc=invisible
ProcSubset=pid
PrivateUsers=yes
RemoveIPC=yes
UMask=0077
MemoryMax=1G

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# Install this script as the diginode-seeder command. When it was piped from curl there's no file to copy,
# so the same version is downloaded from its GitHub release.
install_command() {
  local src="${BASH_SOURCE[0]:-}" tmp=""
  if [[ -z $src || ! -f $src ]]; then
    tmp=$(mktemp); src="$tmp"
    if ! curl -fsSL -m 60 "$RELEASES_URL/download/v$DGNS_VERSION/diginode-seeder.sh" -o "$tmp" 2>/dev/null \
       || ! grep -qx "DGNS_VERSION=\"$DGNS_VERSION\"" "$tmp"; then
      rm -f "$tmp"
      warn "Couldn't install the diginode-seeder command (version $DGNS_VERSION isn't on GitHub)."
      return 0
    fi
  fi
  if [[ $(realpath "$src") != "$(realpath "$INSTALL_DIR/bin/diginode-seeder" 2>/dev/null || true)" ]]; then
    install -m 755 "$src" "$INSTALL_DIR/bin/diginode-seeder.new"
    mv -f "$INSTALL_DIR/bin/diginode-seeder.new" "$INSTALL_DIR/bin/diginode-seeder"   # a new file, so a running copy isn't disturbed
  fi
  [[ -z $tmp ]] || rm -f "$tmp"
  ln -sfn "$INSTALL_DIR/bin/diginode-seeder" "$CMD_LINK"
}

# The login message: a script in /etc/update-motd.d, run at each SSH login. Like DigiNode Tools, the system's
# own /etc/motd text is moved aside while it's on, and put back when it's turned off.
apply_motd() {
  if [[ ${MOTD:-yes} == no ]]; then remove_motd; return 0; fi
  if [[ ! -d /etc/update-motd.d ]]; then warn "No /etc/update-motd.d on this system, so no login message."; return 0; fi
  {
    printf '#!/bin/sh\n# DigiNode Seeder login message. Written by DigiNode Seeder %s - updates overwrite it.\n' "$DGNS_VERSION"
    printf '# Turn it off with: diginode-seeder --motd off\n'
    cat <<'EOF'
b=$(printf '\033[1m'); y=$(printf '\033[33m'); r=$(printf '\033[0m')
echo
# DigiNode Tools on the same server shows the logo already.
if [ ! -x /etc/update-motd.d/50-diginode ]; then
printf '%s' "$b"
cat <<'LOGO'
       ____   _         _   _   __            __
      / __ \ (_)____ _ (_) / | / /____   ____/ /___
     / / / // // __ '// / /  |/ // __ \ / __  // _ \
    / /_/ // // /_/ // / / /|  // /_/ // /_/ //  __/
   /_____//_/ \__, //_/ /_/ |_/ \____/ \__,_/ \___/
              /____/       https://diginode.tools
LOGO
printf '%s\n' "$r"
fi
printf '     Check DigiNode Seeder Status: %sdiginode-seeder%s\n\n' "$b" "$r"
printf '      For help, enter: %sdiginode-seeder --help%s\n' "$b" "$r"
# Say so if anything has stopped.
stopped=""
systemctl is-active -q dnsdist || stopped=" dnsdist"
for f in /etc/diginode-seeder/*.conf; do
  [ -e "$f" ] || continue
  id=$(basename "$f" .conf)
  systemctl is-active -q "diginode-seeder@$id" || stopped="$stopped $id"
done
if [ -n "$stopped" ]; then
  printf '\n     %s[!] Not running:%s%s - check with: %sdiginode-seeder%s\n' "$y" "$stopped" "$r" "$b" "$r"
fi
if [ -f /var/run/reboot-required ]; then
  if grep -qs '^Unattended-Upgrade::Automatic-Reboot "true"' /etc/apt/apt.conf.d/52diginode-seeder-auto-updates; then
    printf '\n     A restart is needed to finish installing updates. It will restart at %s.\n' "$(sed -n 's/^Unattended-Upgrade::Automatic-Reboot-Time "\(.*\)";/\1/p' /etc/apt/apt.conf.d/52diginode-seeder-auto-updates)"
  else
    printf '\n     %s[!] A restart is needed to finish installing updates:%s %ssudo reboot%s\n' "$y" "$r" "$b" "$r"
  fi
fi
echo
EOF
  } > "$MOTD_FILE.new"
  chmod 755 "$MOTD_FILE.new"
  mv -f "$MOTD_FILE.new" "$MOTD_FILE"
  if [[ -s /etc/motd && ! -e /etc/motd.before-diginode-seeder ]]; then
    mv /etc/motd /etc/motd.before-diginode-seeder
  fi
  ok "Login message on (turn it off with: diginode-seeder --motd off)"
}

remove_motd() {
  [[ -e $MOTD_FILE ]] || return 0
  rm -f "$MOTD_FILE"
  if [[ -e /etc/motd.before-diginode-seeder && ! -e /etc/motd ]]; then
    mv /etc/motd.before-diginode-seeder /etc/motd
  fi
  ok "Login message off"
}

# Automatic security updates, with unattended-upgrades: the system's own choice of updates (its security updates),
# changed config files kept instead of asking (DigiNode Seeder changes dnsdist's, so without this dnsdist would
# never be updated), and a restart at RESTART_TIME when an update needs one.
apply_updates() {
  if [[ -f $DGNT_UPDATES_CONF ]]; then
    info "System updates are managed by DigiNode Tools on this server (diginode-setup > System)."
    return 0
  fi
  if [[ ${AUTO_UPDATES:-yes} == no ]]; then
    if [[ -f $UPDATES_CONF ]]; then
      rm -f "$UPDATES_CONF"
      printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "0";' > "$APT_PERIODIC_CONF"
      ok "Automatic security updates off"
    fi
    return 0
  fi
  if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    spin "Installing unattended-upgrades" apt-get install -y -qq unattended-upgrades \
      || { warn "Couldn't install unattended-upgrades, so updates aren't automatic."; return 0; }
  fi
  printf '%s\n' 'APT::Periodic::Update-Package-Lists "1";' 'APT::Periodic::Unattended-Upgrade "1";' > "$APT_PERIODIC_CONF"
  local restart=false; [[ ${AUTO_RESTART:-yes} == yes ]] && restart=true
  cat > "$UPDATES_CONF.new" <<EOF
// Automatic security updates - written by DigiNode Seeder. Changes here are overwritten.
// Change them with: diginode-seeder --auto-updates on|off   or   diginode-seeder --auto-restart on|off
Unattended-Upgrade::Automatic-Reboot "$restart";
Unattended-Upgrade::Automatic-Reboot-Time "$RESTART_TIME";
Dpkg::Options {
        "--force-confdef";
        "--force-confold";
};
EOF
  mv -f "$UPDATES_CONF.new" "$UPDATES_CONF"
  # A mistake in an apt config file would break apt, so check it can be read.
  if ! apt-config dump >/dev/null 2>&1; then
    rm -f "$UPDATES_CONF"; warn "Couldn't set up automatic restarts; the system's own update settings are used."
    return 0
  fi
  if [[ $restart == true ]]; then ok "Automatic security updates on (restarting at $RESTART_TIME when an update needs it)"
  else ok "Automatic security updates on (no automatic restarts)"; fi
}

# For the status: a line about updates, and one if a restart is needed.
updates_status() {
  if [[ -f $DGNT_UPDATES_CONF ]]; then
    printf '  %b %s\n' "${GRN}✓${R}" "Automatic system updates: managed by DigiNode Tools"
  elif [[ ${AUTO_UPDATES:-} == yes && -f $UPDATES_CONF ]]; then
    local last; last=$(systemctl show -p LastTriggerUSec --value apt-daily-upgrade.timer 2>/dev/null || true)
    if [[ -z $last || $last == n/a ]]; then last="not yet"; else last=$(date -d "$last" '+%-d %b %H:%M' 2>/dev/null || echo "$last"); fi
    printf '  %b %s\n' "${GRN}✓${R}" "Automatic security updates: on (last run: $last)"
  else
    printf '  %b %s\n' "${YLW}!${R}" "Automatic security updates: off (turn on: diginode-seeder --auto-updates on)"
  fi
  if [[ -f /var/run/reboot-required ]]; then
    if [[ ${AUTO_RESTART:-} == yes && -f $UPDATES_CONF ]]; then
      printf '  %b %s\n' "${CYN}i${R}" "A restart is needed to finish installing updates. It will restart at $RESTART_TIME."
    else
      printf '  %b %s\n' "${YLW}!${R}" "A restart is needed to finish installing updates. Restart with: sudo reboot"
    fi
  fi
}

write_dnsdist() {
  title "Setting up dnsdist (answers DNS on port 53)"
  # Keep a copy of someone's own dnsdist config (not Debian's sample, which is all comments).
  if [[ -f $DNSDIST_CONF ]] && ! grep -q "^$DNSDIST_MARK" "$DNSDIST_CONF" \
     && grep -qvE '^[[:space:]]*(--.*)?$|^setSecurityPollSuffix\(""\)$' "$DNSDIST_CONF"; then
    local bak; bak="$DNSDIST_CONF.before-diginode-seeder.$(date +%Y%m%d-%H%M%S)"
    cp -p "$DNSDIST_CONF" "$bak"
    info "Saved the old dnsdist config as $bak"
  fi
  local id tmp; tmp=$(mktemp)
  {
    echo "$DNSDIST_MARK $DGNS_VERSION. It is rewritten each time the setup runs."
    echo "-- Only the seed names below are answered; everything else is refused."
    echo
    [[ -n $LOCAL_V4 ]] && echo "setLocal(\"$LOCAL_V4:53\")"
    if [[ -n $LOCAL_V6 ]]; then
      if [[ -n $LOCAL_V4 ]]; then echo "addLocal(\"[$LOCAL_V6]:53\")"; else echo "setLocal(\"[$LOCAL_V6]:53\")"; fi
    fi
    echo 'setACL({"0.0.0.0/0", "::/0"})'
    echo 'setSecurityPollSuffix("")'
    echo
    echo "-- Limit how fast one address (or IPv6 /64) can ask, so the server can't be"
    echo "-- used to flood others."
    echo 'addAction(MaxQPSIPRule(50), DropAction())'
    echo
    echo "-- The seeders only answer over UDP (their answers always fit), so questions"
    echo "-- over TCP get a clean \"refused\" instead of a dropped connection."
    echo 'addAction(TCPRule(true), RCodeAction(DNSRCode.REFUSED))'
    echo
    for id in "${ENABLED[@]}"; do
      echo "-- ${NET_LABEL[$id]}"
      echo "newServer({address=\"127.0.0.1:${NET_DNS_PORT[$id]}\", pool=\"$id\", checkName=\"${SEED_HOST[$id]}.\", checkType=\"NS\", checkInterval=10, maxCheckFailures=3})"
      echo "local names_${id//-/_} = newSuffixMatchNode()"
      echo "names_${id//-/_}:add(\"${SEED_HOST[$id]}.\")"
      echo "addAction(SuffixMatchNodeRule(names_${id//-/_}), PoolAction(\"$id\"))"
      echo
    done
    echo 'addAction(AllRule(), RCodeAction(DNSRCode.REFUSED))'
  } > "$tmp"
  if ! dnsdist --check-config -C "$tmp" >/dev/null 2>&1; then
    dnsdist --check-config -C "$tmp" || true
    rm -f "$tmp"; fail "The dnsdist config didn't pass its check."
  fi
  install -m 644 "$tmp" "$DNSDIST_CONF"; rm -f "$tmp"
  ok "dnsdist config written ($DNSDIST_CONF)"
}

open_firewall() {
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 53/udp >/dev/null && ok "Firewall (ufw): UDP port 53 opened"
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd -q --permanent --add-port=53/udp && firewall-cmd -q --reload && ok "Firewall (firewalld): UDP port 53 opened"
  fi
}

# A fingerprint of everything a service runs with, so an update only restarts
# what changed (a restarted seeder hands out fewer nodes for a minute or two).
fingerprint() { # fingerprint dnsdist|<id>
  # The "Written by DigiNode Seeder <version>" lines are left out, so a new version alone restarts nothing.
  if [[ $1 == dnsdist ]]; then
    { cat "$DNSDIST_CONF" 2>/dev/null || true; } | grep -v '^-- Written by DigiNode Seeder' | sha256sum
  else
    { cat "$UNIT_FILE" "$INSTALL_DIR/bin/run-seeder" "$CONF_DIR/$1.conf" \
          "$INSTALL_DIR/bin/${1%%-*}-seeder.commit" 2>/dev/null || true; } | grep -v '^# Written by DigiNode Seeder' | sha256sum
  fi
}
declare -A FP_BEFORE=()
remember_fingerprints() {
  local id
  # Empty = not set up by us before (a first install), so no "restarted" message.
  FP_BEFORE[dnsdist]=""
  if grep -q "^$DNSDIST_MARK" "$DNSDIST_CONF" 2>/dev/null; then FP_BEFORE[dnsdist]=$(fingerprint dnsdist); fi
  for id in "${ENABLED[@]}"; do
    FP_BEFORE[$id]=""
    if [[ -f $CONF_DIR/$id.conf ]]; then FP_BEFORE[$id]=$(fingerprint "$id"); fi
  done
}
# Start a service, or restart it if it's running with old settings.
start_or_restart() { # start_or_restart <unit> <fingerprint key>
  if ! systemctl is-active -q "$1"; then
    systemctl start "$1"
  elif [[ -z "${FP_BEFORE[$2]:-}" ]]; then
    systemctl restart "$1"                      # first install: quietly
  elif [[ "${FP_BEFORE[$2]}" != "$(fingerprint "$2")" ]]; then
    systemctl restart "$1"; info "Restarted $1 (it changed)"
  fi
}

start_all() {
  title "Starting"
  systemctl enable -q dnsdist
  start_or_restart dnsdist dnsdist
  local id
  for id in "${ENABLED[@]}"; do
    systemctl enable -q "diginode-seeder@$id"
    start_or_restart "diginode-seeder@$id" "$id"
  done
  sleep 3
  systemctl is-active -q dnsdist || { journalctl -u dnsdist -n 20 --no-pager; fail "dnsdist didn't start."; }
  ok "dnsdist is running"
  for id in "${ENABLED[@]}"; do
    systemctl is-active -q "diginode-seeder@$id" || { journalctl -u "diginode-seeder@$id" -n 20 --no-pager; fail "The ${NET_LABEL[$id]} seeder didn't start."; }
    ok "${NET_LABEL[$id]} seeder is running"
  done
}

# Ask this server for each seed name until it hands out nodes.
test_local() {
  title "Waiting for the seeders to find nodes (up to 3 minutes)"
  local id n addr="${LOCAL_V4:-$LOCAL_V6}" waited=0
  for id in "${ENABLED[@]}"; do
    n=0
    # Wait for a useful number of nodes (10), or until 3 minutes have passed in all.
    while :; do
      n=$(dig +short +time=2 +tries=1 @"$addr" "${SEED_HOST[$id]}" A 2>/dev/null | grep -c '^[0-9]' || true)
      (( n >= 10 || waited >= 180 )) && break
      [[ -t 1 ]] && printf '\r%s[…]%s %s: %s nodes so far  %s%dm %02ds%s ' "$CYN" "$R" "${SEED_HOST[$id]}" "$n" "$DIM" $((waited / 60)) $((waited % 60)) "$R"
      sleep 5; waited=$((waited + 5))
    done
    [[ -t 1 ]] && printf '\r\e[K'
    if (( n == 1 )); then ok "${SEED_HOST[$id]}: 1 node so far"
    elif (( n > 1 )); then ok "${SEED_HOST[$id]}: $n nodes so far"
    else warn "${SEED_HOST[$id]}: no nodes yet. It can take a few minutes; check later with: $(cmd_hint)"; fi
  done
}

# Where the seed name is handed to, asked straight from its parent zone's nameserver (so no cached answers).
# Sets DELEG_NS (nameserver names) and DELEG_IPS (their addresses).
find_delegation() { # find_delegation <name>
  local name="$1" parent="${1#*.}" pns="" resp n
  DELEG_NS=""; DELEG_IPS=""
  while [[ $parent == *.* ]]; do
    pns=$(dig +short +time=3 +tries=1 @1.1.1.1 "$parent" NS 2>/dev/null | head -1)
    [[ -n $pns ]] && break
    parent="${parent#*.}"
  done
  [[ -n $pns ]] || return 0
  resp=$(dig +norec +time=3 +tries=2 @"$pns" "$name" NS 2>/dev/null || true)
  DELEG_NS=$(awk -v n="${name,,}." 'tolower($1)==n && $4=="NS" {print tolower($5)}' <<<"$resp" | sed 's/\.$//' | sort -u)
  DELEG_IPS=$(awk '$4=="A" || $4=="AAAA" {print tolower($5)}' <<<"$resp" | sort -u)
  if [[ -n $DELEG_NS && -z $DELEG_IPS ]]; then       # no glue: look the nameservers up
    for n in $DELEG_NS; do
      DELEG_IPS+=$'\n'$(dig +short +time=3 +tries=1 @1.1.1.1 "$n" A "$n" AAAA 2>/dev/null | grep -E '^[0-9a-f:.]+$' || true)
    done
  fi
}

points_here() { # does this list of addresses include this server?
  [[ -n $PUBLIC_V4 ]] && grep -qxF "$PUBLIC_V4" <<<"$1" && return 0
  [[ -n $LOCAL_V6 ]] && grep -qixF "$LOCAL_V6" <<<"$1" && return 0
  return 1
}

# Check each seed name's DNS records and, if something is wrong, say what. Returns 0 if all are right.
# "quiet": only the result (used before showing the records).
check_dns() { # check_dns [quiet]
  local id n all=0 quiet="${1:-}" name
  for id in "${ENABLED[@]}"; do
    name="${SEED_HOST[$id]}"
    find_delegation "$name"
    if [[ -z $DELEG_NS ]]; then
      all=1
      [[ -n $quiet ]] && continue
      printf '  %b %s\n' "${YLW}!${R}" "$name"
      n=$(dig +short +time=3 +tries=1 @1.1.1.1 "$name" A 2>/dev/null | grep -c '^[0-9]' || true)
      if (( n > 0 )); then say "      It has an A (or CNAME) record. Delete it, and add:  $name  NS  $NS_HOST"
      else say "      No NS record yet. Add:  $name  NS  $NS_HOST"; fi
      continue
    fi
    if ! points_here "$DELEG_IPS"; then
      all=1
      [[ -n $quiet ]] && continue
      printf '  %b %s\n' "${YLW}!${R}" "$name"
      if [[ -z $(tr -d '[:space:]' <<<"$DELEG_IPS") ]]; then
        say "      It's handed to $(tr '\n' ' ' <<<"$DELEG_NS")but that name has no address. Add:  $NS_HOST  A  $PUBLIC_V4"
      elif grep -qE '^(104\.(1[6-9]|2[0-9]|3[01])\.|172\.(6[4-9]|7[01])\.|2606:4700:)' <<<"$DELEG_IPS"; then
        say "      $(head -1 <<<"$DELEG_NS") is proxied by Cloudflare. Set its records to DNS only (grey cloud)."
      else
        say "      It's handed to $(tr '\n' ' ' <<<"$DELEG_NS")at $(tr '\n' ' ' <<<"$DELEG_IPS" | xargs), not this server ($PUBLIC_V4${LOCAL_V6:+, $LOCAL_V6})."
        if grep -qxF "$NS_HOST" <<<"$DELEG_NS"; then
          say "      Change the $NS_HOST records to this server's address (see below)."
        else
          say "      Either change its NS record to $NS_HOST, or point $(head -1 <<<"$DELEG_NS") at this server."
        fi
      fi
      continue
    fi
    # The records are right. Does an answer arrive through public DNS?
    n=$(dig +short +time=3 +tries=1 @1.1.1.1 "$name" A 2>/dev/null | grep -c '^[0-9]' || true)
    if (( n > 0 )); then
      [[ -n $quiet ]] || printf '  %b %s  %s nodes\n' "${GRN}✓${R}" "$name" "$n"
    else
      all=1
      [[ -n $quiet ]] && continue
      printf '  %b %s\n' "${YLW}!${R}" "$name"
      say "      The records are right, but no answer arrives through public DNS yet. Public DNS can"
      say "      remember the old answer for up to 30 minutes. If it still fails after that, check that"
      say "      UDP port 53 is open in your server provider's firewall."
    fi
  done
  return $all
}

show_dns_records() {
  title "Add these DNS records"
  say "At the DNS provider for your domain:"
  say ""
  [[ -n $PUBLIC_V4 ]] && printf '  %-34s %-5s %s\n' "$NS_HOST" "A" "$PUBLIC_V4"
  [[ -n $LOCAL_V6 ]] && printf '  %-34s %-5s %s\n' "$NS_HOST" "AAAA" "$LOCAL_V6"
  local id
  for id in "${ENABLED[@]}"; do
    printf '  %-34s %-5s %s\n' "${SEED_HOST[$id]}" "NS" "$NS_HOST"
  done
  say ""
  say "  - On Cloudflare, set the $NS_HOST records to ${B}DNS only${R} (grey cloud), not proxied."
  say "  - Delete any other record (A, CNAME...) for the seed names, or the NS records won't work."
  say "  - Your server provider's firewall must allow ${B}UDP port 53${R} in."
  say ""
  say "Help with DNS records: ${GUIDE_URL}#dns-records"
}

# After showing the records: wait while they're added, then check them (and again, until they work or the user stops).
wait_for_dns() {
  [[ $ASSUME_YES -eq 0 ]] && has_tty || return 1
  local a
  while :; do
    say ""
    printf '%s ' "Press ${B}Enter${R} once you've added them, to check them (or type ${B}q${R} to check later):" > "$TTY"
    IFS= read -r a < "$TTY" || a=q
    [[ $a =~ ^[Qq] ]] && return 1
    title "Checking your DNS records"
    check_dns && return 0
    say ""
    say "DNS changes can take a few minutes. Try again, or check later with: $(cmd_hint --dns)"
  done
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
do_setup() {
  say ""
  show_logo
  say ""
  say "  ${B}DigiNode Seeder $DGNS_VERSION${R}: sets up DNS seeders, which help new nodes find the network."
  say ""
  check_system
  detect_addresses
  check_port53
  if [[ $CLI_SET -eq 0 ]] && load_settings; then
    info "Found an existing setup."
  fi
  if [[ ${#ENABLED[@]} -eq 0 || $RECONFIGURE -eq 1 ]]; then
    [[ $CLI_SET -eq 1 ]] || ask_settings
  fi
  apply_cli_choices
  # Set up before these choices existed: ask once (or turn them on, with --yes).
  if [[ -z $MOTD ]]; then
    if [[ $ASSUME_YES -eq 0 ]] && has_tty; then ask_motd; else MOTD=yes; fi
  fi
  if [[ -z $AUTO_UPDATES ]]; then
    if [[ $ASSUME_YES -eq 0 ]] && has_tty; then ask_updates; else AUTO_UPDATES=yes; AUTO_RESTART=${AUTO_RESTART:-yes}; fi
  fi
  [[ ${#ENABLED[@]} -gt 0 && -n $NS_HOST && -n $SOA_EMAIL ]] || fail "Settings are incomplete."
  show_summary
  confirm "Go ahead?" y || exit 0
  remember_fingerprints
  ensure_swap
  install_packages
  build_seeders
  install_service
  install_command
  apply_motd
  apply_updates
  save_settings
  write_dnsdist
  open_firewall
  start_all
  test_local
  local dns_ok=0
  if check_dns quiet; then
    title "Your DNS records"
    check_dns || true
    dns_ok=1
  else
    show_dns_records
    wait_for_dns && dns_ok=1
  fi
  title "All done. What's next"
  if [[ $dns_ok -eq 0 ]]; then
    say "  - Add the DNS records above, then check them:   ${B}$(cmd_hint --dns)${R}"
  fi
  say "  - See how it's doing, now and then:              ${B}$(cmd_hint)${R}"
  say "  - Update it (keeps your settings):               ${B}$(cmd_hint --update)${R}"
  say "  - After a couple of weeks, ask for your seed to be added to ${CHAIN_CORE_NAME[${ENABLED[0]%%-*}]},"
  say "    so nodes start using it. ${B}$(cmd_hint)${R} shows the line to add, and the guide shows how:"
  say "    ${GUIDE_URL}#add-to-digibyte-core"
  [[ -x $CMD_LINK ]] && say "  - All commands:   ${B}diginode-seeder --help${R}"
  return 0
}

do_status() {
  load_settings || fail "DigiNode Seeder isn't set up on this server."
  detect_addresses
  title "DigiNode Seeder status"
  local id state n mark chain w=10
  for id in "${ENABLED[@]}"; do (( ${#SEED_HOST[$id]} > w )) && w=${#SEED_HOST[$id]}; done
  state=$(systemctl is-active dnsdist || true)
  mark="${GRN}✓${R}"; [[ $state == active ]] || mark="${RED}✗${R}"
  printf '  %b %-18s %s\n' "$mark" "dnsdist" "$state (answers DNS on port 53)"
  for id in "${ENABLED[@]}"; do
    state=$(systemctl is-active "diginode-seeder@$id" || true)
    n=$(dig +short +time=2 +tries=1 @"${LOCAL_V4:-$LOCAL_V6}" "${SEED_HOST[$id]}" A 2>/dev/null | grep -c '^[0-9]' || true)
    mark="${GRN}✓${R}"; [[ $state == active && $n -gt 0 ]] || mark="${RED}✗${R}"
    printf '  %b %-18s %-8s %-*s  %s nodes\n' "$mark" "${NET_SHORT[$id]}" "$state" "$w" "${SEED_HOST[$id]}" "$n"
  done
  for chain in "${CHAINS[@]}"; do
    [[ -f $INSTALL_DIR/bin/$chain-seeder.commit ]] || continue
    local repo="${CHAIN_REPO[$chain]#https://github.com/}"
    printf '    %s%s seeder build %s (%s)%s\n' "$DIM" "${CHAIN_NAME[$chain]}" \
      "$(cat "$INSTALL_DIR/bin/$chain-seeder.commit")" "${repo%.git}" "$R"
  done
  title "From the internet (DNS records and public DNS)"
  local dns_ok=0
  check_dns && dns_ok=1
  title "System"
  updates_status
  show_core_status "$dns_ok"
  say ""
  say "${DIM}Logs: journalctl -u diginode-seeder@${ENABLED[0]}    Commands: diginode-seeder --help${R}"
}

# Is each seed in the node software's seed list yet? If not, show the line to add, and when.
show_core_status() { # show_core_status <dns_ok 0|1>
  local dns_ok="$1" chain id src days=0 since="" missing=()
  chain="${ENABLED[0]%%-*}"
  title "${CHAIN_CORE_NAME[$chain]}"
  src=$(curl -fsS -m 10 "${CHAIN_CORE_RAW[$chain]}" 2>/dev/null || true)
  for id in "${ENABLED[@]}"; do
    if [[ -n $src ]] && grep -qF "\"${SEED_HOST[$id]}\"" <<<"$src"; then
      printf '  %b %s is in %s (develop branch)\n' "${GRN}✓${R}" "${SEED_HOST[$id]}" "${CHAIN_CORE_NAME[$chain]}"
    else
      missing+=("$id")
    fi
  done
  [[ ${#missing[@]} -gt 0 ]] || return 0
  if [[ -n $SETUP_DATE ]]; then
    days=$(( ( $(date -u +%s) - $(date -u -d "$SETUP_DATE" +%s) ) / 86400 ))
    since=$(date -u -d "$SETUP_DATE" '+%-d %B %Y')
  fi
  if [[ $dns_ok -eq 0 ]]; then
    say "  Not listed yet. Once your DNS records work and it has run reliably for a couple of"
    say "  weeks, ask for it to be added, so nodes start using it."
  elif (( days >= 14 )); then
    say "  Not listed yet. It has run since $since ($days days): time to ask for it to be added,"
    say "  so nodes start using it."
  else
    say "  Not listed yet. Set up on $since. Once it has run reliably for a couple of weeks"
    say "  (from $(date -u -d "$SETUP_DATE + 14 days" '+%-d %B %Y')), ask for it to be added, so nodes start using it."
  fi
  say ""
  say "  The line to add to ${CHAIN_CORE_FILE[$chain]}, at the end of the right list:"
  for id in "${missing[@]}"; do
    printf '    %s%-13s%s vSeeds.emplace_back("%s"); // Your Name @your-github-handle\n' "$DIM" "${NET_CORE_LIST[$id]}:" "$R" "${SEED_HOST[$id]}"
  done
  say "  How, on GitHub's website or in a terminal:  ${GUIDE_URL}#add-to-digibyte-core"
  say "  Or let an AI agent do it for you. Get a ready-made prompt with:  ${B}diginode-seeder --ai-prompt${R}"
}

# A ready-to-paste prompt for an AI agent that makes the pull request, filled in with this server's details.
do_ai_prompt() {
  load_settings || fail "DigiNode Seeder isn't set up on this server."
  detect_addresses >/dev/null
  local chain id name handle src n since lines="" checks="" listed=() todo=()
  chain="${ENABLED[0]%%-*}"
  src=$(curl -fsS -m 10 "${CHAIN_CORE_RAW[$chain]}" 2>/dev/null || true)
  for id in "${ENABLED[@]}"; do
    if [[ -n $src ]] && grep -qF "\"${SEED_HOST[$id]}\"" <<<"$src"; then listed+=("${SEED_HOST[$id]}"); else todo+=("$id"); fi
  done
  for name in "${listed[@]}"; do ok "$name is already in ${CHAIN_CORE_NAME[$chain]}."; done
  [[ ${#todo[@]} -gt 0 ]] || return 0

  title "A prompt for an AI agent"
  say "An AI agent that can run commands and use GitHub (for example Claude Code, with the"
  say "GitHub CLI 'gh' signed in) can make the pull request for you. It checks your seeder,"
  say "prepares everything, and shows it to you before anything is published."
  say ""
  name="Your Name"; handle="your-github-handle"
  if [[ $ASSUME_YES -eq 0 ]] && has_tty; then
    say "Your name and GitHub handle go in the line you add, so the developers can reach you."
    ask "Your name, as it should appear" ""; [[ -n $REPLY ]] && name="$REPLY"
    ask "Your GitHub handle (without @)" ""; [[ -n $REPLY ]] && handle="${REPLY#@}"
  fi
  since=$(date -u -d "${SETUP_DATE:-today}" '+%-d %B %Y')
  for id in "${todo[@]}"; do
    n=$(dig +short +time=2 +tries=1 @"${LOCAL_V4:-$LOCAL_V6}" "${SEED_HOST[$id]}" A 2>/dev/null | grep -c '^[0-9]' || true)
    lines+="- ${NET_LABEL[$id]} seed: ${SEED_HOST[$id]}  (goes in the ${NET_CORE_LIST[$id]}; it currently returns about $n nodes)"$'\n'
    checks+="   At the end of the ${NET_CORE_LIST[$id]}:"$'\n'"     vSeeds.emplace_back(\"${SEED_HOST[$id]}\"); // $name @$handle"$'\n'
  done

  say ""
  say "Copy everything between the lines and paste it into your AI agent:"
  say "${DIM}------------------------------------------------------------------------------${R}"
  cat <<EOF
I run a ${CHAIN_NAME[$chain]} DNS seeder (set up with DigiNode Seeder) and want it added to
${CHAIN_CORE_NAME[$chain]}. Please prepare a pull request for me. I'm not familiar with Git, so
explain each step briefly as you go.

My details:
${lines}- My name as it should appear: $name
- My GitHub handle: $handle
- Running since: $since

Steps:
1. Check each seed name answers from the internet: \`dig +short <name>\` and
   \`dig +short x9.<name>\` (or nslookup, on Windows) should each return several
   IP addresses. Stop and tell me if any returns nothing.
2. Check I'm signed in to GitHub with \`gh auth status\`. If not, help me sign in
   (\`gh auth login\`), or install the GitHub CLI first if it's missing.
3. Fork DigiByte-Core/digibyte with \`gh\` (if I don't already have a fork) and
   create a branch from the latest \`develop\` branch.
4. In ${CHAIN_CORE_FILE[$chain]}, add these lines, each at the end of its list
   (mainnet: under "// DigiByte MAINNET DNS Seed Server:", testnet: under
   "// DigiByte TESTNET DNS Seed Servers:"), copying the format of the lines
   above exactly:
${checks}   Change nothing else in the file.
5. Commit with a message like "net: Add <seed name> DNS seed". The commit
   message must not contain any @ mentions (DigiByte's contribution rules).
6. Show me the diff, the PR title and the PR description, and wait for my OK.
   The title starts with "net:". The description says which seed(s) it adds,
   who runs them, since when, and that they answer plain and x9. queries
   (with the number of addresses each returned).
7. Only after I say yes: push the branch and open the pull request against
   DigiByte-Core/digibyte, base branch \`develop\`. Give me the link, and tell
   me how to follow the reviewers' comments.
EOF
  say "${DIM}------------------------------------------------------------------------------${R}"
  say "More about this step: ${GUIDE_URL}#add-to-digibyte-core"
}

do_dns() {
  load_settings || fail "DigiNode Seeder isn't set up on this server."
  detect_addresses >/dev/null
  title "Checking your DNS records"
  if check_dns; then say ""; ok "All your seed names work."; return 0; fi
  show_dns_records
}

# Download the latest release and run it: it updates the command, the seeder and the settings files,
# and only restarts what changed.
do_update() {
  need_root
  load_settings || fail "DigiNode Seeder isn't set up on this server. Set it up with: curl -sSL https://seedsetup.diginode.tools | sudo bash"
  local tmp newver; tmp=$(mktemp /tmp/diginode-seeder.XXXXXX)
  spin "Checking for a new version of DigiNode Seeder" curl -fsSL -m 60 "$RELEASES_URL/latest/download/diginode-seeder.sh" -o "$tmp" \
    || fail "Couldn't download DigiNode Seeder from GitHub."
  newver=$(sed -n 's/^DGNS_VERSION="\(.*\)"$/\1/p' "$tmp" | head -1)
  [[ -n $newver ]] || fail "The download doesn't look like DigiNode Seeder."
  if [[ $newver == "$DGNS_VERSION" ]]; then
    ok "DigiNode Seeder $DGNS_VERSION is the latest version. Checking the seeders for updates."
  elif [[ $(printf '%s\n%s\n' "$newver" "$DGNS_VERSION" | sort -V | tail -1) == "$DGNS_VERSION" ]]; then
    rm -f "$tmp"
    warn "You have DigiNode Seeder $DGNS_VERSION, newer than the latest release ($newver). Nothing changed."
    say "To update the seeders with this version, run: diginode-seeder --yes"
    return 0
  else
    ok "New version: DigiNode Seeder $newver (you have $DGNS_VERSION)."
  fi
  exec bash "$tmp" --yes
}

do_uninstall() {
  need_root
  load_settings || fail "DigiNode Seeder isn't set up on this server."
  confirm "Stop and remove all seeders? Their crawl data in $STATE_BASE is kept." n || exit 0
  local id
  for id in "${ENABLED[@]}"; do systemctl disable --now "diginode-seeder@$id" >/dev/null 2>&1 || true; done
  rm -f "$UNIT_FILE"; systemctl daemon-reload
  if grep -q "^$DNSDIST_MARK" "$DNSDIST_CONF" 2>/dev/null; then
    systemctl disable --now dnsdist >/dev/null 2>&1 || true
    mv "$DNSDIST_CONF" "$DNSDIST_CONF.diginode-seeder.off"
  fi
  for f in "$CONF_DIR"/*.conf; do [[ -e $f ]] && mv "$f" "$f.off"; done
  [[ -L $CMD_LINK ]] && rm -f "$CMD_LINK"
  remove_motd
  ok "Seeders stopped and removed. Settings kept in $CONF_DIR, data in $STATE_BASE."
  say "To set it up again: curl -sSL https://seedsetup.diginode.tools | sudo bash"
  say "Remember to remove the seed names' NS records at your DNS provider."
}

usage() {
  cat <<EOF
DigiNode Seeder $DGNS_VERSION - run DNS seeders for DigiByte on your own server.

Usage: diginode-seeder [option]

  (no option)          Show how the seeders are doing, and how to get them into DigiByte Core
  --dns                Check your DNS records, and explain anything that's wrong
  --ai-prompt          A ready-made prompt for an AI agent to add your seed to DigiByte Core
  --motd on|off         Show (or stop showing) the DigiNode Seeder message when you log in
  --auto-updates on|off Install security updates automatically (on by default)
  --auto-restart on|off Restart at 03:30 when an update needs it (on by default)
  --update             Update DigiNode Seeder and the seeders (keeps your settings)
  --reconfigure        Change the seed names, nameserver, email or which seeders run
  --uninstall          Stop and remove the seeders (keeps their data)
  --version            Show the version
  --help               Show this text

Set up without questions (e.g. for automation):
  --mainnet <name>     Seed name for DigiByte mainnet (e.g. seed.example.com)
  --testnet <name>     Seed name for DigiByte testnet (e.g. testnetseed.example.com)
  --ns <name>          Nameserver name for this server (e.g. dnsseed.example.com)
  --email <address>    Contact email for the seeds' DNS records
  --yes                Don't ask; accept the defaults

Updating, changing and removing need administrator rights: if you aren't root, it asks
for your password (sudo).

First install:  curl -sSL https://seedsetup.diginode.tools | sudo bash
Guide:          $GUIDE_URL
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
on_off() { # on_off <option> <value> -> ONOFF=yes|no
  case "$2" in
    on|yes) ONOFF=yes ;; off|no) ONOFF=no ;;
    *) fail "Use $1 on or $1 off." ;;
  esac
}

# Choices given as options win over saved ones. Turning automatic updates off also turns restarts off.
apply_cli_choices() {
  [[ -n $CLI_MOTD ]] && MOTD="$CLI_MOTD"
  # Turning updates back on brings back automatic restarts too (the default), unless --auto-restart says otherwise.
  if [[ $CLI_UPDATES == yes && $AUTO_UPDATES == no && -z $CLI_RESTART ]]; then AUTO_RESTART=yes; fi
  [[ -n $CLI_UPDATES ]] && AUTO_UPDATES="$CLI_UPDATES"
  [[ -n $CLI_RESTART ]] && AUTO_RESTART="$CLI_RESTART"
  if [[ $AUTO_RESTART == yes && $AUTO_UPDATES == no ]]; then AUTO_RESTART=no; fi
  if [[ $AUTO_UPDATES == yes && -z $AUTO_RESTART ]]; then AUTO_RESTART=yes; fi
  return 0
}

main() {
  # Run as the installed diginode-seeder command: no option = status. Run from curl (or a file): no option = set up.
  AS_COMMAND=0; [[ $(basename "$0") == diginode-seeder ]] && AS_COMMAND=1
  ORIG_ARGS=("$@")
  local cmd=setup
  [[ $AS_COMMAND -eq 1 && $# -eq 0 ]] && cmd=status
  RECONFIGURE=0; CLI_SET=0
  declare -gA SEED_HOST=()
  ENABLED=(); NS_HOST=""; SOA_EMAIL=""; SETUP_DATE=""; MOTD=""; CLI_MOTD=""
  AUTO_UPDATES=""; AUTO_RESTART=""; CLI_UPDATES=""; CLI_RESTART=""
  local cli_main="" cli_test="" cli_ns="" cli_email=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) cmd=status ;;
      --dns) cmd=dns ;;
      --ai-prompt) cmd=aiprompt ;;
      --update) cmd=update ;;
      --version|-v) echo "DigiNode Seeder $DGNS_VERSION"; exit 0 ;;
      --uninstall) cmd=uninstall ;;
      --reconfigure) RECONFIGURE=1 ;;
      --mainnet) cli_main="${2:-}"; shift ;;
      --testnet) cli_test="${2:-}"; shift ;;
      --ns) cli_ns="${2:-}"; shift ;;
      --email) cli_email="${2:-}"; shift ;;
      --motd) on_off "$1" "${2:-}"; CLI_MOTD=$ONOFF; shift ;;
      --auto-updates) on_off "$1" "${2:-}"; CLI_UPDATES=$ONOFF; shift ;;
      --auto-restart) on_off "$1" "${2:-}"; CLI_RESTART=$ONOFF; shift ;;
      --yes|-y) ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) usage; fail "Unknown option: $1" ;;
    esac
    shift
  done
  case "$cmd" in
    status) do_status; return ;;
    dns) do_dns; return ;;
    aiprompt) do_ai_prompt; return ;;
    update) do_update; return ;;
    uninstall) do_uninstall; return ;;
  esac
  # Just --motd / --auto-updates / --auto-restart, on a server that's set up: change only those.
  if [[ -n $CLI_MOTD$CLI_UPDATES$CLI_RESTART && -z $cli_main$cli_test && $RECONFIGURE -eq 0 && -r $CONF_DIR/settings ]]; then
    need_root
    load_settings
    apply_cli_choices
    write_settings_file
    if [[ -n $CLI_MOTD ]]; then apply_motd; fi
    if [[ -n $CLI_UPDATES$CLI_RESTART ]]; then apply_updates; fi
    return
  fi
  if [[ -n $cli_main$cli_test ]]; then
    [[ -n $cli_ns && -n $cli_email ]] || fail "--ns and --email are needed with --mainnet/--testnet."
    ENABLED=()
    if [[ -n $cli_main ]]; then valid_hostname "$cli_main" || fail "Invalid --mainnet name."; ENABLED+=(digibyte-mainnet); SEED_HOST[digibyte-mainnet]="${cli_main,,}"; fi
    if [[ -n $cli_test ]]; then valid_hostname "$cli_test" || fail "Invalid --testnet name."; ENABLED+=(digibyte-testnet); SEED_HOST[digibyte-testnet]="${cli_test,,}"; fi
    valid_hostname "$cli_ns" || fail "Invalid --ns name."
    email_to_mbox "$cli_email" >/dev/null || fail "Invalid --email (no dot allowed before the @)."
    NS_HOST="${cli_ns,,}"; SOA_EMAIL="$cli_email"; CLI_SET=1
    apply_cli_choices
    keep_saved_extras
  fi
  do_setup
}

main "$@"

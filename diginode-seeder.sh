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

DGNS_VERSION="0.1.0"

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

# Questions read from the terminal, so the script also works with curl | bash.
TTY="/dev/tty"
ASSUME_YES=0
ask() { # ask "Question" "default" -> REPLY
  local q="$1" def="${2:-}"
  if [[ $ASSUME_YES -eq 1 ]]; then REPLY="$def"; return; fi
  [[ -r $TTY ]] || fail "No terminal to ask questions on. Use the command-line options (see --help)."
  if [[ -n $def ]]; then printf '%s %s[%s]%s: ' "$q" "$DIM" "$def" "$R" > "$TTY"
  else printf '%s: ' "$q" > "$TTY"; fi
  IFS= read -r REPLY < "$TTY" || true
  REPLY="${REPLY:-$def}"
}
confirm() { # confirm "Question" [default y|n]
  local def="${2:-y}" hint="[Y/n]"
  [[ $def == n ]] && hint="[y/N]"
  if [[ $ASSUME_YES -eq 1 ]]; then [[ $def == y ]]; return; fi
  [[ -r $TTY ]] || fail "No terminal to ask questions on. Use --yes to accept the defaults."
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

check_system() {
  [[ $EUID -eq 0 ]] || fail "Please run as root, for example: curl -sSL https://seedsetup.diginode.tools | sudo bash"
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
  NS_HOST=""; SOA_EMAIL=""; ENABLED=()
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

save_settings() {
  install -d -m 755 "$CONF_DIR"
  cat > "$CONF_DIR/settings" <<EOF
# DigiNode Seeder settings. Run the setup again to change them.
NS_HOST="$NS_HOST"
SOA_EMAIL="$SOA_EMAIL"
EOF
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
}

show_summary() {
  title "Summary"
  local id
  for id in "${ENABLED[@]}"; do
    printf '  %-36s %s  %s(nodes on port %s)%s\n' "${NET_LABEL[$id]}" "${SEED_HOST[$id]}" "$DIM" "${NET_P2P_PORT[$id]}" "$R"
  done
  printf '  %-36s %s\n' "Nameserver (this server)" "$NS_HOST"
  printf '  %-36s %s\n' "Contact email" "$SOA_EMAIL"
  printf '  %-36s %s\n' "Server address" "${PUBLIC_V4:-none}${LOCAL_V6:+, $LOCAL_V6}"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
install_packages() {
  title "Installing packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq build-essential libssl-dev libboost-dev git dnsdist dnsutils curl ca-certificates >/dev/null
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
      git -C "$src" fetch -q origin "${CHAIN_BRANCH[$chain]}"
      git -C "$src" reset -q --hard "origin/${CHAIN_BRANCH[$chain]}"
    else
      git clone -q --branch "${CHAIN_BRANCH[$chain]}" "${CHAIN_REPO[$chain]}" "$src"
    fi
    commit=$(git -C "$src" rev-parse --short HEAD)
    make -C "$src" -s clean >/dev/null 2>&1 || true
    local jobs; jobs=$(nproc); (( MEM_MB < 1500 )) && jobs=1
    make -C "$src" -s -j"$jobs" >/dev/null 2>&1 || { make -C "$src" 2>&1 | tail -20; fail "The build failed."; }
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
  if [[ $1 == dnsdist ]]; then
    { cat "$DNSDIST_CONF" 2>/dev/null || true; } | sha256sum
  else
    { cat "$UNIT_FILE" "$INSTALL_DIR/bin/run-seeder" "$CONF_DIR/$1.conf" \
          "$INSTALL_DIR/bin/${1%%-*}-seeder" 2>/dev/null || true; } | sha256sum
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
      sleep 10; waited=$((waited + 10))
    done
    if (( n == 1 )); then ok "${SEED_HOST[$id]}: 1 node so far"
    elif (( n > 1 )); then ok "${SEED_HOST[$id]}: $n nodes so far"
    else warn "${SEED_HOST[$id]}: no nodes yet. It can take a few minutes; check later with: $0 --status"; fi
  done
}

# Is the seed name reachable from the internet yet?
test_public() {
  local id n all=0
  for id in "${ENABLED[@]}"; do
    n=$(dig +short +time=3 +tries=1 @1.1.1.1 "${SEED_HOST[$id]}" A 2>/dev/null | grep -c '^[0-9]' || true)
    if (( n > 0 )); then ok "${SEED_HOST[$id]} works from the internet ($n nodes via 1.1.1.1)"; else all=1; fi
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
  say "Then check with:  dig ${SEED_HOST[${ENABLED[0]}]}"
  say "Help with DNS records: https://diginode.tools/diginode-seeder/#dns-records"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
do_setup() {
  title "DigiNode Seeder $DGNS_VERSION"
  say "Sets up DNS seeders, which help new nodes find the network."
  check_system
  detect_addresses
  check_port53
  if [[ $CLI_SET -eq 0 ]] && load_settings; then
    info "Found an existing setup."
  fi
  if [[ ${#ENABLED[@]} -eq 0 || $RECONFIGURE -eq 1 ]]; then
    [[ $CLI_SET -eq 1 ]] || ask_settings
  fi
  [[ ${#ENABLED[@]} -gt 0 && -n $NS_HOST && -n $SOA_EMAIL ]] || fail "Settings are incomplete."
  show_summary
  confirm "Go ahead?" y || exit 0
  remember_fingerprints
  ensure_swap
  install_packages
  build_seeders
  install_service
  save_settings
  write_dnsdist
  open_firewall
  start_all
  test_local
  if test_public; then
    title "All done"
  else
    show_dns_records
  fi
  say ""
  say "${B}Last step:${R} once it has run reliably for a couple of weeks, ask for it to be"
  say "added to DigiByte Core, so nodes start using it:"
  say "https://diginode.tools/diginode-seeder/#add-to-digibyte-core"
  say ""
  say "Status:  curl -sSL https://seedsetup.diginode.tools | sudo bash -s -- --status"
  say "Update:  run the setup command again."
}

do_status() {
  load_settings || fail "DigiNode Seeder isn't set up on this server."
  detect_addresses
  title "DigiNode Seeder status"
  local id state commit n line
  printf '  %-36s %s\n' "dnsdist" "$(systemctl is-active dnsdist)"
  for id in "${ENABLED[@]}"; do
    state=$(systemctl is-active "diginode-seeder@$id" || true)
    commit=$(cat "$INSTALL_DIR/bin/${id%%-*}-seeder.commit" 2>/dev/null || echo "?")
    n=$(dig +short +time=2 +tries=1 @"${LOCAL_V4:-$LOCAL_V6}" "${SEED_HOST[$id]}" A 2>/dev/null | grep -c '^[0-9]' || true)
    printf '  %-36s %s, build %s, %s nodes\n' "${NET_LABEL[$id]} (${SEED_HOST[$id]})" "$state" "$commit" "$n"
    line=$(journalctl -u "diginode-seeder@$id" -n 50 --no-pager -o cat 2>/dev/null | grep 'available' | tail -1 || true)
    [[ -n $line ]] && printf '  %sLast report (every 10 minutes): %s%s\n' "$DIM" "$line" "$R"
  done
  title "From the internet"
  test_public || warn "Not reachable through public DNS yet (or the DNS records are missing)."
}

do_uninstall() {
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
  ok "Seeders stopped and removed. Settings kept in $CONF_DIR, data in $STATE_BASE."
  say "Remember to remove the seed names' NS records at your DNS provider."
}

usage() {
  cat <<EOF
DigiNode Seeder $DGNS_VERSION - run DNS seeders for DigiByte.

  curl -sSL https://seedsetup.diginode.tools | sudo bash                 set up or update
  curl -sSL https://seedsetup.diginode.tools | sudo bash -s -- --status   check status

Options:
  --status              Show whether the seeders are running and answering
  --reconfigure         Ask the setup questions again
  --uninstall           Stop and remove the seeders (keeps their data)
  --mainnet <name>      Seed name for DigiByte mainnet (e.g. seed.example.com)
  --testnet <name>      Seed name for DigiByte testnet (e.g. testnetseed.example.com)
  --ns <name>           Nameserver name for this server (e.g. dnsseed.example.com)
  --email <address>     Contact email for the seeds' DNS records
  --yes                 Don't ask; accept the defaults
  --help                Show this text
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local cmd=setup
  RECONFIGURE=0; CLI_SET=0
  declare -gA SEED_HOST=()
  ENABLED=(); NS_HOST=""; SOA_EMAIL=""
  local cli_main="" cli_test="" cli_ns="" cli_email=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) cmd=status ;;
      --uninstall) cmd=uninstall ;;
      --reconfigure) RECONFIGURE=1 ;;
      --mainnet) cli_main="${2:-}"; shift ;;
      --testnet) cli_test="${2:-}"; shift ;;
      --ns) cli_ns="${2:-}"; shift ;;
      --email) cli_email="${2:-}"; shift ;;
      --yes|-y) ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) usage; fail "Unknown option: $1" ;;
    esac
    shift
  done
  case "$cmd" in
    status) do_status; return ;;
    uninstall) do_uninstall; return ;;
  esac
  if [[ -n $cli_main$cli_test ]]; then
    [[ -n $cli_ns && -n $cli_email ]] || fail "--ns and --email are needed with --mainnet/--testnet."
    ENABLED=()
    if [[ -n $cli_main ]]; then valid_hostname "$cli_main" || fail "Invalid --mainnet name."; ENABLED+=(digibyte-mainnet); SEED_HOST[digibyte-mainnet]="${cli_main,,}"; fi
    if [[ -n $cli_test ]]; then valid_hostname "$cli_test" || fail "Invalid --testnet name."; ENABLED+=(digibyte-testnet); SEED_HOST[digibyte-testnet]="${cli_test,,}"; fi
    valid_hostname "$cli_ns" || fail "Invalid --ns name."
    email_to_mbox "$cli_email" >/dev/null || fail "Invalid --email (no dot allowed before the @)."
    NS_HOST="${cli_ns,,}"; SOA_EMAIL="$cli_email"; CLI_SET=1
  fi
  do_setup
}

main "$@"

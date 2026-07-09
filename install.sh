#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${TUIC_REPO:-tuic-protocol/tuic}"
FALLBACK_VERSION="tuic-server-1.0.0"
INSTALL_DIR="/opt/tuic"
CONFIG_DIR="/etc/tuic"
BIN_PATH="/usr/local/bin/tuic-server"
SERVICE_NAME="tuic"
PORT=""
UUID_VALUE=""
PASSWORD_VALUE=""
SNI_VALUE="www.bing.com"
CONGESTION_CONTROL="bbr"
VERSION_VALUE="${TUIC_VERSION:-latest}"
OPEN_FIREWALL=1

usage() {
  cat <<'USAGE'
TUIC VPS one-click installer

Usage:
  bash install.sh --port <1-65535> [options]
  bash install.sh --print
  bash install.sh --uninstall

Options:
  -p, --port <port>               UDP listen port. Required for install.
  -u, --uuid <uuid>               User UUID. Default: random.
  -w, --password <password>       User password. Default: random.
  -s, --sni <name>                Certificate CN and link SNI. Default: www.bing.com.
  -c, --congestion-control <cc>   cubic, new_reno, or bbr. Default: bbr.
  -v, --version <tag>             Release tag, for example tuic-server-1.0.0. Default: latest.
      --no-firewall               Do not open the UDP port with ufw/firewalld.
      --install-dir <path>        Runtime metadata directory. Default: /opt/tuic.
      --config-dir <path>         Config and certificate directory. Default: /etc/tuic.
      --service-name <name>       systemd service name. Default: tuic.
      --print                     Print saved node links and service status.
      --uninstall                 Stop service and remove installed TUIC files.
  -h, --help                      Show help.

Examples:
  bash install.sh --port 443
  bash install.sh --port 8443 --congestion-control cubic --sni example.com
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log() {
  echo "[tuic-installer] $*"
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "please run as root, for example: sudo bash install.sh --port 443"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

safe_remove_dir() {
  local path="$1" base
  while [[ "$path" != "/" && "$path" == */ ]]; do
    path="${path%/}"
  done
  base="${path##*/}"
  [[ -n "$path" && "$path" == /* && "$path" != "/" ]] || die "refusing to remove unsafe path: $path"

  case "$base" in
    tuic|tuic-*|tuic_*)
      rm -rf -- "$path"
      ;;
    *)
      die "refusing to remove directory whose final path segment is not tuic/tuic-*/tuic_*: $path"
      ;;
  esac
}

install_dependencies() {
  local need=()
  local cmd
  for cmd in curl openssl sha256sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      need+=("$cmd")
    fi
  done

  if [[ "${#need[@]}" -eq 0 ]]; then
    return 0
  fi

  log "installing dependencies: curl openssl ca-certificates coreutils"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl openssl ca-certificates coreutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl openssl ca-certificates coreutils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl openssl ca-certificates coreutils
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install curl openssl ca-certificates coreutils
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm curl openssl ca-certificates coreutils
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl openssl ca-certificates coreutils
  else
    die "cannot install dependencies automatically; please install curl, openssl, ca-certificates, and coreutils"
  fi
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

valid_service_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.@-]+$ ]]
}

valid_sni() {
  [[ -n "$1" && "$1" != *"/"* && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

random_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
  fi
}

random_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    local raw
    raw="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s-%s-4%s-%s%s-%s\n' \
      "${raw:0:8}" "${raw:8:4}" "${raw:13:3}" \
      "$(printf '%x' $(( (0x${raw:16:1} & 0x3) | 0x8 )))" \
      "${raw:17:3}" "${raw:20:12}"
  fi
}

detect_target() {
  local arch libc target_arch target_libc

  case "$(uname -m)" in
    x86_64|amd64) target_arch="x86_64" ;;
    aarch64|arm64) target_arch="aarch64" ;;
    armv7l|armv7) target_arch="armv7" ;;
    i386|i686) target_arch="i686" ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac

  libc="gnu"
  if ldd --version 2>&1 | grep -qi musl || [[ -f /etc/alpine-release ]]; then
    libc="musl"
  fi

  case "$target_arch:$libc" in
    x86_64:gnu) target_libc="unknown-linux-gnu" ;;
    x86_64:musl) target_libc="unknown-linux-musl" ;;
    aarch64:gnu) target_libc="unknown-linux-gnu" ;;
    aarch64:musl) target_libc="unknown-linux-musl" ;;
    i686:gnu) target_libc="unknown-linux-gnu" ;;
    i686:musl) target_libc="unknown-linux-musl" ;;
    armv7:gnu) target_libc="unknown-linux-gnueabihf" ;;
    armv7:musl) target_libc="unknown-linux-musleabihf" ;;
    *) die "unsupported Linux target: ${target_arch}:${libc}" ;;
  esac

  echo "${target_arch}-${target_libc}"
}

latest_server_version() {
  local api tag
  api="https://api.github.com/repos/${REPO}/releases?per_page=30"
  tag="$(curl -fsSL "$api" \
    | grep -Eo '"tag_name"[[:space:]]*:[[:space:]]*"tuic-server-[^"]+"' \
    | sed -E 's/.*"([^"]+)".*/\1/' \
    | head -n 1 || true)"
  if [[ -n "$tag" ]]; then
    echo "$tag"
  else
    echo "$FALLBACK_VERSION"
  fi
}

download_binary() {
  local target version asset base tmp checksum
  target="$(detect_target)"
  version="$VERSION_VALUE"
  if [[ "$version" == "latest" ]]; then
    version="$(latest_server_version)"
  fi
  asset="${version}-${target}"
  base="https://github.com/${REPO}/releases/download/${version}/${asset}"
  tmp="$(mktemp -d)"

  log "downloading ${asset}"
  curl -fL --retry 3 --retry-delay 2 -o "${tmp}/${asset}" "$base"
  checksum="${tmp}/${asset}.sha256sum"
  if curl -fL --retry 3 --retry-delay 2 -o "$checksum" "${base}.sha256sum"; then
    (cd "$tmp" && sha256sum -c "$(basename "$checksum")")
  else
    log "checksum file not available, continuing without sha256 verification"
  fi

  install -m 0755 "${tmp}/${asset}" "$BIN_PATH"
  rm -rf "$tmp"
  "$BIN_PATH" --version >/dev/null
}

write_certificate() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"

  if openssl version >/dev/null 2>&1; then
    openssl req -x509 -newkey ec \
      -pkeyopt ec_paramgen_curve:prime256v1 \
      -nodes -days 36500 \
      -keyout "${CONFIG_DIR}/private.key" \
      -out "${CONFIG_DIR}/certificate.crt" \
      -subj "/CN=${SNI_VALUE}" >/dev/null 2>&1
  else
    die "openssl is required to generate the TLS certificate"
  fi

  chmod 600 "${CONFIG_DIR}/private.key"
  chmod 644 "${CONFIG_DIR}/certificate.crt"
}

write_config() {
  local password_json config_dir_json
  password_json="$(json_escape "$PASSWORD_VALUE")"
  config_dir_json="$(json_escape "$CONFIG_DIR")"

  mkdir -p "$CONFIG_DIR" "$INSTALL_DIR"
  cat >"${CONFIG_DIR}/config.json" <<EOF
{
  "server": "[::]:${PORT}",
  "users": {
    "${UUID_VALUE}": "${password_json}"
  },
  "certificate": "${config_dir_json}/certificate.crt",
  "private_key": "${config_dir_json}/private.key",
  "congestion_control": "${CONGESTION_CONTROL}",
  "alpn": ["h3"],
  "udp_relay_ipv6": true,
  "zero_rtt_handshake": false,
  "dual_stack": true,
  "auth_timeout": "3s",
  "task_negotiation_timeout": "3s",
  "max_idle_time": "10s",
  "max_external_packet_size": 1500,
  "send_window": 16777216,
  "receive_window": 8388608,
  "gc_interval": "3s",
  "gc_lifetime": "15s",
  "log_level": "warn"
}
EOF
  chmod 600 "${CONFIG_DIR}/config.json"
}

write_service() {
  cat >"/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=TUIC server
Documentation=https://github.com/${REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -c ${CONFIG_DIR}/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=infinity
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

open_firewall() {
  [[ "$OPEN_FIREWALL" -eq 1 ]] || return 0

  if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi '^Status: active'; then
    ufw allow "${PORT}/udp" >/dev/null || true
    log "ufw allowed ${PORT}/udp"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null || true
    firewall-cmd --reload >/dev/null || true
    log "firewalld allowed ${PORT}/udp"
  fi
}

url_encode() {
  local LC_ALL=C input="$1" output="" char encoded
  local i
  for ((i = 0; i < ${#input}; i++)); do
    char="${input:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) output+="$char" ;;
      *) printf -v encoded '%%%02X' "'$char"; output+="$encoded" ;;
    esac
  done
  printf '%s' "$output"
}

json_escape() {
  local input="$1"
  input="${input//\\/\\\\}"
  input="${input//\"/\\\"}"
  input="${input//$'\n'/\\n}"
  input="${input//$'\r'/\\r}"
  input="${input//$'\t'/\\t}"
  printf '%s' "$input"
}

get_public_ip() {
  local family="$1" url
  if [[ "$family" == "4" ]]; then
    for url in https://api.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
      curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' && return 0
    done
  else
    for url in https://api64.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
      curl -6 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' && return 0
    done
  fi
  return 1
}

make_link() {
  local host="$1" label="$2" host_for_link pass_enc sni_enc label_enc
  pass_enc="$(url_encode "$PASSWORD_VALUE")"
  sni_enc="$(url_encode "$SNI_VALUE")"
  label_enc="$(url_encode "$label")"
  host_for_link="$host"
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    host_for_link="[${host}]"
  fi

  printf 'tuic://%s:%s@%s:%s?congestion_control=%s&udp_relay_mode=native&alpn=h3&sni=%s&allow_insecure=1#%s' \
    "$UUID_VALUE" "$pass_enc" "$host_for_link" "$PORT" "$CONGESTION_CONTROL" "$sni_enc" "$label_enc"
}

save_links() {
  local ipv4 ipv6 link4 link6
  : >"${INSTALL_DIR}/links.txt"
  {
    echo "UUID=${UUID_VALUE}"
    echo "PASSWORD=${PASSWORD_VALUE}"
    echo "PORT=${PORT}"
    echo "SNI=${SNI_VALUE}"
    echo "CONGESTION_CONTROL=${CONGESTION_CONTROL}"
    echo
  } >>"${INSTALL_DIR}/links.txt"

  if ipv4="$(get_public_ip 4)"; then
    link4="$(make_link "$ipv4" "TUIC-IPv4")"
    echo "IPv4=${ipv4}" >>"${INSTALL_DIR}/links.txt"
    echo "TUIC_IPV4_LINK=${link4}" >>"${INSTALL_DIR}/links.txt"
  fi

  if ipv6="$(get_public_ip 6)"; then
    link6="$(make_link "$ipv6" "TUIC-IPv6")"
    echo "IPv6=${ipv6}" >>"${INSTALL_DIR}/links.txt"
    echo "TUIC_IPV6_LINK=${link6}" >>"${INSTALL_DIR}/links.txt"
  fi

  chmod 600 "${INSTALL_DIR}/links.txt"
}

print_links() {
  if [[ -f "${INSTALL_DIR}/links.txt" ]]; then
    echo
    echo "===== TUIC node information ====="
    cat "${INSTALL_DIR}/links.txt"
    echo "================================="
    echo
  else
    log "no saved link file found at ${INSTALL_DIR}/links.txt"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
  fi
}

install_service() {
  need_root
  install_dependencies
  require_cmd curl
  require_cmd openssl
  require_cmd sha256sum
  require_cmd systemctl

  [[ -n "$PORT" ]] || die "--port is required"
  valid_port "$PORT" || die "invalid port: $PORT"
  [[ "$CONGESTION_CONTROL" =~ ^(cubic|new_reno|bbr)$ ]] || die "invalid congestion control: $CONGESTION_CONTROL"
  valid_service_name "$SERVICE_NAME" || die "invalid systemd service name: $SERVICE_NAME"
  valid_sni "$SNI_VALUE" || die "invalid SNI value: $SNI_VALUE"

  if [[ -z "$UUID_VALUE" ]]; then
    UUID_VALUE="$(random_uuid)"
  fi
  valid_uuid "$UUID_VALUE" || die "invalid UUID: $UUID_VALUE"

  if [[ -z "$PASSWORD_VALUE" ]]; then
    PASSWORD_VALUE="$(random_password)"
  fi

  mkdir -p "$(dirname "$BIN_PATH")" "$INSTALL_DIR" "$CONFIG_DIR"
  download_binary
  write_certificate
  write_config
  write_service
  open_firewall

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.service"
  sleep 1
  systemctl is-active --quiet "${SERVICE_NAME}.service" || {
    systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
    die "service failed to start"
  }

  save_links
  print_links
}

uninstall_service() {
  need_root
  valid_service_name "$SERVICE_NAME" || die "invalid systemd service name: $SERVICE_NAME"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  rm -f "$BIN_PATH"
  safe_remove_dir "$CONFIG_DIR"
  safe_remove_dir "$INSTALL_DIR"
  log "uninstalled ${SERVICE_NAME}"
}

ACTION="install"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port) PORT="${2:-}"; shift 2 ;;
    -u|--uuid) UUID_VALUE="${2:-}"; shift 2 ;;
    -w|--password) PASSWORD_VALUE="${2:-}"; shift 2 ;;
    -s|--sni) SNI_VALUE="${2:-}"; shift 2 ;;
    -c|--congestion-control) CONGESTION_CONTROL="${2:-}"; shift 2 ;;
    -v|--version) VERSION_VALUE="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --config-dir) CONFIG_DIR="${2:-}"; shift 2 ;;
    --service-name) SERVICE_NAME="${2:-}"; shift 2 ;;
    --no-firewall) OPEN_FIREWALL=0; shift ;;
    --print) ACTION="print"; shift ;;
    --uninstall) ACTION="uninstall"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$ACTION" in
  install) install_service ;;
  print) print_links ;;
  uninstall) uninstall_service ;;
  *) die "unknown action: $ACTION" ;;
esac

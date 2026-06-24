#!/usr/bin/env bash
#
# Production-ready dnscrypt-proxy installation script for Debian-based systems.
#
# Layout:
#   /opt/dnscrypt-proxy                      root:root 0755, daemon binary/assets
#   /etc/dnscrypt-proxy                      root:root 0755, daemon configuration
#   /etc/dnscrypt-proxy/dnscrypt-proxy.toml  root:dnscrypt-proxy 0640
#   /var/lib/dnscrypt-proxy                  dnscrypt-proxy:dnscrypt-proxy 0750, service state/home
#   /var/cache/dnscrypt-proxy                dnscrypt-proxy:dnscrypt-proxy 0750, source caches
#
# Usage:
#   sudo ./install-dnscrypt-proxy.sh

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo_status() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

echo_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

if [[ "${EUID}" -ne 0 ]]; then
  echo_error "This script must be run as root (use sudo)."
  exit 1
fi

SERVICE_NAME="dnscrypt-proxy"
DNSCRYPT_USER="dnscrypt-proxy"
DNSCRYPT_GROUP="dnscrypt-proxy"

INSTALL_DIR="/opt/dnscrypt-proxy"
CONFIG_DIR="/etc/dnscrypt-proxy"
CONFIG="${CONFIG_DIR}/dnscrypt-proxy.toml"
CACHE_DIR="/var/cache/dnscrypt-proxy"
STATE_DIR="/var/lib/dnscrypt-proxy"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
UPDATE_WRAPPER="/usr/local/bin/update-dnscrypt-proxy"
RUNUSER="/usr/sbin/runuser"
PUBLIC_KEY="RWTk1xXqcTODeYttYMCMLo0YJHaFEHn7a3akqHlb/7QvIQXHVPxKbjB5"
SERVICE_CHANGED=0

detect_arch() {
  case "$(uname -m)" in
    aarch64) echo "arm64" ;;
    armv7l|arm*) echo "arm" ;;
    x86_64) echo "x86_64" ;;
    *) echo_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
}

download_release() {
  local workdir="$1"
  local release_dir="${workdir}/release"
  local arch latest_tag latest_version tarfile

  arch="$(detect_arch)"
  latest_tag="$(curl -fsSL https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)"
  latest_version="${latest_tag#v}"

  if [[ -z "${latest_tag}" || -z "${latest_version}" ]]; then
    echo_error "Could not detect latest dnscrypt-proxy release."
    exit 1
  fi

  tarfile="dnscrypt-proxy-linux_${arch}-${latest_version}.tar.gz"
  echo_status "Downloading dnscrypt-proxy ${latest_version} for ${arch}..."
  wget -q -P "${workdir}" "https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${latest_tag}/${tarfile}"

  echo_status "Verifying release signature with minisign..."
  wget -q -P "${workdir}" "https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${latest_tag}/${tarfile}.minisig"
  minisign -Vm "${workdir}/${tarfile}" -P "${PUBLIC_KEY}"

  mkdir -p "${release_dir}"
  tar -xzf "${workdir}/${tarfile}" -C "${release_dir}" --strip-components=1

  if [[ ! -x "${release_dir}/dnscrypt-proxy" || ! -f "${release_dir}/example-dnscrypt-proxy.toml" ]]; then
    echo_error "Downloaded release did not contain the expected dnscrypt-proxy files."
    exit 1
  fi
}

configure_setting() {
  local key="$1"
  local value="$2"
  local config="$3"
  local active_setting_pattern="^[[:space:]]*${key}[[:space:]]*="
  local commented_setting_pattern="^# ${key}[[:space:]]*="

  sed -i "/${active_setting_pattern}/c\\${key} = ${value}" "${config}" 2>/dev/null || true

  if ! grep -q "${active_setting_pattern}" "${config}"; then
    sed -i "/${commented_setting_pattern}/c\\${key} = ${value}" "${config}" 2>/dev/null || true
  fi

  if ! grep -q "${active_setting_pattern}" "${config}"; then
    printf '%s = %s\n' "${key}" "${value}" >> "${config}"
  fi
}

configure_section_setting() {
  local section="$1"
  local key="$2"
  local value="$3"
  local config="$4"
  local tmp

  tmp="$(mktemp)"

  awk -v section="${section}" -v key="${key}" -v value="${value}" '
    function is_section_header(line) {
      return line ~ /^[[:space:]]*\[[^]]+\][[:space:]]*($|#)/
    }

    function section_name(line, name) {
      name = line
      sub(/^[[:space:]]*\[/, "", name)
      sub(/\][[:space:]]*($|#.*$)/, "", name)
      return name
    }

    function is_target_key(line, trimmed) {
      trimmed = line
      sub(/^[[:space:]]*/, "", trimmed)
      return trimmed ~ "^" key "[[:space:]]*="
    }

    is_section_header($0) {
      if (in_target && !wrote) {
        print key " = " value
        wrote = 1
      }

      current = section_name($0)
      in_target = current == section

      if (in_target) {
        found_section = 1
        wrote = 0
      }

      print
      next
    }

    in_target && is_target_key($0) {
      if (!wrote) {
        print key " = " value
        wrote = 1
      }
      next
    }

    {
      print
    }

    END {
      if (in_target && !wrote) {
        print key " = " value
        wrote = 1
      }

      if (!found_section) {
        print ""
        print "[" section "]"
        print key " = " value
      }
    }
  ' "${config}" > "${tmp}"

  cat "${tmp}" > "${config}"
  rm -f "${tmp}"
}

render_systemd_service() {
  cat <<EOF
[Unit]
Description=dnscrypt-proxy encrypted DNS proxy
Documentation=https://github.com/DNSCrypt/dnscrypt-proxy/wiki

[Service]
Type=simple
User=${DNSCRYPT_USER}
Group=${DNSCRYPT_GROUP}
WorkingDirectory=${STATE_DIR}
ExecStartPre=${INSTALL_DIR}/dnscrypt-proxy -config ${CONFIG} -check
ExecStart=${INSTALL_DIR}/dnscrypt-proxy -config ${CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=120
StartLimitInterval=5
StartLimitBurst=10
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${CACHE_DIR} ${STATE_DIR}
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF
}

install_systemd_service() {
  local tmp

  tmp="$(mktemp)"
  render_systemd_service > "${tmp}"

  if [[ -f "${SERVICE_FILE}" ]] && cmp -s "${tmp}" "${SERVICE_FILE}"; then
    echo_status "Systemd service already matches ${SERVICE_FILE}; preserving it."
    rm -f "${tmp}"
    return 0
  fi

  if [[ -f "${SERVICE_FILE}" ]]; then
    echo_status "Updating systemd service at ${SERVICE_FILE}..."
  else
    echo_status "Installing systemd service at ${SERVICE_FILE}..."
  fi

  install -o root -g root -m 0644 "${tmp}" "${SERVICE_FILE}"
  rm -f "${tmp}"
  SERVICE_CHANGED=1
}

render_shell_assignment() {
  local name="$1"
  local value="$2"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\\$}"
  value="${value//\`/\\\`}"

  printf '%s="%s"\n' "${name}" "${value}"
}

render_update_wrapper() {
  cat <<'EOF'
#!/usr/bin/env bash
#
# Secure production update wrapper for dnscrypt-proxy.
#

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo_status() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

echo_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

if [[ "${EUID}" -ne 0 ]]; then
  echo_error "This script must be run as root (use sudo)."
  exit 1
fi

EOF

  render_shell_assignment "SERVICE_NAME" "${SERVICE_NAME}"
  render_shell_assignment "DNSCRYPT_USER" "${DNSCRYPT_USER}"
  render_shell_assignment "DNSCRYPT_GROUP" "${DNSCRYPT_GROUP}"
  render_shell_assignment "INSTALL_DIR" "${INSTALL_DIR}"
  render_shell_assignment "CONFIG" "${CONFIG}"
  render_shell_assignment "CACHE_DIR" "${CACHE_DIR}"
  render_shell_assignment "STATE_DIR" "${STATE_DIR}"
  render_shell_assignment "RUNUSER" "${RUNUSER}"
  render_shell_assignment "PUBLIC_KEY" "${PUBLIC_KEY}"

  cat <<'EOF'

BINARY="${INSTALL_DIR}/dnscrypt-proxy"
EXAMPLE_CONFIG="${INSTALL_DIR}/example-dnscrypt-proxy.toml"

detect_arch() {
  case "$(uname -m)" in
    aarch64) echo "arm64" ;;
    armv7l|arm*) echo "arm" ;;
    x86_64) echo "x86_64" ;;
    *) echo_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
}

rollback_install() {
  echo_error "Restoring previous installation from ${BACKUP_DIR}"

  if [[ -d "${INSTALL_DIR}" ]]; then
    mv "${INSTALL_DIR}" "${FAILED_DIR}" 2>/dev/null || true
  fi

  if [[ -d "${BACKUP_DIR}" ]]; then
    mv "${BACKUP_DIR}" "${INSTALL_DIR}"
  fi
}

if [[ ! -x "${BINARY}" ]]; then
  echo_error "dnscrypt-proxy binary not found at ${BINARY}"
  exit 1
fi

if [[ ! -f "${CONFIG}" ]]; then
  echo_error "dnscrypt-proxy config not found at ${CONFIG}"
  exit 1
fi

for required_dir in "${CACHE_DIR}" "${STATE_DIR}"; do
  if [[ ! -d "${required_dir}" ]]; then
    echo_error "Required directory not found at ${required_dir}"
    exit 1
  fi
done

ARCH="$(detect_arch)"
CURRENT_VERSION="$("${BINARY}" -version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
LATEST_TAG="$(curl -fsSL https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)"
LATEST_VERSION="${LATEST_TAG#v}"

if [[ -z "${LATEST_TAG}" || -z "${LATEST_VERSION}" ]]; then
  echo_error "Could not detect latest dnscrypt-proxy release."
  exit 1
fi

echo_status "Installed: ${CURRENT_VERSION:-unknown} | Latest: ${LATEST_VERSION}"

if [[ "${CURRENT_VERSION}" == "${LATEST_VERSION}" ]]; then
  echo_status "Already up to date."
  exit 0
fi

echo_status "Update available; proceeding with download and verification..."

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

TARFILE="dnscrypt-proxy-linux_${ARCH}-${LATEST_VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/${LATEST_TAG}/${TARFILE}"

echo_status "Downloading ${DOWNLOAD_URL}"
curl -fsSL -o "${WORKDIR}/update.tar.gz" "${DOWNLOAD_URL}"

if command -v minisign >/dev/null; then
  curl -fsSL -o "${WORKDIR}/update.tar.gz.minisig" "${DOWNLOAD_URL}.minisig"
  if minisign -Vm "${WORKDIR}/update.tar.gz" -P "${PUBLIC_KEY}"; then
    echo_status "Signature verified"
  else
    echo_error "Signature FAILED"
    exit 1
  fi
else
  echo_status "minisign not installed; skipping signature check"
fi

RELEASE_DIR="${WORKDIR}/release"
mkdir -p "${RELEASE_DIR}"
tar -xzf "${WORKDIR}/update.tar.gz" -C "${RELEASE_DIR}" --strip-components=1

if [[ ! -x "${RELEASE_DIR}/dnscrypt-proxy" ]]; then
  echo_error "Downloaded release did not contain an executable dnscrypt-proxy binary."
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d%H%M%S)"
STAGED_INSTALL="${INSTALL_DIR}.new.${TIMESTAMP}"
STAGED_BINARY="${STAGED_INSTALL}/dnscrypt-proxy"
RELEASE_EXAMPLE_CONFIG="${STAGED_INSTALL}/example-dnscrypt-proxy.toml"
BACKUP_DIR="${INSTALL_DIR}.old.${TIMESTAMP}"
FAILED_DIR="${INSTALL_DIR}.failed.${TIMESTAMP}"
EXAMPLE_REVIEW_DIR="${STATE_DIR}/example-config-${LATEST_VERSION}-${TIMESTAMP}"
REVIEW_OLD_EXAMPLE="${EXAMPLE_REVIEW_DIR}/example-dnscrypt-proxy.toml.old"
REVIEW_NEW_EXAMPLE="${EXAMPLE_REVIEW_DIR}/example-dnscrypt-proxy.toml.new"
REVIEW_EXAMPLE_DIFF="${EXAMPLE_REVIEW_DIR}/example-dnscrypt-proxy.toml.diff"

echo_status "Preparing complete release at ${STAGED_INSTALL}..."
install -d -o root -g root -m 0755 "${STAGED_INSTALL}"
cp -a "${RELEASE_DIR}"/* "${STAGED_INSTALL}/"
chown -R root:root "${STAGED_INSTALL}"
chmod 0755 "${STAGED_INSTALL}/dnscrypt-proxy"

echo_status "Validating installed config with the staged binary..."
if ! (
  cd "${STATE_DIR}"
  "${RUNUSER}" -u "${DNSCRYPT_USER}" -- "${STAGED_BINARY}" -config "${CONFIG}" -check
); then
  echo_error "Config check failed with staged binary."
  exit 1
fi

if [[ -f "${RELEASE_EXAMPLE_CONFIG}" ]]; then
  if [[ -f "${EXAMPLE_CONFIG}" ]]; then
    if ! cmp -s "${RELEASE_EXAMPLE_CONFIG}" "${EXAMPLE_CONFIG}"; then
      install -d -o root -g "${DNSCRYPT_GROUP}" -m 0750 "${EXAMPLE_REVIEW_DIR}"
      install -o root -g "${DNSCRYPT_GROUP}" -m 0640 "${EXAMPLE_CONFIG}" "${REVIEW_OLD_EXAMPLE}"
      install -o root -g "${DNSCRYPT_GROUP}" -m 0640 "${RELEASE_EXAMPLE_CONFIG}" "${REVIEW_NEW_EXAMPLE}"
      diff -u "${REVIEW_OLD_EXAMPLE}" "${REVIEW_NEW_EXAMPLE}" > "${REVIEW_EXAMPLE_DIFF}" 2>/dev/null || true
      chown root:"${DNSCRYPT_GROUP}" "${REVIEW_EXAMPLE_DIFF}"
      chmod 0640 "${REVIEW_EXAMPLE_DIFF}"
      echo "=================================================================="
      echo_status "[WARNING] example-dnscrypt-proxy.toml HAS CHANGED in new version"
      echo "   Review directory: ${EXAMPLE_REVIEW_DIR}"
      echo "   Old example:      ${REVIEW_OLD_EXAMPLE}"
      echo "   New example:      ${REVIEW_NEW_EXAMPLE}"
      echo "   Diff:             ${REVIEW_EXAMPLE_DIFF}"
      echo "=================================================================="
    fi
  fi
fi

echo_status "Stopping ${SERVICE_NAME}..."
systemctl stop "${SERVICE_NAME}"

echo_status "Replacing ${INSTALL_DIR} with the complete new release..."
if ! mv "${INSTALL_DIR}" "${BACKUP_DIR}"; then
  echo_error "Could not back up ${INSTALL_DIR}; leaving current installation in place."
  systemctl start "${SERVICE_NAME}" || true
  exit 1
fi

if ! mv "${STAGED_INSTALL}" "${INSTALL_DIR}"; then
  rollback_install
  systemctl start "${SERVICE_NAME}" || true
  exit 1
fi

echo_status "Starting ${SERVICE_NAME}..."
if systemctl start "${SERVICE_NAME}" && systemctl is-active --quiet "${SERVICE_NAME}"; then
  echo_status "dnscrypt-proxy successfully updated to ${LATEST_VERSION}."
  echo_status "Previous installation retained at ${BACKUP_DIR}."
else
  echo_error "Service start failed after update."
  rollback_install
  systemctl start "${SERVICE_NAME}" || true
  exit 1
fi
EOF
}

install_update_wrapper() {
  local tmp
  local wrapper_dir

  tmp="$(mktemp)"
  wrapper_dir="$(dirname "${UPDATE_WRAPPER}")"
  render_update_wrapper > "${tmp}"

  install -d -o root -g root -m 0755 "${wrapper_dir}"

  if [[ -f "${UPDATE_WRAPPER}" ]] && cmp -s "${tmp}" "${UPDATE_WRAPPER}"; then
    echo_status "Update wrapper already matches ${UPDATE_WRAPPER}; preserving it."
    chown root:root "${UPDATE_WRAPPER}"
    chmod 0755 "${UPDATE_WRAPPER}"
    rm -f "${tmp}"
    return 0
  fi

  if [[ -f "${UPDATE_WRAPPER}" ]]; then
    echo_status "Updating update wrapper at ${UPDATE_WRAPPER}..."
  else
    echo_status "Installing update wrapper at ${UPDATE_WRAPPER}..."
  fi

  install -o root -g root -m 0755 "${tmp}" "${UPDATE_WRAPPER}"
  rm -f "${tmp}"
}

ensure_directory() {
  local owner="$1"
  local group="$2"
  local mode="$3"
  local dir="$4"

  if [[ -d "${dir}" ]]; then
    echo_status "Directory already exists at ${dir}; preserving it."
    return 0
  fi

  echo_status "Creating directory ${dir}."
  install -d -o "${owner}" -g "${group}" -m "${mode}" "${dir}"
}

test_dns_resolution() {
  local attempt
  local max_attempts=30
  local output

  echo_status "Testing DNS resolution through dnscrypt-proxy..."

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if output="$(dig @127.0.0.1 -p 5053 google.com +short +tries=1 +time=2)" && [[ -n "${output}" ]]; then
      printf '%s\n' "${output}"
      return 0
    fi

    if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
      echo_error "${SERVICE_NAME} is not running."
      return 1
    fi

    if [[ "${attempt}" -lt "${max_attempts}" ]]; then
      sleep 2
    fi
  done

  echo_error "dnscrypt-proxy did not answer DNS queries after repeated attempts."
  return 1
}

echo_status "=== Starting production dnscrypt-proxy installation ==="

echo_status "Installing runtime dependencies..."
apt-get update -qq
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  dnsutils \
  minisign \
  wget

echo_status "Ensuring dedicated runtime user and directories..."
if ! getent group "${DNSCRYPT_GROUP}" >/dev/null; then
  addgroup --system "${DNSCRYPT_GROUP}"
else
  echo_status "Group ${DNSCRYPT_GROUP} already exists."
fi

if ! id -u "${DNSCRYPT_USER}" >/dev/null 2>&1; then
  adduser --system \
    --home "${STATE_DIR}" \
    --ingroup "${DNSCRYPT_GROUP}" \
    --shell /usr/sbin/nologin \
    --no-create-home \
    "${DNSCRYPT_USER}"
else
  echo_status "User ${DNSCRYPT_USER} already exists."
fi

ensure_directory root root 0755 "${INSTALL_DIR}"
ensure_directory root root 0755 "${CONFIG_DIR}"
ensure_directory "${DNSCRYPT_USER}" "${DNSCRYPT_GROUP}" 0750 "${CACHE_DIR}"
ensure_directory "${DNSCRYPT_USER}" "${DNSCRYPT_GROUP}" 0750 "${STATE_DIR}"

if [[ -x "${INSTALL_DIR}/dnscrypt-proxy" ]]; then
  echo_status "Existing dnscrypt-proxy binary found at ${INSTALL_DIR}; preserving it."
else
  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "${WORKDIR}"' EXIT

  download_release "${WORKDIR}"
  cp -a "${WORKDIR}/release"/* "${INSTALL_DIR}/"
  chown -R root:root "${INSTALL_DIR}"
  chmod 0755 "${INSTALL_DIR}/dnscrypt-proxy"
fi

if [[ ! -f "${INSTALL_DIR}/example-dnscrypt-proxy.toml" ]]; then
  echo_error "Missing ${INSTALL_DIR}/example-dnscrypt-proxy.toml; ${INSTALL_DIR} does not look like a complete dnscrypt-proxy installation."
  exit 1
fi

if [[ ! -f "${CONFIG}" ]]; then
  echo_status "Installing default config at ${CONFIG}..."
  install -o root -g "${DNSCRYPT_GROUP}" -m 0640 "${INSTALL_DIR}/example-dnscrypt-proxy.toml" "${CONFIG}"

  configure_setting "server_names" "['cloudflare']" "${CONFIG}"
  configure_setting "listen_addresses" "['127.0.0.1:5053']" "${CONFIG}"
  configure_setting "max_clients" "1000" "${CONFIG}"
  configure_setting "dnscrypt_servers" "false" "${CONFIG}"
  configure_setting "doh_servers" "true" "${CONFIG}"
  configure_setting "require_dnssec" "true" "${CONFIG}"
  configure_setting "bootstrap_resolvers" "['1.1.1.1:53', '1.0.0.1:53']" "${CONFIG}"
  configure_setting "netprobe_address" "'1.1.1.1:53'" "${CONFIG}"
  configure_section_setting "sources.public-resolvers" \
    "cache_file" \
    "'${CACHE_DIR}/public-resolvers.md'" \
    "${CONFIG}"
  configure_section_setting "sources.relays" \
    "cache_file" \
    "'${CACHE_DIR}/relays.md'" \
    "${CONFIG}"
else
  echo_status "Existing config found at ${CONFIG}; preserving it."
fi

echo_status "Validating configuration and installing service/update wrapper..."
(
  cd "${STATE_DIR}"
  "${RUNUSER}" -u "${DNSCRYPT_USER}" -- "${INSTALL_DIR}/dnscrypt-proxy" -config "${CONFIG}" -check
)

install_systemd_service
install_update_wrapper

if [[ "${SERVICE_CHANGED}" -eq 1 ]]; then
  echo_status "Reloading systemd after service file change..."
  systemctl daemon-reload
fi

if systemctl is-enabled --quiet "${SERVICE_NAME}"; then
  echo_status "${SERVICE_NAME} is already enabled."
else
  echo_status "Enabling ${SERVICE_NAME}..."
  systemctl enable "${SERVICE_NAME}"
fi

if [[ "${SERVICE_CHANGED}" -eq 1 ]] && systemctl is-active --quiet "${SERVICE_NAME}"; then
  echo_status "Restarting ${SERVICE_NAME} to apply service file changes..."
  systemctl restart "${SERVICE_NAME}"
elif systemctl is-active --quiet "${SERVICE_NAME}"; then
  echo_status "${SERVICE_NAME} is already running."
else
  echo_status "Starting ${SERVICE_NAME}..."
  systemctl start "${SERVICE_NAME}"
fi

test_dns_resolution

echo_status "dnscrypt-proxy installation completed successfully."
echo_status "Installed at:      ${INSTALL_DIR}"
echo_status "Config file:       ${CONFIG}"
echo_status "State directory:   ${STATE_DIR}"
echo_status "Cache directory:   ${CACHE_DIR}"
echo_status "Update wrapper:    ${UPDATE_WRAPPER}"

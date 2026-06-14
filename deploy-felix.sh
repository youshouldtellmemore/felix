#!/bin/bash

# 
# Copyright: 2025-01-18
# 
# About:
#  This script sets up the felix server to act as a cloudflare tunnel, and serve the djfm Django web app from a
#  sub-domain.
# 

set -euo pipefail

# Colors for clear terminal output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo_status() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

echo_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
  exit 1
}

# Must be run as root
if [[ "${EUID}" -ne 0 ]]; then
  echo_error "This script must be run as root (use sudo)."
fi

# Load .env file or fail
if [ ! -f "$0.env" ]; then
  echo_error "Missing $0.env."
else
  # shellcheck disable=SC1090
  source "$0.env"
fi

# Validate required .env configurations.
if [[ -z "${APP_USER}" ]]; then echo_error "Missing APP_USER set in $0.env."; fi
if [[ -z "${APP_URL}" ]]; then echo_error "Missing APP_URL set in $0.env."; fi
if [[ -z "${APP_REPO}" ]]; then echo_error "Missing APP_REPO set in $0.env."; fi
if [[ -z "${APP_REVERSE_PROXY_PORT}" ]]; then echo_error "Missing APP_REVERSE_PROXY_PORT set in $0.env."; fi
# if [[ -z "${CLOUDFLARE_TUNNEL_TOKEN}" ]]; then echo_error "Missing CLOUDFLARE_TUNNEL_TOKEN set in $0.env."; fi
if [[ -n "${PG_DUMP_FILE}" && ! -f "${PG_DUMP_FILE}" ]]; then echo_error "Failed to locate ${PG_DUMP_FILE}."; fi
if [[ -z "${DB_USER}" ]]; then echo_error "Missing DB_USER set in $0.env."; fi
if [[ -z "${DB_PASSWD}" ]]; then echo_error "Missing DB_PASSWD set in $0.env."; fi
if [[ -z "${PYENV_VER}" ]]; then echo_error "Missing PYENV_VER set in $0.env."; fi

# pyenv must be installed, wrapper script with Python build options present, and noted version available to install.
PYENV_ROOT="/opt/pyenv"
PYENV_INSTALL="/usr/local/bin/pyenv-install"
if [[ ! -f "${PYENV_INSTALL}" ]]; then echo_error "Missing ${PYENV_INSTALL}."; fi
# shellcheck disable=SC2143
if [[ -z "$("${PYENV_ROOT}/bin/pyenv" install -l | grep "\s${PYENV_VER}$")" ]]; then echo_error "Cannot locate pyenv version ${PYENV_VER}."; fi

APP_REPO_NAME="${APP_REPO##*/}"
APP_REPO_NAME="${APP_REPO_NAME%.git}"

APP_ROOT="/opt/${APP_URL}"
APP_LOG_ROOT="/var/log/${APP_URL}"          # gunicorn, nginx logs.
APP_BACKUPS_ROOT="/var/backups/${APP_URL}"  # Django and postgres DB backups.
APP_RUN_ROOT="/var/run/${APP_URL}"          # gunicorn socket and nginx PID files.
APP_WWW_ROOT="/var/www/${APP_URL}"          # Django staticfiles served by nginx.
APP_CERTS_ROOT="/etc/acme/${APP_URL}"       # ACME-generated certificate files for the application.

ACME_ROOT="/opt/acme"
ACME_WWW_ROOT="/var/www/acme"

CF_SYSTEMD_SERVICE="/etc/systemd/system/cloudflared.service"

# Print welcome message.
echo_status "=== Starting production configuration of felix ==="

# Don't start doing all those things until the user acknowledges they want to continue. Comment out for automated use.
read -p "Press [Enter] key to start, or Ctrl-C to cancel."

# 1. Add cloudflared apt source and require use of their apt key.
#    According to 10/2025 note at https://pkg.cloudflare.com/index.html, bookworm is the only pinned release.
echo_status "Adding cloudflare to apt sources"
DEBIAN_CODENAME="$(lsb_release -cs)"
if [[ "${DEBIAN_CODENAME}" != "bookworm" ]]; then
  DEBIAN_CODENAME="any"
fi
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared ${DEBIAN_CODENAME} main" | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null

# 2. Update package index (required on fresh installs)
echo_status "Updating apt package index..."
apt-get update -qq

# 3. Install all required build packages
echo_status "Installing dependencies (cloudflared, nginx, postgresql libs, etc.)..."
apt-get install -y --no-install-recommends \
  cloudflared \
  git \
  nginx \
  postgresql \
  postgresql-contrib \
  libpq-dev

echo_status "Disabling nginx's default site."
sudo unlink /etc/nginx/sites-enabled/default
sudo systemctl reload nginx

# 4. Create the web application's postgresql database and, optionally, restore it from backup.
echo_status "Setting up PostgreSQL"
sudo -iu postgres << EOF
echo "[postgres] Creating database user ${DB_USER}"
createuser -d ${DB_USER}
psql -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASSWD}'"

echo "[postgres] Creating new database ${APP_REPO_NAME} and setting owner to ${DB_USER}"
createdb "${APP_REPO_NAME}" --owner ${DB_USER}
EOF

# shellcheck disable=SC2153
if [[ -n "${PG_DUMP_FILE}" ]]; then
  PG_TEMP_DIR=$(mktemp -d)
  PG_TEMP_FILE="${PG_TEMP_DIR}/${PG_DUMP_FILE##*/}"
  cp "${PG_DUMP_FILE}" "${PG_TEMP_DIR}"
  sudo chown -R postgres "${PG_TEMP_DIR}"
  sudo -iu postgres << EOF
  echo "[postgres] Restoring database ${APP_REPO_NAME} from backup file ${PG_TEMP_FILE}."
  pg_restore --no-owner --role=${DB_USER} -d ${APP_REPO_NAME} "${PG_TEMP_FILE}"
EOF
else
  echo "[postgres] No database backup – skipping pg_restore."
fi

# 5. Setup the application user and necessary application folders.
echo_status "Creating application user ${APP_USER}"
sudo adduser --system --home "${APP_ROOT}" --group "${APP_USER}" --no-create-home
sudo install -d -o "${APP_USER}" -g "${APP_USER}" -m 0700 "${APP_ROOT}/bin"

echo_status "Creating application folders."
sudo install -d -o "${APP_USER}" -g "${APP_USER}" \
  "${APP_RUN_ROOT}" \
  "${APP_WWW_ROOT}" \
  "${APP_LOG_ROOT}/gunicorn" \
  "${APP_LOG_ROOT}/postgres-backup-restore"

sudo install -d -o "${APP_USER}" -g "www-data" -m 0775 "${APP_LOG_ROOT}/nginx"

sudo install -d -o "${APP_USER}" -g "${APP_USER}" -m 0750 "${APP_BACKUPS_ROOT}/django"
sudo install -d -o "${APP_USER}" -g "${APP_USER}" -m 0700 "${APP_BACKUPS_ROOT}/postgres"

# 6. Setup the acme user and necessary application folders.
# Create a non-root user account for running acme per https://github.com/acmesh-official/acme.sh/wiki/sudo#create-non-root-account.
sudo adduser --system --home "${ACME_ROOT}" --group acme --no-create-home
sudo install -d -o "acme" -g "acme" -m 0750 "${ACME_ROOT}"

echo "acme ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload nginx" > /etc/sudoers.d/acme-nginx
sudo chmod 0440 /etc/sudoers.d/acme-nginx

sudo install -d -o "acme" -g "acme" "${ACME_WWW_ROOT}"
sudo install -d -o "acme" -g "www-data" -m 0740 "${APP_CERTS_ROOT}"

# 7. Install acme.sh – cannot issue certificates until Cloudflare tunnel is setup.
echo_status "[acme] Installing acme.sh to ${ACME_ROOT}"
sudo -u acme -s <<EOF
cd ~

# Initialize system user crontab since acme.sh integrates to it. Adapted from https://stackoverflow.com/a/9625233.
(crontab -l 2>/dev/null; echo "") | crontab -

# Download and install acme.sh.
curl https://get.acme.sh | sh
EOF

# 8. Create an acme.sh nginx configuration and activate it.
echo_status "[acme] Creating nginx available site."
cat << EOF > /etc/nginx/sites-available/acme
server {
  listen 64816;
  client_max_body_size 4G;

  # set the correct host(s) for your site
  server_name ${APP_URL};

  keepalive_timeout 5;

  # path for static files
  root ${ACME_WWW_ROOT};

  location / {
    # checks for static file, if not found drop connection
    try_files \$uri =444;
  }
}
EOF
sudo ln -s /etc/nginx/sites-available/acme /etc/nginx/sites-enabled/acme
sudo systemctl reload nginx

# 9. Setup Cloudflare tunnel.
if [[ -f "${CF_SYSTEMD_SERVICE}" ]]; then
  echo_status "Cloudflare service already present – skipping tunnel setup."
elif [[ -z "${CLOUDFLARE_TUNNEL_TOKEN}" ]]; then
  echo_status "Cloudflare tunnel token not specified in CLOUDFLARE_TUNNEL_TOKEN – skipping tunnel setup."
else
  echo_status "Setting up Cloudflare tunnel"
  sudo cloudflared service install "${CLOUDFLARE_TUNNEL_TOKEN}"
fi

# 10. Issue certificate against the test server to verify everything's working.
echo_status "[acme] Automating certificate generation and renewal for ${APP_URL}"
sudo -u acme -s <<EOF
cd ~
.acme.sh/acme.sh --issue --server letsencrypt -d ${APP_URL} -w "${ACME_WWW_ROOT}"
.acme.sh/acme.sh --install-cert --domain "${APP_URL}" --key-file ${APP_CERTS_ROOT}/key.pem --fullchain-file ${APP_CERTS_ROOT}/cert.pem --reloadcmd "sudo systemctl reload nginx"
EOF

# 11. Make sure pyenv is setup and the target Python version is installed.
echo_status "Downloading and building Python ${PYENV_VER}. This will take some time!"
sudo "${PYENV_INSTALL}" "${PYENV_VER}"


# Setup Django application user account:
# - create app runtime folders
# - change file/folder permissions: only allow app user, with limited group access
# - create venv: create a Python-version specific venv and symlink to it
sudo -u "${APP_USER}" -s <<EOF
cd ~

# Create a virtual environment specific to current Python version; then, symlink to it. This helps with upgrading later.
echo "[${APP_USER}] Creating venv"
"${PYENV_ROOT}/versions/${PYENV_VER}/bin/python" -m venv ".venv-${PYENV_VER}"
ln -s ".venv-${PYENV_VER}" .venv

echo "[${APP_USER}] Cloning ${APP_REPO}"
# Clone the GitHub repository.
git clone ${APP_REPO}

echo "[${APP_USER}] Installing application's requirements."
source .venv/bin/activate
cd "${APP_REPO_NAME}"  # repo folder
python -m pip install -r requirements/prod.txt

echo "[${APP_USER}] Generating application .env"
python3 "${APP_REPO_NAME}/helpers/secret_key.py" > "${APP_REPO_NAME}/settings/.env"
echo "DATABASE_URL=postgres://${DB_USER}:${DB_PASSWD}@localhost:5432/${APP_REPO_NAME}" >> ${APP_REPO_NAME}/settings/.env
echo "STATIC_ROOT=${APP_WWW_ROOT}/static" >> ${APP_REPO_NAME}/settings/.env
echo "ALLOWED_HOSTS=${APP_URL}" >> ${APP_REPO_NAME}/settings/.env

echo "[$APP_USER}] Generation .pgpass"
echo "localhost:5432:${APP_REPO_NAME}:${DB_USER}:${DB_PASSWD}" > ~/.pgpass
chmod 600 ~/.pgpass

echo "[${APP_USER}] Running first Django migration"
cd "${APP_REPO_NAME}"
python3 manage.py migrate

echo "[${APP_USER}] Collecting staticfiles"
python3 manage.py collectstatic
EOF

echo_status "Creating web application systemd unit socket."
cat << EOF > "/etc/systemd/system/${APP_URL}-gunicorn.socket"
[Unit]
Description=${APP_URL} gunicorn socket

[Socket]
ListenStream=${APP_RUN_ROOT}/gunicorn.sock
# Our service won't need permissions for the socket, since it
# inherits the file descriptor by socket activation.
# Only the nginx daemon will need access to the socket:
SocketUser=${APP_USER}
SocketGroup=www-data
# Once the user/group is correct, restrict the permissions:
SocketMode=0660

[Install]
WantedBy=sockets.target
EOF

echo_status "Creating web application systemd unit service."
cat << EOF > "/etc/systemd/system/${APP_URL}-gunicorn.service"
[Unit]
Description=${APP_URL} gunicorn daemon
Requires=${APP_URL}-gunicorn.socket
After=network.target

[Service]
# gunicorn can let systemd know when it is ready
Type=notify
NotifyAccess=main
# the specific user that our service will run as
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_ROOT}/${APP_REPO_NAME}/${APP_REPO_NAME}
Environment="PATH=${APP_ROOT}/.venv/bin"
# TODO:--limit-request-line is a hack for misusing GET vs POST..but this is easier for now
ExecStart=${APP_ROOT}/.venv/bin/gunicorn settings.wsgi:application \
	--name "${APP_URL}-gunicorn" \
	--limit-request-line 8190 \
	--workers 3 \
	--bind unix:${APP_RUN_ROOT}/gunicorn.sock \
	--access-logfile ${APP_LOG_ROOT}/gunicorn/access.log \
	--error-logfile ${APP_LOG_ROOT}/gunicorn/error.log
ExecReload=/bin/kill -s HUP \$MAINPID
KillMode=mixed
TimeoutStopSec=5
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# Enable socket and start its service.
sudo systemctl enable --now "${APP_URL}-gunicorn.socket"
sudo systemctl start "${APP_URL}-gunicorn"

###
###
### Django app's installed; next is plumbing between Cloudflare and Gunicorn via nginx.
###
###

# Create Django app's nginx configuration.
cat << EOF > "/etc/nginx/sites-available/${APP_URL}"
error_log  ${APP_LOG_ROOT}/nginx/error.log warn;
access_log ${APP_LOG_ROOT}/nginx/access.log combined;

upstream app_server {
  server unix:/run/${APP_URL}/gunicorn.sock fail_timeout=0;
}

server {
  listen ${APP_REVERSE_PROXY_PORT} ssl http2;

  server_name ${APP_URL};

  ssl_certificate     /etc/acme/${APP_URL}/cert.pem;
  ssl_certificate_key /etc/acme/${APP_URL}/key.pem;

  # Modern TLS settings
  ssl_protocols TLSv1.3;

  ssl_session_cache shared:SSL:20m;
  ssl_session_timeout 60m;

  client_max_body_size 4G;
  keepalive_timeout 5;
  server_tokens off;

  # Security headers
  add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Referrer-Policy "strict-origin-when-cross-origin" always;
  add_header Permissions-Policy "interest-cohort=()" always;

  # path for static files
  root "${APP_WWW_ROOT}";

  location / {
    try_files \$uri @proxy_to_app;
  }

  location @proxy_to_app {
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$server_name;
    proxy_set_header Host \$http_host;
    proxy_redirect off;
    proxy_pass http://app_server;
  }
}
EOF
sudo ln -s "/etc/nginx/sites-available/${APP_URL}" "/etc/nginx/sites-enabled/${APP_URL}"
sudo systemctl reload nginx

cat << SH_EOF > "${APP_ROOT}/bin/postgres-backup-restore.sh"
#!/bin/bash

# Standalone script for PostgreSQL database backup using pg_dump
# - Uses pg_dump -Fc for custom-format backups (.dump.gz)
# - Supports optional restoration from custom-format backups
# - Loads DATABASE_URL from an environment file (key/value format)
# - Syntax: db_backup_pg_dump.sh [--env ENV_FILE] [--restore RESTORE_FILE] [--help]
# - Logs to /var/log/\${APP_NAME}/db_backup_pg_dump/db_backup_pg_dump.log
# - Stores backups in /var/backups/\${APP_NAME}/postgres
# - Logs deleted backup files during rotation
# - Designed for systemd automation with error handling and secure permissions

set -e  # Exit on any unhandled error

# Default configuration
APP_NAME="${APP_URL}"
PGPASS_FILE="${APP_ROOT}/.pgpass"
DEFAULT_ENV_FILE="${APP_ROOT}/${APP_REPO_NAME}/${APP_REPO_NAME}/settings/.env"
BACKUP_RETENTION_DAYS=365  # Days to keep backups

# Function to display usage information
usage() {
    cat << EOF
Usage: \$0 [--env ENV_FILE] [--restore RESTORE_FILE] [--help]

Options:
  --env ENV_FILE       Path to env file containing DATABASE_URL (optional, defaults to script_dir/.env)
  --restore RESTORE_FILE Path to custom-format backup file for pg_restore (optional)
  --help               Display this help message

Description:
  Performs pg_dump backup of the database specified in DATABASE_URL (creating .dump.gz files).
  Optionally restores from a custom-format backup if specified.
  Requires an env file with:
  DATABASE_URL=postgres://username:password@host:port/database
  Logs to /var/log/APP_NAME/db_backup_pg_dump/db_backup_pg_dump.log and stores backups in
  /var/backups/APP_NAME/postgres.

Example:
  \$0 --env ~/.env --restore backup.dump
EOF
    exit 0
}

# Parse command-line arguments
while [ \$# -gt 0 ]; do
    case "\$1" in
        --env)
            ENV_FILE="\$2"
            shift 2
            ;;
        --restore)
            RESTORE_FILE="\$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            echo "Error: Unknown option \$1" >&2
            usage
            ;;
    esac
done

# Set env file (default if not specified)
ENV_FILE="\${ENV_FILE:-\$DEFAULT_ENV_FILE}"

# Function to load and validate DATABASE_URL from env file
# Sets DATABASE_URL and extracts components
load_env() {
    if [ ! -f "\$ENV_FILE" ]; then
        echo "\$(date): Error: Env file not found at \$ENV_FILE" >&2
        exit 1
    fi
    chmod 0600 "\$ENV_FILE"

    # Read the file and extract DATABASE_URL
    line=\$(grep '^DATABASE_URL=postgres://' "\$ENV_FILE" | head -n 1 || true)
    if [ -z "\$line" ]; then
        echo "\$(date): Error: No DATABASE_URL found in env file" >&2
        exit 1
    fi

    DATABASE_URL="\${line#DATABASE_URL=}"
    if [[ "\$DATABASE_URL" != postgres://* ]]; then
        echo "\$(date): Error: Invalid DATABASE_URL format" >&2
        exit 1
    fi

    # Extract DB_NAME from the URI (last segment after /)
    DB_NAME="\${DATABASE_URL##*/}"
    if [ -z "\$DB_NAME" ] || [[ "\$DB_NAME" == *:* ]] || [[ "\$DB_NAME" == *@* ]]; then
        echo "\$(date): Error: Could not extract valid database name from DATABASE_URL" >&2
        exit 1
    fi

    # Validate DB_NAME
    if ! [[ "\$DB_NAME" =~ ^[a-zA-Z0-9_]+\$ ]]; then
        echo "\$(date): Error: Invalid database name extracted from DATABASE_URL: '\$DB_NAME'" >&2
        exit 1
    fi
}

# Function to log messages
# Args: \$1 - Message to log
log_message() {
    echo "\$(date): \$1" | tee -a "\$LOG_FILE"
}

# Function to perform pg_dump backup
backup_database() {
    local backup_file="\$BACKUP_DIR/backup_\${DB_NAME}_\$(date +%F_%H%M%S).dump.gz"
    log_message "Starting pg_dump backup for \$DB_NAME"

    # Use URI directly (no --dbname=) with -w (fail immediately on password issues)
    if pg_dump -Fc -w "\$DATABASE_URL" | gzip > "\$backup_file" 2>>"\$LOG_FILE"; then
        log_message "Backup created: \$backup_file"
    else
        log_message "Error: Failed to create backup for \$DB_NAME"
        exit 1
    fi

    # Set secure permissions on backup file
    chmod 600 "\$backup_file"

    # Rotate backups older than retention period and log deleted files
    local deleted_files
    deleted_files=\$(find "\$BACKUP_DIR" -name "backup_\${DB_NAME}_*.dump.gz" -mtime +"\$BACKUP_RETENTION_DAYS" -print -delete)
    if [ -n "\$deleted_files" ]; then
        log_message "Rotated backups (older than \$BACKUP_RETENTION_DAYS days):"
        echo "\$deleted_files" | while IFS= read -r file; do
            log_message "  Deleted: \$file"
        done
    else
        log_message "No backups older than \$BACKUP_RETENTION_DAYS days to rotate"
    fi
}

# Function to restore database from custom-format backup
# Args: \$1 - Path to backup file
restore_database() {
    local backup_file="\$1"
    if [ -z "\$backup_file" ]; then
        log_message "No restore file provided, skipping restoration"
        return
    fi
    if [ ! -r "\$backup_file" ]; then
        log_message "Error: Backup file \$backup_file not readable or does not exist"
        exit 1
    fi
    log_message "Restoring database \$DB_NAME from \$backup_file"

    # Use URI directly (no --dbname=) with -w (fail immediately on password issues)
    if pg_restore -w --no-owner "\$DATABASE_URL" "\$backup_file" >/dev/null 2>&1; then
        log_message "Database \$DB_NAME restored successfully"
    else
        log_message "Error: Failed to restore database \$DB_NAME"
        exit 1
    fi
}

# Main execution

# Load and validate env file + DATABASE_URL
load_env

# Set derived variables
LOG_FILE="/var/log/\${APP_NAME}/db_backup_pg_dump/db_backup_pg_dump.log"
BACKUP_DIR="/var/backups/\${APP_NAME}/postgres"

# Ensure log directory and file exist with secure permissions
mkdir -p "\$(dirname "\$LOG_FILE")"
chmod 700 "\$(dirname "\$LOG_FILE")"
touch "\$LOG_FILE"
chmod 600 "\$LOG_FILE"

# Ensure backup directory exists with secure permissions
mkdir -p "\$BACKUP_DIR"
chmod 700 "\$BACKUP_DIR"

log_message "Starting database backup for \$DB_NAME (backups in \$BACKUP_DIR)"

# Perform restore if specified
restore_database "\$RESTORE_FILE"

# Perform backup
backup_database

# Clean up sensitive environment variable
unset DATABASE_URL

log_message "Database backup for \$DB_NAME completed successfully"

exit 0
SH_EOF
chown "${APP_USER}:${APP_USER}" "${APP_ROOT}/bin/postgres-backup-restore.sh"
chmod +x "${APP_ROOT}/bin/postgres-backup-restore.sh"

echo_status "Creating web application postgres backup unit service."
cat << EOF > "/etc/systemd/system/${APP_URL}-postgres-backup.service"
[Unit]
Description=${APP_URL} PostgreSQL Database Backup
After=network.target

[Service]
Type=oneshot
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_ROOT}
ExecStart=${APP_ROOT}/bin/postgres-backup-restore.sh
StandardOutput=append:${APP_LOG_ROOT}/postgres-backup-restore/service.log
StandardError=append:${APP_LOG_ROOT}/postgres-backup-restore/service.log

[Install]
WantedBy=multi-user.target

EOF

cat << EOF > "/etc/systemd/system/${APP_URL}-postgres-backup.timer"
[Unit]
Description=Daily ${APP_URL} PostgreSQL Database Backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable "/etc/systemd/system/${APP_URL}-postgres-backup.timer"
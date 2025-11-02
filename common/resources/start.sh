#!/usr/bin/with-contenv bashio
#
# Copyright [2025] [LeMaRiva Tech]
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

bashio::log.info "Preparing to start HAProxy Add-on..."

# -----------------------------------------------------------------------------
# 1. DEFINE CONSTANTS & VARIABLES
# -----------------------------------------------------------------------------

# Constants/Paths
HA_PROXY_DIR=/usr/local/etc/haproxy
HAPROXY_PID_FILE="/var/run/haproxy.pid"
CERT_PERSISTENT_DIR="/addon_config/le_certs"
DEFAULT_PEM="${HA_PROXY_DIR}/default.pem"
TEMPLATE_FILE="/app/haproxy.cfg.template"
FINAL_CONFIG="/$(bashio::config 'data_path')/haproxy.cfg" # Directly construct FINAL_CONFIG

# Require and Load Config
bashio::config.require 'data_path' 'stats_user' 'stats_password' 'ha_ip_address' 'ha_port'

# HAProxy Variables (Used for SED templating)
export HAPROXY_DATA="$(bashio::config 'data_path')"
HA_SERVICE_IP="$(bashio::config 'ha_ip_address')"
HA_SERVICE_PORT="$(bashio::config 'ha_port')"
FORCE_HTTPS_REDIRECT="$(bashio::config 'force_redirect')"
HAPROXY_STATS_USER="$(bashio::config 'stats_user')"
HAPROXY_STATS_PASS="$(bashio::config 'stats_password')"

# Logging Variable: Read, lowercase, and validate the log level from config.yaml
# This is added to the HAProxy configuration using the __LOG_LEVEL__ placeholder.
LOG_LEVEL=$(bashio::config 'log_level' | awk '{print tolower($0)}')
if bashio::var.is_empty "${LOG_LEVEL}" || [ "${LOG_LEVEL}" = "null" ]; then
    LOG_LEVEL="info" # Default to INFO if not set
fi

# HAProxy uses 'warning', not 'warn', for syslog compatibility
if [ "${LOG_LEVEL}" = "warn" ]; then
    LOG_LEVEL="warning"
fi

bashio::log.info "HAProxy log level set to: ${LOG_LEVEL}"

# Certbot Variables
CERT_EMAIL="$(bashio::config 'cert_email')"
CERT_DOMAIN="$(bashio::config 'cert_domain')"
CERTBOT_CERT_PATH="${CERT_PERSISTENT_DIR}/live/${CERT_DOMAIN}"

# Host Ports (Used for SED templating)
HOST_PORT_80=$(bashio::addon.port 80)
HOST_PORT_443=$(bashio::addon.port 443)
HOST_PORT_9999=$(bashio::addon.port 9999)

bashio::log.info "HAProxy ports: HTTP=${HOST_PORT_80}, HTTPS=${HOST_PORT_443}, Stats=${HOST_PORT_9999}"

# -----------------------------------------------------------------------------
# 2. CONFIGURATION TEMPLATING
# -----------------------------------------------------------------------------

mkdir -p "$(dirname "${FINAL_CONFIG}")" || bashio::exit.nok "Could not create data directory."
rm -f "${HAPROXY_PID_FILE}"

# Copy the template and perform all SED replacements in a single pipeline
# Using a temp file for safety, then moving it to the final location
< "${TEMPLATE_FILE}" \
    sed "
        s|__HOST_PORT_9999__|${HOST_PORT_9999}|g;
        s|__HAPROXY_STATS_USER__|${HAPROXY_STATS_USER}|g;
        s|__HAPROXY_STATS_PASS__|${HAPROXY_STATS_PASS}|g;
        s|__HOST_PORT_80__|${HOST_PORT_80}|g;
        s|__HOST_PORT_443__|${HOST_PORT_443}|g;
        s|__HA_SERVICE_IP__|${HA_SERVICE_IP}|g;
        s|__HA_SERVICE_PORT__|${HA_SERVICE_PORT}|g;
        s|__CERT_DOMAIN_STRING__|${CERT_DOMAIN}|g; 
        s|__LOG_LEVEL__|${LOG_LEVEL}|g;
    " > "${FINAL_CONFIG}.tmp"
mv "${FINAL_CONFIG}.tmp" "${FINAL_CONFIG}"

bashio::log.info "haproxy.cfg generated successfully."

# -----------------------------------------------------------------------------
# 3. CERTIFICATE LOGIC (Self-Signed & Let's Encrypt)
# -----------------------------------------------------------------------------

# Generate self-signed certificate if it doesn't exist
if [ ! -f "${DEFAULT_PEM}" ]; then
    bashio::log.info "Generating self-signed certificate..."
    
    # Use temporary files for keys/certs
    TEMP_DIR=/tmp
    KEY=${TEMP_DIR}/haproxy_key.pem
    CERT=${TEMP_DIR}/haproxy_cert.pem
    SUBJ="/C=US/ST=somewhere/L=someplace/O=haproxy/OU=haproxy/CN=haproxy.selfsigned.invalid"
    
    # Generate key and CSR without passwords and combine them in a single pipe (faster/cleaner)
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${KEY}" -out "${CERT}" \
        -subj "${SUBJ}" &>/dev/null
    
    cat "${CERT}" "${KEY}" > "${DEFAULT_PEM}"
    rm -f "${KEY}" "${CERT}"
fi

# Check for existing Certbot setup and run if necessary
if bashio::config.has_value 'cert_domain'; then
    FULLCHAIN_PATH="${CERTBOT_CERT_PATH}/fullchain.pem"
    
    # Check if certificate exists (for renewal check or initial skip)
    if [ -f "${FULLCHAIN_PATH}" ]; then
        bashio::log.info "Existing certificate found. HAProxy will handle renewal."
    
    # Initial request logic
    elif bashio::var.is_empty "${CERT_EMAIL}"; then
        bashio::exit.nok "Certbot is enabled but 'cert_email' is missing."
    
    else
        bashio::log.warning "No existing certificate found. Starting HAProxy temporarily for initial validation..."
        
        # Ensure Certbot directories are ready
        mkdir -p "${CERT_PERSISTENT_DIR}/work" "${CERT_PERSISTENT_DIR}/log"
        
        # 1. Start HAProxy in the background for ACME challenge
        /usr/local/sbin/haproxy -f "${FINAL_CONFIG}" -D -p "${HAPROXY_PID_FILE}" &
        
        # 2. Wait for PID file creation (max 10s)
        for i in {1..10}; do
            [ -f "${HAPROXY_PID_FILE}" ] && break
            sleep 1
        done

        # 3. Process HAProxy PID
        if [ -f "${HAPROXY_PID_FILE}" ]; then
            HAPROXY_PID=$(cat "${HAPROXY_PID_FILE}")
        else
            bashio::log.error "HAProxy failed to start for Certbot validation."
            exit 1 # Exit script if HAProxy failed to start for the critical task
        fi
        
        # 4. Run Certbot
        bashio::log.info "Attempting to obtain certificate for domain: ${CERT_DOMAIN}..."
        if /usr/bin/certbot-certonly \
            --config-dir "${CERT_PERSISTENT_DIR}" \
            --work-dir "${CERT_PERSISTENT_DIR}/work" \
            --logs-dir "${CERT_PERSISTENT_DIR}/log" \
            --email "${CERT_EMAIL}" \
            --domains "${CERT_DOMAIN}" --non-interactive --webroot --webroot-path /var/www/html; then # Assuming webroot or standalone are configured
            bashio::log.info "Certificate successfully obtained! Running refresh..."
            haproxy-refresh
        else
            bashio::log.error "Certbot certificate request failed. HAProxy will use self-signed."
        fi
        
        # 5. Stop the temporary HAProxy instance
        bashio::log.info "Stopping temporary HAProxy (PID ${HAPROXY_PID})."
        kill "${HAPROXY_PID}" 2>/dev/null || bashio::log.warning "Temporary HAProxy was already stopped."
    fi
fi

# -----------------------------------------------------------------------------
# 4. NETWORKING (IPTABLES / TC SETUP)
# -----------------------------------------------------------------------------

# Find the IP address more reliably
IP=$(ip route get 1.1.1.1 | awk '/src/ {print $7}' | head -n 1)

if [ -n "$IP" ]; then
    /usr/sbin/iptables -t mangle -I OUTPUT -p tcp -s "${IP}" --syn -j MARK --set-mark 1
    
    # TC setup (Combined for efficiency)
    tc qdisc add dev lo root handle 1: prio bands 4
    tc qdisc add dev lo parent 1:1 handle 10: pfifo limit 1000
    tc qdisc add dev lo parent 1:2 handle 20: pfifo limit 1000
    tc qdisc add dev lo parent 1:3 handle 30: pfifo limit 1000
    
    nl-qdisc-add --dev=lo --parent=1:4 --id=40: plug --limit 33554432
    nl-qdisc-add --dev=lo --parent=1:4 --id=40: --update plug --release-indefinite
    tc filter add dev lo protocol ip parent 1:0 prio 1 handle 1 fw classid 1:4
else
    bashio::log.warning "Could not reliably determine IP address for TPROXY setup. Skipping IPTABLES/TC."
fi

# -----------------------------------------------------------------------------
# 5. START SUPERVISOR
# -----------------------------------------------------------------------------
bashio::log.info "Starting HAProxy via Supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
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

bashio::log.info "Preparing to start..."

bashio::log.info "Waiting 1 seconds for Supervisor to initialize API token..."
sleep 1

# --- REQUIRE CORE OPTIONS ---
bashio::config.require 'data_path'

# --- DEFINE CONSTANTS & VARIABLES ---
DATA_PATH="$(bashio::config 'data_path')"
HA_PROXY_DIR=/usr/local/etc/haproxy
TEMP_DIR=/tmp

PASSWORD=$(openssl rand -base64 32)
SUBJ="/C=US/ST=somewhere/L=someplace/O=haproxy/OU=haproxy/CN=haproxy.selfsigned.invalid"

KEY=${TEMP_DIR}/haproxy_key.pem
CERT=${TEMP_DIR}/haproxy_cert.pem
CSR=${TEMP_DIR}/haproxy.csr
DEFAULT_PEM=${HA_PROXY_DIR}/default.pem
CONFIG=/app/haproxy.cfg


# --- SETUP ENV VARIABLES ---
export HA_SERVICE_IP="$(bashio::config 'ha_ip_address')"
export HA_SERVICE_PORT="$(bashio::config 'ha_port')"
export FORCE_HTTPS_REDIRECT="$(bashio::config 'force_redirect')"
export HAPROXY_DATA="$(bashio::config 'data_path')"
export HAPROXY_STATS_USER="$(bashio::config 'stats_user')"
export HAPROXY_STATS_PASS="$(bashio::config 'stats_password')"
CERT_EMAIL="$(bashio::config 'cert_email')"
CERT_DOMAIN="$(bashio::config 'cert_domain')"
CERTBOT_CERT_PATH="/etc/letsencrypt/live/${CERT_DOMAIN}"

# Export internal ports (must match 'ports' in config.yaml)
export HTTP_PORT="80"
export HTTPS_PORT="443"

# bashio::addon.port is for external (host) port mapping, not for internal binds.
export HOST_PORT_80=$(bashio::addon.port 80)
export HOST_PORT_443=$(bashio::addon.port 443)
export HOST_PORT_9999=$(bashio::addon.port 9999)

bashio::log.info "Host port for HTTP (internal 80) is: ${HOST_PORT_80}"
bashio::log.info "Host port for HTTPS (internal 443) is: ${HOST_PORT_443}"
bashio::log.info "Host port for HAProxy Stats (internal 9999) is: ${HOST_PORT_9999}"
bashio::log.info "HAProxy stats user set to: ${HAPROXY_STATS_USER}"

# --- HAProxy CONFIG SETUP ---
mkdir -p "$HAPROXY_DATA" || bashio::exit.nok "Could not create $HAPROXY_DATA"
# Check if config file for haproxy exists
if [ ! -e ${HAPROXY_DATA}/haproxy.cfg ]; then
  if [ ! -e ${CONFIG} ]; then
    bashio::exit.nok "${CONFIG} not found"
  fi;
  cp ${CONFIG} ${HAPROXY_DATA}/haproxy.cfg
  bashio::log.info "Using configuration file at ${HAPROXY_DATA}/haproxy.cfg"
fi

# --- CERTIFICATE LOGIC ---

# Check if a valid Let's Encrypt certificate already exists for the first domain.
if bashio::config.has_value 'cert_domains' && [ -d "${CERTBOT_CERT_PATH}" ]; then
    bashio::log.info "Let's Encrypt certificate directory found: ${CERTBOT_CERT_PATH}"
elif bashio::config.has_value 'cert_domains'; then
    bashio::log.warning "No existing Let's Encrypt certificate found. Requesting new one..."  

    # Check for required certbot values
    if bashio::var.is_empty "${CERT_EMAIL}" || bashio::var.is_empty "${CERT_DOMAIN}"; then
        bashio::exit.nok "Certbot is enabled but 'cert_email' or 'cert_domains' is missing."
    fi

    bashio::log.info "Attempting to obtain certificate for domain: ${CERT_DOMAIN}"

    # Run certbot to get certificate (using the custom wrapper script)
    if ! /usr/bin/certbot-certonly \
        --email "${CERT_EMAIL}" \
        --domains "${CERT_DOMAIN}"; then
        bashio::log.error "Certbot certificate request failed. Falling back to self-signed."
    else
        bashio::log.info "Certificate successfully obtained!"
    fi
fi

# Create default.pem if no valid certificate exists (or if certbot failed)
# Note: This file is required by HAProxy bind statement to start.
if [ ! -e "${DEFAULT_PEM}" ]; then
    bashio::log.info "Creating temporary self-signed default.pem."
    openssl genrsa -des3 -passout pass:${PASSWORD} -out ${KEY} 2048 &> /dev/null
    openssl req -new -key ${KEY} -passin pass:${PASSWORD} -out ${CSR} -subj ${SUBJ} &> /dev/null
    cp ${KEY} ${KEY}.org &> /dev/null
    openssl rsa -in ${KEY}.org -passin pass:${PASSWORD} -out ${KEY} &> /dev/null
    openssl x509 -req -days 3650 -in ${CSR} -signkey ${KEY} -out ${CERT} &> /dev/null
    cat ${CERT} ${KEY} > ${DEFAULT_PEM}
    echo ${PASSWORD} > /password.txt
fi

# --- IPTABLES / TC SETUP (Networking) --- 

# Get the IP address of the default route's interface
INTERFACE_NAME=$(ip route | awk '/default/ {print $5}' | head -n 1)
IP=$(ip addr show $INTERFACE_NAME | awk '/inet / {print $2}' | cut -d/ -f1)

# Fallback: Use 'ip' to find the first non-localhost IP
if [ -z "$IP" ]; then
    IP=$(ip route get 1.1.1.1 | awk '/src/ {print $7}' | head -n 1)
fi

# Note: Using /usr/sbin/iptables is safer than just 'iptables'
/usr/sbin/iptables -t mangle -I OUTPUT -p tcp -s ${IP} --syn -j MARK --set-mark 1

# Set up the queuing discipline (Traffic Control for TProxy)
tc qdisc add dev lo root handle 1: prio bands 4
tc qdisc add dev lo parent 1:1 handle 10: pfifo limit 1000
tc qdisc add dev lo parent 1:2 handle 20: pfifo limit 1000
tc qdisc add dev lo parent 1:3 handle 30: pfifo limit 1000

# Create a plug qdisc with 32 meg of buffer
nl-qdisc-add --dev=lo --parent=1:4 --id=40: plug --limit 33554432
# Release the plug
nl-qdisc-add --dev=lo --parent=1:4 --id=40: --update plug --release-indefinite

# Set up the filter
tc filter add dev lo protocol ip parent 1:0 prio 1 handle 1 fw classid 1:4

# --- START SUPERVISOR ---
bashio::log.info "Starting HAProxy..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf

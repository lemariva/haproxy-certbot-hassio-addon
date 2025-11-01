#!/usr/bin/with-contenv bashio
#
# Copyright [2025] [LeMaRiva Tech]

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

bashio::log.info "Preparing to start..."

bashio::log.info "Waiting 5 seconds for Supervisor to initialize API token..."
sleep 5

bashio::config.require 'data_path'

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

# setup env variables
export HA_SERVICE_IP="$(bashio::config 'ha_ip_address')"
export HA_SERVICE_PORT="$(bashio::config 'ha_port')"
export FORCE_HTTPS_REDIRECT="$(bashio::config 'force_redirect')"
export HAPROXY_DATA="$(bashio::config 'data_path')"
export HAPROXY_STATS_USER="$(bashio::config 'stats_user')"
export HAPROXY_STATS_PASS="$(bashio::config 'stats_password')"

bashio::log.info "HAProxy stats user set to: ${HAPROXY_STATS_USER}"

mkdir -p "$HAPROXY_DATA" || bashio::exit.nok "Could not create $HAPROXY_DATA"

# Check if config file for haproxy exists
if [ ! -e ${CONFIG} ]; then
  bashio::exit.nok "${CONFIG} not found"
else
  if [ ! -e ${HAPROXY_DATA}/haproxy.cfg ]; then
    cp ${CONFIG} ${HAPROXY_DATA}/haproxy.cfg
  fi;
  bashio::log.info "Using configuration file at ${HAPROXY_DATA}/haproxy.cfg"
fi

# Check if default.pem has been created
if [ ! -e ${DEFAULT_PEM} ]; then
  openssl genrsa -des3 -passout pass:${PASSWORD} -out ${KEY} 2048 &> /dev/null
  openssl req -new -key ${KEY} -passin pass:${PASSWORD} -out ${CSR} -subj ${SUBJ} &> /dev/null
  cp ${KEY} ${KEY}.org &> /dev/null
  openssl rsa -in ${KEY}.org -passin pass:${PASSWORD} -out ${KEY} &> /dev/null
  openssl x509 -req -days 3650 -in ${CSR} -signkey ${KEY} -out ${CERT} &> /dev/null
  cat ${CERT} ${KEY} > ${DEFAULT_PEM}
  echo ${PASSWORD} > /password.txt
fi

# Get the IP address of the default route's interface
INTERFACE_NAME=$(ip route | awk '/default/ {print $5}' | head -n 1)
IP=$(ip addr show $INTERFACE_NAME | awk '/inet / {print $2}' | cut -d/ -f1)

# Fallback: Use 'ip' to find the first non-localhost IP
if [ -z "$IP" ]; then
    IP=$(ip route get 1.1.1.1 | awk '/src/ {print $7}' | head -n 1)
fi

/usr/sbin/iptables -t mangle -I OUTPUT -p tcp -s ${IP} --syn -j MARK --set-mark 1

# Set up the queuing discipline
tc qdisc add dev lo root handle 1: prio bands 4
tc qdisc add dev lo parent 1:1 handle 10: pfifo limit 1000
tc qdisc add dev lo parent 1:2 handle 20: pfifo limit 1000
tc qdisc add dev lo parent 1:3 handle 30: pfifo limit 1000

# Create a plug qdisc with 32 meg of buffer
nl-qdisc-add --dev=lo --parent=1:4 --id=40: plug --limit 33554432
# Release the plug
nl-qdisc-add --dev=lo --parent=1:4 --id=40: --update plug --release-indefinite

# Set up the filter, any packet marked with "1" will be
# directed to the plug
tc filter add dev lo protocol ip parent 1:0 prio 1 handle 1 fw classid 1:4

# Run Supervisor
bashio::log.info "Starting HAProxy..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf

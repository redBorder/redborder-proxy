#!/bin/bash

#######################################################################
# Copyright (c) 2014 ENEO Tecnología S.L.
# This file is part of redBorder.
# redBorder is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# redBorder is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License License for more details.
# You should have received a copy of the GNU Affero General Public License License
# along with redBorder. If not, see <http://www.gnu.org/licenses/>.
#######################################################################

FORCE=0
CUSTOM_MAC=""

function usage(){
	echo "Usage: $0 [-f] [-m <mac>] [-h]"
	echo "    -f -> force clean and regenerate (do not prompt)"
	echo "    -m -> custom MAC address (e.g. 00:11:22:33:44:55)"
	echo "    -h -> print this help"
	exit 2
}

while getopts "fm:h" opt; do
  case $opt in
    f) FORCE=1;;
    m) CUSTOM_MAC="$OPTARG";;
    h) usage;;
    *) usage;;
  esac
done

VAR="y"

if [ $FORCE -eq 0 ]; then
  echo -n "Are you sure you want to clean and regenerate NMSP keys? (y/N) "
  read VAR
fi

if [ "x$VAR" == "xy" -o "x$VAR" == "xY" ]; then
  # Clean up existing keys
  rm -f /etc/redborder-nmsp/aes.keystore /etc/redborder-nmsp/nmspd-key-hashes.json

  if [ -n "$CUSTOM_MAC" ]; then
    NMSPMAC="$CUSTOM_MAC"
  else
    DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [ -n "$DEFAULT_IFACE" ] && [ -f "/sys/class/net/$DEFAULT_IFACE/address" ]; then
      NMSPMAC=$(cat "/sys/class/net/$DEFAULT_IFACE/address")
    else
      NMSPMAC=$(ip a | grep link/ether | head -n 1 | awk '{print $2}')
    fi
  fi

  if [ -z "$NMSPMAC" ]; then
    NMSPMAC="$(< /dev/urandom tr -dc a-f0-9 | head -c2 | sed 's/ //g'):$(< /dev/urandom tr -dc a-f0-9 | head -c2 | sed 's/ //g'):$(< /dev/urandom tr -dc a-f0-9 | head -c2 | sed 's/ //g'):$(< /dev/urandom tr -dc a-f0-9 | head -c2 | sed 's/ //g'):$(< /dev/urandom tr -dc a-f0-9 | head -c2 | sed 's/ //g'):$(< /dev/urandom tr -dc a-f0-9 | head -c2 | sed 's/ //g')"
  fi

  # Ensure destination directory exists
  mkdir -p /etc/redborder-nmsp/

  SUCCESS=0
  RB_BIN=""
  if [ -x /usr/bin/rb-nmsp ]; then
    RB_BIN="/usr/bin/rb-nmsp"
  elif command -v rb-nmsp &>/dev/null; then
    RB_BIN="$(command -v rb-nmsp)"
  fi

  if [ -n "$RB_BIN" ]; then
    "$RB_BIN" config-gen /etc/redborder-nmsp/ /etc/redborder-nmsp/ "$NMSPMAC"
    if [ $? -eq 0 ]; then
      SUCCESS=1
    fi
  elif [ -f /usr/lib/redborder-nmsp/rb-nmsp.jar ]; then
    java -cp /usr/lib/redborder-nmsp/deps/*:/usr/lib/redborder-nmsp/rb-nmsp.jar net.redborder.nmsp.NmspConsumer config-gen /etc/redborder-nmsp/ /etc/redborder-nmsp/ "$NMSPMAC"
    if [ $? -eq 0 ]; then
      SUCCESS=1
    fi
  fi

  if [ $SUCCESS -eq 1 ]; then
    # Set proper permissions for redborder-nmsp service user
    if getent passwd redborder-nmsp >/dev/null 2>&1; then
      chown -R redborder-nmsp:redborder-nmsp /etc/redborder-nmsp 2>/dev/null || true
    fi
    chmod 0750 /etc/redborder-nmsp 2>/dev/null || true
    chmod 0640 /etc/redborder-nmsp/aes.keystore /etc/redborder-nmsp/nmspd-key-hashes.json 2>/dev/null || true

    # Restart service if active
    if systemctl is-active --quiet redborder-nmsp 2>/dev/null; then
      systemctl restart redborder-nmsp
    fi

    # Display authorization banner
    HASHES_FILE="/etc/redborder-nmsp/nmspd-key-hashes.json"

    if [ -f "$HASHES_FILE" ]; then
      MAC=$(grep -o '"macAddress": *"[^"]*"' "$HASHES_FILE" | cut -d'"' -f4)
      SHA2=$(grep -o '"sha2KeyHashHex": *"[^"]*"' "$HASHES_FILE" | cut -d'"' -f4)
      SHA1=$(grep -o '"keyHashHex": *"[^"]*"' "$HASHES_FILE" | cut -d'"' -f4)

      echo ""
      echo "=========================================================================="
      echo "                     NMSP Authorization Details                           "
      echo "=========================================================================="
      echo "MAC Address:     $MAC"
      echo "SHA-256 Hash:    $SHA2"
      echo "SHA-1 Hash:      $SHA1"
      echo ""
      echo "Command to run on Cisco WLC CLI:"
      echo "  config auth-list add sha256-fingerprint $MAC $SHA2"
      echo "=========================================================================="
      echo ""
    fi
  else
    echo "ERROR: Failed to regenerate NMSP keys."
    exit 1
  fi
fi


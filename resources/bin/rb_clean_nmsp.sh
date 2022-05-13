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

function usage(){
	echo "ERROR: $0 [-f] [-h] "
  	echo "    -f -> force delete (not ask)"
  	echo "    -h -> print this help"
	exit 2
}

while getopts "fh" opt; do
  case $opt in
    f) FORCE=1;;
    h) usage;;
  esac
done

VAR="y"

if [ $FORCE -eq 0 ]; then
  echo -n "Are you sure you want to clean and regenerate nmsp keys? (y/N) "
  read VAR
fi

if [ "x$VAR" == "xy" -o "x$VAR" == "xY" ]; then
  rm -f /etc/nmspd/aes.keystore /etc/nmspd/nmspd-key-hashes.json
  if [ -f /var/nmspd/app/nmsp.jar -a ! -f /etc/nmspd/aes.keystore ]; then
    NMSPMAC=$(ip a | grep link/ether | tail -n 1 | awk '{print $2}')
    if [ "x$NMSPMAC" == "x" ]; then
      NMSPMAC="$(< /dev/urandom tr -dc a-f0-9 | head -c2 | sed 's/ //g'):$(< /dev/urandom tr -dc a-f0-9 | head -c2 | sed 's/ //g'):$(< /dev/urandom tr -dc a-f0-9 | head -c2 | sed 's/ //g'):$(< /dev/urandom tr -dc a-f0-9 | head -c2 | sed 's/ //g'):$(< /dev/urandom tr -dc a-f0-9 | head -c2 | sed 's/ //g'):$(< /dev/urandom tr -dc a-f0-9 | head -c2 | sed 's/ //g'):"
    fi
    rm -f /etc/nmspd/aes.keystore
    rm -f /etc/nmspd/nmspd-key-hashes.json
    java -cp /var/nmspd/app/deps/*:/var/nmspd/app/nmsp.jar net.redborder.nmsp.NmspConsumer config-gen /etc/nmspd/ /etc/nmspd/ $NMSPMAC
  fi
fi


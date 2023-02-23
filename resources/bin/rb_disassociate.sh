
FORCE=0
RET=0
DELETE="/etc/chef/client.pem /etc/motd /etc/sudoers.d/redBorder /etc/n2klocd/config.json /etc/nprobe/config.json /etc/sysconfig/iptables /etc/sysconfig/nprobe /etc/chef/role.json /etc/chef/role-once.json /etc/raddb/clients.conf /etc/raddb/kafka_log.conf /etc/raddb/radiusd.conf /etc/rb-social/config.yml /etc/mosquitto/conf.d/ /etc/mosquitto/mosquitto.conf /etc/chef/rb-register.db /tmp/kafka /tmp/zookeeper /var/log/rb-register/finish.log /etc/sysconfig/arpwatch /etc/pmacctd.conf /etc/rb-exporter/* /etc/logstash/pipelines.yml /share/bulkstats.tar.gz /var/rb-scanner-request/conf/"


source /usr/lib/redborder/lib/rb_functions.sh

function usage(){
	echo "ERROR: $0 [-f] [-h] "
  	echo "    -f -> force delete (not ask)"
  	echo "    -h -> print this help"
	exit 2
}

logger -t "rb_disassociate_sensor" "Deleting proxy"

while getopts "fh" opt; do
  case $opt in
    f) FORCE=1;;
    h) usage;;
  esac
done

VAR="y"

if [ $FORCE -eq 0 ]; then
  echo -n "Are you sure you want to disassociate this proxy from the manager? (y/N) "
  read VAR
fi

if [ "x$VAR" == "xy" -o "x$VAR" == "xY" ]; then
  e_title "Stopping services"
  /usr/lib/redborder/bin/rb_clean_zookeeper.sh -kfl
  ds_services_stop="chef-client f2k n2klocd redborder-monitor"
  systemctl stop $ds_services_stop

  e_title "Deleting files"
  for n in $DELETE; do
    echo "Deleting $n"
    rm -rf $n
  done
  touch /etc/sysconfig/iptables
  touch /etc/force_create_topics

  e_title "Generating new uuid"
  cat /proc/sys/kernel/random/uuid > /etc/rb-uuid

  e_title "Generating new nmsp certs"
  /usr/lib/redborder/bin/rb_clean_nmsp.sh -f

  e_title "Starting registration daemons"
  rm /etc/sysconfig/rb-register
  cp /etc/sysconfig/rb-register.default /etc/sysconfig/rb-register

  e_title "Pushing hash from rb-uuid to rb-register"
  echo HASH=\"$(cat /etc/rb-uuid)\" >> /etc/sysconfig/rb-register 

  e_title "Disassociate finished. Please use rb_setup_wizard to register this machine again"
fi

exit $RET
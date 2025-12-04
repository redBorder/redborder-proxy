source /usr/lib/redborder/lib/rb_functions.sh

force=0
consumersdata=0
startservices=1
kafkaclean=0
ds_services_stop="chef-client f2k n2klocd redborder-monitor"
ds_services_start="zookeeper kafka k2http f2k rb-sociald rb-snmp nmspd n2klocd freeradius redborder-monitor chef-client sfacctd logstash redborder-ale redborder-scanner"

function usage() {
  echo "rb_clean_zookeeper.sh [-h][-f][-c][-l][-k]"
  echo " -h -> print this help"
  echo " -l -> do not start services at the end"
  echo " -c -> clean kafka consumers data in zookeeper"
  echo " -k -> clean kafka information too"
  echo " -f -> do not ask"
  exit 0
}

function clean_consumers() {
  local path="/consumers"
  response=$(/usr/bin/zkCli.sh -server localhost:2181 ls /consumers 2>/dev/null | grep '^\[.*\]$')

  # Remove brackets, split by comma, and trim whitespace
  IFS=',' read -ra children <<< "${response#[}"
  for child in "${children[@]}"; do
    child="${child%]}"
    child="$(echo "$child" | xargs)"  # Trim whitespace
    [[ -n "$child" ]] && echo "Deleting: $path/$child"
    /usr/bin/zkCli.sh -server localhost:2181 delete $path/$child 2>/dev/null | grep '^\[.*\]$'
  done
}

while getopts "fydschlk" name
do
  case $name in
    f) force=1;;
    y) force=1;;
    c) consumersdata=1;;
    l) startservices=0;;
    k) kafkaclean=1;;
    h) usage;;
  esac
done

if [ $force -eq 0 ]; then
  echo -n "Are you sure you want to clean zookeeper data (y/N)? "
  read VAR
else
  VAR="y"
fi

if [ "x$VAR" == "xy" -o "x$VAR" == "xY" ]; then
  systemctl stop $ds_services_stop

  if [ $consumersdata -eq 0 ]; then
    e_title "Deleting all zookeeper data"
    rm -rf /tmp/zookeeper/version-2/*

    if [ $kafkaclean -eq 1 ]; then
      e_title "Deleting all kafka data"
      rm -rf /tmp/kafka/*
    fi

    if [ $startservices -eq 1 ]; then
      systemctl start zookeeper
      sleep 5
      systemctl start kafka
      sleep 5
      /usr/lib/redborder/bin/rb_create_topics | grep -v 'Due to limitations in metric names'
    fi
  else
    systemctl start zookeeper
    e_title "Deleting specific zookeeper data"
    clean_consumers
  fi

  if [ $startservices -eq 1 ]; then
    systemctl start $ds_services_start
  fi
fi

source /usr/lib/redborder/lib/rb_functions.sh

force=0
consumersdata=0
startservices=1
kafkaclean=0
ds_services_stop="chef-client f2k n2klocd redborder-monitor"

function usage() {
  echo "rb_clean_zookeeper.sh [-h][-f][-c][-l][-k]"
  echo " -h -> print this help"
  echo " -l -> do not start services at the end"
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

function start_services() {
  local ds_services_start="zookeeper kafka k2http f2k n2klocd redborder-monitor chef-client sfacctd logstash redborder-ale redborder-scanner"

  # Cache available services
  local systemctl_services=$(systemctl list-unit-files --no-pager --no-legend | awk '{print $1}')
  local rbcli_services=$(rbcli service list | awk '{print $1}')

  for service_name in $ds_services_start; do
    if echo "$systemctl_services" | grep -qw "^$service_name"; then
      # Try to start the service
      if systemctl start "$service_name"; then
        echo "Service '$service_name' started successfully."
      else
        echo "Failed to start '$service_name'. Please check the service logs."
      fi
    elif echo "$rbcli_services" | grep -qw "^$service_name"; then
      echo "Info: Service '$service_name' exists in rbcli but is not enabled in systemctl. Please enable it first."
    else
      echo "Error: Service '$service_name' not found in systemctl or rbcli."
    fi
  done
}

while getopts "fydschlk" name

do
  case $name in
    f) force=1;;
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
      rb_create_topics.sh | grep -v 'Due to limitations in metric names'
    fi
  else
    systemctl start zookeeper
    e_title "Deleting specific zookeeper data"
    clean_consumers
  fi

  if [ $startservices -eq 1 ]; then
    start_services
  fi
fi

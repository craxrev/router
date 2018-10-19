#!/opt/bin/bash
#
# Script for calculating the up/down speed a chosen subnetwork clients
#
#

# Refresh rate of the calculation (does not effect the calculation itself), default to 1 second
REFRESH_RATE="$1"
if [ -z "$REFRESH_RATE" ];
then
  REFRESH_RATE=1000000
fi

# LAN configs
LAN_IFACE="br0"
LAN_TYPE="192.168.31"

# Make sure one instance is running
# if [ -f /tmp/traffic_monitor.lock ];
# then
#   if [ ! -d /proc/$(cat /tmp/traffic_monitor.lock) ]; then
#     echo "WARNING : Lockfile detected but process $(cat /tmp/traffic_monitor.lock) does not exist. Reinitialising lock file!"
#     rm -f /tmp/traffic_monitor.lock
#   else
#     echo "WARNING : Process is already running as $(cat /tmp/traffic_monitor.lock), aborting!"
#     exit
#   fi
# fi
# 
# echo $$ > /tmp/traffic_monitor.lock
echo "Monitoring network ${LAN_TYPE}.255"

declare -A IPS

start=`awk 'NR==3 {print $3}' /proc/timer_list`

while :
do
  #Create the RRDIPT CHAIN (it doesn't matter if it already exists).
  iptables -N RRDIPT 2> /dev/null

  #Add the RRDIPT CHAIN to the FORWARD chain (if non existing).
  iptables -L FORWARD --line-numbers -n | grep "RRDIPT" | grep "1" > /dev/null
  if [ $? -ne 0 ]; then
    iptables -L FORWARD -n | grep "RRDIPT" > /dev/null
    if [ $? -eq 0 ]; then
      iptables -D FORWARD -j RRDIPT
    fi
  iptables -I FORWARD -j RRDIPT
  fi

  #For each host in the ARP table
  grep ${LAN_TYPE} /proc/net/arp | while read IP TYPE FLAGS MAC MASK IFACE
  do
    #Add iptable rules (if non existing).
    iptables -nL RRDIPT | grep "${IP}[[:space:]]" > /dev/null
    if [ $? -ne 0 ]; then
      iptables -I RRDIPT -d ${IP} -j RETURN
      iptables -I RRDIPT -s ${IP} -j RETURN
    fi
  done
  
  TRAFFIC=$(iptables -L RRDIPT -vnx -t filter | grep ${LAN_TYPE} | awk '{ if (NR % 2 == 1) printf "'%s' '%s' ",$8,$2; else printf "'%s'\n",$2;}')
  
  end=`awk 'NR==3 {print $3}' /proc/timer_list`
  
  runtime=$(( end - start )) # in microseconds
  millisec=$(( $runtime/1000000 ))
  
  start=$end
  
  printf "\033c"
  clear
  
  while read IP UP DL
  do
    if [[ -v "IPS[$IP]" ]] ; then
      OLD_UP=`echo ${IPS[$IP]} | cut -d' ' -f1`
      OLD_DL=`echo ${IPS[$IP]} | cut -d' ' -f2`
      
      DIFF_UP=$(($UP - $OLD_UP))
      DIFF_DL=$(($DL - $OLD_DL))
      
      DIFF_UP=$(($DIFF_UP / $millisec))
      DIFF_DL=$(($DIFF_DL / $millisec))
      
      echo "$IP: ${DIFF_UP}K ${DIFF_DL}K"
      IPS[$IP]="$UP $DL"
    else
        IPS[$IP]="$UP $DL"
    fi
  done <<< "$TRAFFIC"
  
  usleep $REFRESH_RATE
  #sleep $REFRESH_RATE
done
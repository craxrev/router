#!/bin/ash
# a simple mac based clients blocker
# V1
# Using iptables

# Network interface
IF=br-lan

# IMPORTANT PLEASE SET A VALID MAC ADDRESS
ADMIN_MAC='xx:xx:xx:xx:xx:xx'


start() {

	if ! [ -z $ADMIN_MAC ] && [ ${#ADMIN_MAC} -eq 17 ] && cat /proc/net/arp | grep br-lan | grep -q $ADMIN_MAC; then

		cat /proc/net/arp | grep $IF | awk '{ print $1,$2,$4 }' | tr -d '()' | while read -r line ; do

			IP=`echo $line | awk '{ print $1}'`
			MAC=`echo $line | awk '{ print $3}'`

			if [ "$MAC" != "$ADMIN_MAC" ]; then
				echo "Blocking $IP"
				iptables -I FORWARD -m mac --mac-source $MAC -j DROP
			fi

		done

	else

		printf "Aborted! one of these problems found:\n-The Admin mac is not found in your network\n-Incorrect/invalid MAC address\n"

	fi

}

stop(){

	iptables -L | grep MAC | awk '{ print $7 }' | tr -d '()' | while read -r line ; do

		MAC=`echo $line`
		iptables -D FORWARD -m mac --mac-source $MAC -j DROP

	done

}

show(){

	if iptables -L | grep -q MAC; then

		iptables -L | grep MAC

	else

		echo "Selfishness not active"

	fi

}


case "$1" in

	start)

		echo "Starting selfishness.."
		stop
		start
		echo "Starting selfishness: Done"
		;;

	stop)

		echo "Stopping selfishness.."
		stop
		echo "Stopping selfishness: Done"
		;;

	show)

		echo ""
		show
		echo ""
		;;

	*)

		pwd=$(pwd)
		echo "Usage: selfish.sh {start|stop|show}"
		;;

esac

exit 0
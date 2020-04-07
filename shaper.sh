#!/bin/ash
# a QoS script for OpenWrt based routers
# V2
# Using Hierarchical Token Bucket (HTB) to shape bandwidth.

# Loading QoS variables
. ./qos.cfg

start() {

    if [ $WITH_BORROWING == true ]; then
        echo "Strict bandwidth usage disabled"
    else
        echo "Strict bandwidth usage enabled"
    fi

    if [ $LIMIT_UPLOAD == true ]; then
        # Load ifb QoS modules
        [ -z "$(lsmod | grep ifb)" ] && modprobe ifb numifbs=1

        # Init virtual interface
        ip link set dev $FI up
    else
        echo "Upload filtering disabled"
    fi

    # Sharing bandwidth across AP clients

    CLTS=$(cat /proc/net/arp | grep br-lan | awk '{ print $1,$2,$4 }' | tr -d '()' | grep -v '$ADMIN_MAC' | wc -l)

    CEIL_DNLD=`echo $CEIL | awk '{ print $1}'`
    CEIL_UPLD=`echo $CEIL | awk '{ print $2}'`

    CLTS_DNLD_SHARE=$(( CEIL_DNLD * CLTS_PERC / 100 ))
    CLTS_UPLD_SHARE=$(( CEIL_UPLD * CLTS_PERC / 100 ))

    CLTS_DEFAULT_DNLD=$(( CLTS_DNLD_SHARE / CLTS ))
    CLTS_DEFAULT_UPLD=$(( CLTS_UPLD_SHARE / CLTS ))

    RESERVED_DNLD=$(( CEIL_DNLD * RESERVED_PERC / 100 ))
    RESERVED_UPLD=$(( CEIL_UPLD * RESERVED_PERC / 100 ))

    ADMIN_DNLD=$(( CEIL_DNLD - CLTS_DNLD_SHARE - RESERVED_DNLD))
    ADMIN_UPLD=$(( CEIL_UPLD - CLTS_UPLD_SHARE - RESERVED_UPLD))

    # Prepare download shapers
    $TC qdisc add dev $IF root handle $DLHNDL: htb
    $TC class add dev $IF parent $DLHNDL: classid $DLHNDL:1 htb rate ${CEIL_DNLD}kbps burst 8kbit cburst 8k

    $TC class add dev $IF parent $DLHNDL:1 classid $DLHNDL:10 htb rate ${RESERVED_DNLD}kbps `if [ $WITH_BORROWING == true ]; then echo "ceil ${CEIL_DNLD}kbps burst 8kbit cburst 8kbit prio 1"; fi`
    $TC qdisc add dev $IF parent $DLHNDL:10 handle ${DLHNDL}10: `echo $QUEUE_METHOD`

    $TC class add dev $IF parent $DLHNDL:1 classid $DLHNDL:20 htb rate ${ADMIN_DNLD}kbps `if [ $WITH_BORROWING == true ]; then echo "ceil ${CEIL_DNLD}kbps burst 4kbit cburst 1kbit prio 2"; fi`
    $TC qdisc add dev $IF parent $DLHNDL:20 handle ${DLHNDL}20: `echo $QUEUE_METHOD`

    $TC class add dev $IF parent $DLHNDL:1 classid $DLHNDL:30 htb rate ${CLTS_DEFAULT_DNLD}kbps `if [ $WITH_BORROWING == true ]; then echo "ceil ${CEIL_DNLD}kbps burst 2kbit cburst 1kbit prio 3"; fi`
    $TC qdisc add dev $IF parent $DLHNDL:30 handle ${DLHNDL}30: `echo $QUEUE_METHOD`

    if [ $LIMIT_UPLOAD == true ]; then
        # Prepare upload shapers
        $TC qdisc add dev $IF handle ffff: ingress
        $TC filter add dev $IF parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev $FI
        $TC qdisc add dev $FI root handle $UPHNDL: htb
        $TC class add dev $FI parent $UPHNDL: classid $UPHNDL:1 htb rate ${CEIL_UPLD}kbps

        $TC class add dev $FI parent $UPHNDL:1 classid $UPHNDL:10 htb rate ${RESERVED_UPLD}kbps `if [ $WITH_BORROWING == true ]; then echo "ceil ${CEIL_UPLD}kbps prio 1"; fi`
        #$TC qdisc add dev $FI parent $UPHNDL:10 handle ${UPHNDL}10: `echo $QUEUE_METHOD`

        $TC class add dev $FI parent $UPHNDL:1 classid $UPHNDL:20 htb rate ${ADMIN_UPLD}kbps  `if [ $WITH_BORROWING == true ]; then echo "ceil ${CEIL_UPLD}kbps prio 2"; fi`
        #$TC qdisc add dev $FI parent $UPHNDL:20 handle ${UPHNDL}20: `echo $QUEUE_METHOD`

        $TC class add dev $FI parent $UPHNDL:1 classid $UPHNDL:30 htb rate ${CLTS_DEFAULT_UPLD}kbps  `if [ $WITH_BORROWING == true ]; then echo "ceil ${CEIL_UPLD}kbps prio 3"; fi`
        #$TC qdisc add dev $FI parent $UPHNDL:30 handle ${UPHNDL}30: `echo $QUEUE_METHOD`
    fi

    if [ $ICMP_PRIO == true ]; then

        echo "ICMP prioritization enabled"

        if [ $LIMIT_UPLOAD == true ]; then
            echo "Using reserved bandwidth : setting DNLD to ${RESERVED_DNLD}kbps, UPLD to ${RESERVED_UPLD}kbps"
        else
            echo "Using reserved bandwidth : setting DNLD to ${RESERVED_DNLD}kbps"
        fi

        # Filter icmq packets
        $TC filter add dev $IF protocol ip parent $DLHNDL: prio 10 u32 \
                match ip protocol 1 0xff \
                flowid $DLHNDL:10

        # Filter ACK packets
        $TC filter add dev $IF protocol ip parent $DLHNDL: prio 11 u32 \
                match ip protocol 6 0xff \
                match u8 0x05 0x0f at 0 \
                match u16 0x0000 0xffc0 at 2 \
                match u8 0x10 0xff at 33 \
                flowid $DLHNDL:10

        # Filter 6000-6100 udp ports
        $TC filter add dev $IF protocol ip parent $DLHNDL: prio 12 u32 \
                match ip protocol 6 0xff \
                match ip sport 6000 0xfff0 \
                flowid $DLHNDL:10
        $TC filter add dev $IF protocol ip parent $DLHNDL: prio 12 u32 \
                match ip protocol 6 0xff \
                match ip sport 6016 0xff80 \
                flowid $DLHNDL:10

        # used this https://serverfault.com/questions/231880/how-to-match-port-range-using-u32-filter
        # to get ports range (6000-6143)
        # TODO: udp filtering

        echo
    fi

    cat /proc/net/arp | grep $IF | awk '{ print $1,$2,$4 }' | tr -d '()' | while read -r line ; do

        IP=`echo $line | awk '{ print $1}'`
        MAC=`echo $line | awk '{ print $3}'`

        #echo $HOSTNAME # TODO: resolve hostname
        echo $IP

        if [ "$MAC" == "$ADMIN_MAC" ]; then

            if [ $LIMIT_UPLOAD == true ]; then
                echo "Admin limit : setting DNLD to ${ADMIN_DNLD}kbps, UPLD to ${ADMIN_UPLD}kbps"
            else
                echo "Admin limit : setting DNLD to ${ADMIN_DNLD}kbps"
            fi

            # Filtering download
            $TC filter add dev $IF protocol ip parent $DLHNDL: prio 20 u32 \
                    match ip dst $IP flowid $DLHNDL:20

            if [ $LIMIT_UPLOAD == true ]; then

                # Filtering upload
                $TC filter add dev $FI protocol ip parent $UPHNDL: prio 21 u32 \
                        match ip src $IP flowid $UPHNDL:20

            fi

        else

            if [ $LIMIT_UPLOAD == true ]; then
                echo "Default limit : setting DNLD to ${CLTS_DEFAULT_DNLD}kbps, UPLD to ${CLTS_DEFAULT_UPLD}kbps"
            else
                echo "Default limit : setting DNLD to ${CLTS_DEFAULT_DNLD}kbps"
            fi

            # Filtering download
            $TC filter add dev $IF protocol ip parent $DLHNDL: prio 30 u32 \
                    match ip dst $IP flowid $DLHNDL:30

            if [ $LIMIT_UPLOAD == true ]; then

                # Filtering upload
                $TC filter add dev $FI protocol ip parent $UPHNDL: prio 31 u32 \
                        match ip src $IP flowid $UPHNDL:30

            fi

        fi
        echo
    done

}

restart(){

    # Self-explanatory.
    stop
    sleep 1
    start

}

stop(){

    # Stop the bandwidth shaping.
    $TC qdisc del dev $IF root

    $TC qdisc del dev $IF handle ffff: ingress
    $TC qdisc del root dev $FI

    # remove virtual interface
    ip link set dev $FI down

    # Unload QoS modules
    rmmod ifb

}

show(){

    # Display status of traffic control status.
    echo '===================================='
    $TC -s qdisc ls dev $IF
    echo '===================================='
    $TC -s class ls dev $IF
    echo '===================================='
    $TC -s filter ls dev $IF
    echo '===================================='
    if [ $LIMIT_UPLOAD == true ]; then
        $TC -s qdisc ls dev $FI
        $TC -s class ls dev $FI
        $TC -s filter ls dev $FI
    fi

}


case "$1" in

    start)

        echo "Starting bandwidth shaping.."
        restart
        echo "Starting bandwidth shaping: Done"
        ;;

    stop)

        echo "Stopping bandwidth shaping.."
        stop
        echo "Stopping bandwidth shaping: Done"
        ;;

    show)

        echo "Bandwidth shaping status for $IF:"
        show
        echo ""
        ;;

    *)

        pwd=$(pwd)
        echo "Usage: shaper.sh {start|stop|show}"
        ;;

esac

exit 0

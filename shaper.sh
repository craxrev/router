#!/bin/bash
# a QoS script for padavan based routers

#
# Name of the traffic control command.
TC=/bin/tc

# The network interface we're planning on limiting its bandwidth.
IF=br0                        # Download interface
FI=ifb0                       # Upload interface (virtual using ifb module)

# Settings
LIMIT_UPLOAD=false
WITH_BORROWING=false
EXCLUDED_MAC=''               # i.e. ADMIN MAC (ex:0c:54:15:b5:86:d7)
ICMP_PRIO=false
QUEUE_METHOD="sfq perturb 10" # "pfifo limit 10" or "sfq perturb 10"

# Download & Upload limit
CLIENT_MAX="1600 600"

# Custom speed settings: (format: CLIENT_aa_ma_ca_dd_re_ss)
CLIENT_xx_xx_xx_xx_xx_xx="700 300"


# Default speed settings
CLIENT_DEFAULT="100 50"

DLHNDL=1
UPHNDL=2

# Filter options for limiting download traffic of the intended interface.
U32_DL="$TC filter add dev $IF protocol ip parent $DLHNDL:0 prio 1 u32"

# Filter options for limiting upload traffic of the intended interface.
U32_UP="$TC filter add dev $FI protocol ip parent $UPHNDL:0 prio 1 u32"


start() {

    MAX_DNLD=`echo $CLIENT_MAX | awk '{ print $1}'`
    MAX_UPLD=`echo $CLIENT_MAX | awk '{ print $2}'`
    DEFAULT_DNLD=`echo $CLIENT_DEFAULT | awk '{ print $1}'`
    DEFAULT_UPLD=`echo $CLIENT_DEFAULT | awk '{ print $2}'`

    # Load QoS modules
    [ -z "$(lsmod | grep imq)" ] && modprobe imq
    [ -z "$(lsmod | grep ifb)" ] && modprobe ifb numifbs=1
    
    # Init virtual interface
    ip link set dev $FI up
    
    if [ $WITH_BORROWING == true ]; then
        echo "Strict bandwidth usage disabled"
    else
        echo "Strict bandwidth usage enabled"
    fi
    
    if [ $LIMIT_UPLOAD == false ]; then
        echo "Upload filtering disabled"
    fi
    
    # We'll use Hierarchical Token Bucket (HTB) to shape bandwidth.
    #
    # Prepare download shapers
    $TC qdisc add dev $IF root handle $DLHNDL: htb
    $TC class add dev $IF parent $DLHNDL: classid $DLHNDL:1 htb rate ${MAX_DNLD}kbps
    $TC class add dev $IF parent $DLHNDL:1 classid $DLHNDL:99 htb rate ${DEFAULT_DNLD}kbps `if [ $WITH_BORROWING == true ]; then echo "ceil ${MAX_DNLD}kbps"; fi`
    $TC qdisc add dev $IF parent $DLHNDL:99 handle ${DLHNDL}99: `echo $QUEUE_METHOD`
    
    if [ $LIMIT_UPLOAD == true ]; then
        # Prepare upload shapers
        $TC qdisc add dev $IF handle ffff: ingress
        $TC filter add dev $IF parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev $FI
        $TC qdisc add dev $FI root handle $UPHNDL: htb
        $TC class add dev $FI parent $UPHNDL: classid $UPHNDL:1 htb rate ${MAX_UPLD}kbps
        $TC class add dev $FI parent $UPHNDL:1 classid $UPHNDL:99 htb rate ${DEFAULT_UPLD}kbps `if [ $WITH_BORROWING == true ]; then echo "ceil ${MAX_UPLD}kbps"; fi`
        $TC qdisc add dev $FI parent $UPHNDL:99 handle ${UPHNDL}99: `echo $QUEUE_METHOD`
    fi
    
    COUNTER=10
    
    arp | grep br0 | awk '{ print $1,$2,$4 }' | tr -d '()' | while read -r line ; do
        
        HOSTNAME=`echo $line | awk '{ print $1}'`
        IP=`echo $line | awk '{ print $2}'`
        MAC=`echo $line | awk '{ print $3}'`
        NEW_MAC=`echo $MAC | tr : _`
        
        if [ "$NEW_MAC" == "<incomplete>" ]; then
            NEW_MAC=
        fi
        
        eval "CLIENT_CUSTOM=\$CLIENT_$NEW_MAC"
        
        if [ "$MAC" != "$EXCLUDED_MAC" ]; then
        
            echo $HOSTNAME
            
            if [ -n "$CLIENT_CUSTOM" ]; then
            
                CUSTOM_DNLD=`echo $CLIENT_CUSTOM | awk '{ print $1}'`
                CUSTOM_UPLD=`echo $CLIENT_CUSTOM | awk '{ print $2}'`
                
                echo "Custom limit found : setting DNLD to ${CUSTOM_DNLD}kbps, UPLD to ${CUSTOM_UPLD}kbps"
                                
                # Filtering download
                $TC class add dev $IF parent $DLHNDL:1 classid $DLHNDL:$COUNTER htb rate ${CUSTOM_DNLD}kbps `if [ $WITH_BORROWING == true ]; then echo "ceil ${MAX_DNLD}kbps"; fi`
                $U32_DL match ip dst $IP flowid $DLHNDL:$COUNTER
                $TC qdisc add dev $IF parent $DLHNDL:$COUNTER handle $DLHNDL$COUNTER: `echo $QUEUE_METHOD`
                
                if [ $LIMIT_UPLOAD == true ]; then

                    # Filtering upload
                    $TC class add dev $FI parent $UPHNDL:1 classid $UPHNDL:$COUNTER htb rate ${CUSTOM_UPLD}kbps `if [ $WITH_BORROWING == true ]; then echo "ceil ${MAX_UPLD}kbps"; fi`
                    $U32_UP match ip src $IP flowid $UPHNDL:$COUNTER
                    $TC qdisc add dev $FI parent $UPHNDL:$COUNTER handle $UPHNDL$COUNTER: `echo $QUEUE_METHOD`
                
                fi
                
                COUNTER=$((COUNTER+1))
                
            else
            
                echo "Default limit : setting DNLD to ${DEFAULT_DNLD}kbps, UPLD to ${DEFAULT_UPLD}kbps"
                
                # Filtering download
                $U32_DL match ip dst $IP flowid $DLHNDL:99
                
                if [ $LIMIT_UPLOAD == true ]; then

                    # Filtering upload
                    $U32_UP match ip src $IP flowid $UPHNDL:99
                
                fi

            fi
        fi
        echo
    done
    
    if [ $ICMP_PRIO == true ]; then
    
        echo "ICMP prioritization enabled"
        
        # Filter prio 1 icmq packets
        $TC filter add dev $IF protocol ip parent 1: prio 1 u32 match ip protocol 1 0xff flowid 1:1
        
        # Filter fortnite packets (5222, 5795-5847)
        # TODO
        
        # Filter ACK packets
        $TC filter add dev $IF protocol ip parent 1: prio 2 u32 \
        match ip protocol 6 0xff \
        match u8 0x05 0x0f at 0 \
        match u16 0x0000 0xffc0 at 2 \
        match u8 0x10 0xff at 33 \
        flowid 1:1
        
        #$TC class add dev $IF parent 1: classid 1:1 htb rate $MAX_DNLD
        
        # Prioritize ICMP packets
        #$TC class add dev $IF parent 1: classid 1:2
        #$TC qdisc add dev $IF parent 1:2 handle 999: prio
        #$TC filter add dev $IF protocol ip parent 999:0 prio 1 u32 match ip protocol 1 0xff flowid 999:1
        
    fi
    
}

stop() {

    # Stop the bandwidth shaping.
    $TC qdisc del dev $IF root
    
    if [ $LIMIT_UPLOAD == true ]; then

        $TC qdisc del dev $IF handle ffff: ingress
        $TC qdisc del root dev $FI
        
        # remove virtual interface
        ip link set dev $FI down
    
    fi
    
    # Unload QoS modules
    rmmod imq
    rmmod ifb

}

restart() {

    # Self-explanatory.
    stop
    sleep 1
    start

}

show() {

    # Display status of traffic control status.
    $TC -s qdisc ls dev $IF
    $TC -s qdisc ls dev $FI

}

case "$1" in

  start)

    echo "Starting bandwidth shaping.."
    start
    echo "Starting bandwidth shaping: Done"
    ;;

  stop)

    echo "Stopping bandwidth shaping.."
    stop
    echo "Stopping bandwidth shaping: Done"
    ;;

  restart)

    echo "Restarting bandwidth shaping .."
    restart
    echo "Restarting bandwidth shaping: Done"
    ;;

  show)

    echo "Bandwidth shaping status for $IF:"
    show
    echo ""
    ;;

  *)

    pwd=$(pwd)
    echo "Usage: tc.bash {start|stop|restart|show}"
    ;;

esac

exit 0

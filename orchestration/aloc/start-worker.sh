#!/bin/sh

if [ `uname -s` != Linux ]; then
    ## We're using GNU's getopt not BSD's {sigh}
    echo Error: Not a Linux system
    exit 1
fi

if [ -z "$WALLAROO_BIN" -o ! -x "$WALLAROO_BIN" ]; then
    echo "Error: WALLAROO_BIN env var not set or executable '$WALLAROO_BIN' does not exist"
    exit 1
fi

NUM_WORKERS=1
VERBOSE=""
JOIN_ARG=""

# Ref: /usr/share/doc/util-linux/examples/getopt-parse.bash
TEMP=`getopt -o jn:v --long join,num-workers:,verbose \
     -n $0 -- "$@"`

if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi

# Note the quotes around `$TEMP': they are essential!
eval set -- "$TEMP"

while true ; do
    case "$1" in
        -j|--join) JOIN_ARG="--join $WALLAROO_ARG_CONTROL"; shift 1 ;;
        -n|--num-workers) NUM_WORKERS=$2; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift 1 ;;
        --) shift ; break ;;
        *) echo "Internal error!" ; exit 1 ;;
    esac
done
WORKER=$1

if [ ! -z "$VERBOSE" ]; then
    echo NUM_WORKERS=$NUM_WORKERS
    echo VERBOSE=$VERBOSE
    echo WORKER=$WORKER
    echo JOIN_ARG=$JOIN_ARG
fi

## Assume: all Wallaroo workers are on the same machine via loopback interface
my_ip=${WALLAROO_INIT_HOST}

my_shift=`expr $WORKER \* 10`
my_in_port=`expr $WALLAROO_IN_BASE + $my_shift`
my_in=`echo $WALLAROO_ARG_IN | \
    sed -e "s/__IN_HOST__/$WALLAROO_INIT_HOST/" \
        -e "s/__IN_PORT__/$my_in_port/"`
my_control="${my_ip}:`expr $WALLAROO_MY_CONTROL_BASE + $my_shift`"
my_data="${my_ip}:`expr $WALLAROO_MY_DATA_BASE + $my_shift`"

cmd="$WALLAROO_BIN --in $my_in \
     $WALLAROO_BASE_ARGS \
     --name worker$WORKER --my-control $my_control --my-data $my_data \
     $JOIN_ARG $WALLAROO_ARG_PONY"
if [ ! -z "$VERBOSE" ]; then
    echo "cmd: $cmd /tmp/wallaroo.$WORKER 2>&1 &"
fi

eval "$cmd" > /tmp/wallaroo.$WORKER 2>&1 &

exit 0
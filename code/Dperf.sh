#!/bin/bash

[ $(id -u) -ne 0 ] && exec sudo "$0" "$@"

#IF=/dev/random
IF=/dev/urandom # much cheaper
#IF=/dev/zero    # not always right
#IF="/volume1/public/Install macOS Ventura 13.6.5.dmg"
OF=/dev/null
TF=$(basename $0).test

STATUS="status=progress"

TOTAL=$((2**30)) # 1G

rm -f $TF

#OFLAG="oflag=dsync"
#OFLAG="oflag=direct"

# benchmark bs count
benchmark() {
    echo -e "\n== WRITE: bs=$1, count=$2, total=$TOTAL"

    # write
    dd if="$IF" of=$TF bs=$1 count=$2 $STATUS $OFLAG

    # drop caches
    sync
    echo 3 > /proc/sys/vm/drop_caches

    sleep 1

    echo -e "\n== READ: bs=$1, count=$2, total=$TOTAL"
    # read
    dd if=$TF of=$OF bs=$1 $STATUS

    # clean
    rm -f $TF
}

benchmark2() {
    if which ioping &>/dev/null; then
        echo -e "\n== Latency test: "
        ioping -count 10 -size 1M -quiet .
        echo -e "\n== Seek rate test: "
        ioping -rapid -quiet .
    else
        echo -e "\n== Please install ioping first"
    fi

    echo -e "\n== WRITE: bs=$1, count=$2, total=$TOTAL"

    # write
    # https://superuser.com/questions/470949/how-do-i-create-a-1gb-random-file-in-linux
    openssl rand -base64 $(( TOTAL * 3 / 4 )) |
    dd of=$TF bs=$1 count=$2 $OFLAG $STATUS iflag=fullblock

    # drop caches
    sync
    echo 3 > /proc/sys/vm/drop_caches

    sleep 1

    echo -e "\n== READ: bs=$1, count=$2, total=$TOTAL"
    # read
    dd if=$TF of=$OF bs=$1 $STATUS

    # clean
    rm -f $TF
}

count=$((TOTAL / 1024 / 1024))  # in 1M
benchmark2  1M  $count
#benchmark2  4K  $((count * 256))

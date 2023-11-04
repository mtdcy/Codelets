#!/bin/bash
# ip route management script.
# Copyright (c) Chen Fang 2023, mtdcy.chen@gmail.com.
#
# DON'T exec this script directly, create symlinks first.
# 
# symlink name syntax:
#  <ip table id>-<ipset name>@<gateway ip>@<device name>.sh 

# parse parameters
IFS='@' read a route netif <<< "$(basename $0)"
IFS='-' read iptbl ipset <<< "$a"
netif=${netif%.sh}

cd $(dirname $0)
echo "$PWD: $iptbl - $ipset @ $route @ $netif"

# never use table 00 
iptbl=$(expr $iptbl + 1)
iptmark=$iptbl
iptrule="-m set --match-set $ipset dst -j MARK --set-mark $iptmark"

# sanity check
[ $iptbl -ge 200 ] && echo "ip table >= 200 is forbidden." && exit 255 

route_clear() {
    # delete exists table 
    ip route list table $iptbl > /dev/null 2>&1 &&
    ip route del default table $iptbl 

    # clear route rules 
    ip rule flush table $iptbl

    # clear iptables 
    iptables -t mangle -D PREROUTING $iptrule > /dev/null 2>&1 
    iptables -t mangle -D OUTPUT $iptrule > /dev/null 2>&1 
}

route_setup() {
    # new table 
    ip route add default via $route dev $netif table $iptbl || exit 1

    # create a new route rule 
    ip rule add fwmark $iptmark table $iptbl || exit 2

    # setup ipset
    ipfile="$(dirname $0)/data/$ipset"
    ip2set="$(dirname $0)/ip2set.sh"
    [ -f "$ipfile.lst" ] && "$ip2set" "$ipfile.lst" || "$ip2set" "$ipfile.ip" || exit 3

    # route ipset to netif
    # forward 
    iptables -t mangle -C PREROUTING $iptrule > /dev/null 2>&1 || 
    iptables -t mangle -I PREROUTING $iptrule || exit 4
    # output 
    iptables -t mangle -C OUTPUT $iptrule > /dev/null 2>&1 || 
    iptables -t mangle -I OUTPUT $iptrule || exit 5
}

route_clear 
[ "$1" != "clear" ] && route_setup

echo ""
echo "= route table $iptbl:"
ip route list table $iptbl
ip rule list table $iptbl
echo ""
echo "= ipset:"
ipset list $ipset
echo ""
echo "= iptables:"
iptables -t mangle -S PREROUTING

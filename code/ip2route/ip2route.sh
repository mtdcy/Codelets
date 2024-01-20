#!/bin/bash
# ip route management script.
# Copyright (c) Chen Fang 2023, mtdcy.chen@gmail.com.
#
# DON'T exec this script directly, create symlinks first.
#
#  <ip table id>-<ipset name>@<gateway ip>@<device name>.sh 
#
# 
# v0.2 - 20231125, code refactoring.
# 				   ... 
# 
# v0.1 - initial version


# root privilege is required 
[ $(id -u) -eq 0 ] || exec sudo "$0" "$@" 

dnsmasq="$(dirname $0)/dnsmasq.auto"
[ -f $dnsmasq ] || echo "# dnsmasq servers, generated by ip2route.sh" > $dnsmasq

usage() {
    cat << EOF
ip route management script, v0.2.
Copyright (c) Chen Fang 2023, mtdcy.chen@gmail.com.

ip2route.sh options 

update mode: 
  ip2route.sh path/to/some.ip  [list]   # create a ipset from ip file, and add it to list.
  ip2route.sh path/to/some.lst [list]   # create a ipset from list file, and add it to list.

full mode: 
  symlink_of_ip2route.sh                # update ipset and setup the route.
  symlink_of_ip2route.sh flush          # clear everything except the ipset.

  Please create the right symlink before enter full mode:

  <ip table id>-<ipset name>@<gateway ip>@<device name>.sh -> ip2route.sh 
EOF
}

is_host() { [[ $@ =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]];        }
is_cidr() { [[ $@ =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; }

# update_dnsmasq <domain> <set> <@dns> 
update_dnsmasq() {
    # delete records
    sed -i "/server=\/$1\/*/d" "$dnsmasq"
    sed -i "/ipset=\/$1\/*/d" "$dnsmasq"

    for s in ${@:3}; do
        echo "server=/$1/${s#@}" >> "$dnsmasq"
        echo "ipset=/$1/$2" >> "$dnsmasq"
    done
}

# update_ipset path/to/some.ip [list]
update_ipset() {
    local name=$(basename ${1%.ip})
    local list=${2:-}
    local cidr=0

    # scan for net cidr
    while read host; do
        is_cidr $host && cidr=1 && break
    done < "$1"

    echo "cidr: $cidr"
    # destroy will fail if ipset is in use.
    ipset destroy $name > /dev/null 2>&1 || ipset flush $name

    # create an ipset
    if [ $cidr -eq 0 ]; then 
        ipset -exist create $name hash:ip
    else
        ipset -exist create $name hash:net
    fi

    echo "ipset $name:"
    local dns=()
    while read line; do
		# remove spaces and tail comments
		IFS=' ' read host _ <<< "$line"

        [ -z "$host" ] && continue;
		[[ "$host" =~ '#' ]] && continue;

        # save dns
        [[ "$host" =~ '@' ]] && dns+=($host) && continue

        echo $host

        # add ip to set directly 
        is_host $host && ipset -exist add $name $host && continue
        is_cidr $host && ipset -exist add $name $host && continue

        [ ${#dns[@]} -eq 0 ] || echo " ${dns[@]}"
        update_dnsmasq $host $name ${dns[@]}
    done < "$1"

    [ -z "$list" ] && return 0

    # add current ipset to list without flush
    ipset -exist create $list list:set
    ipset -exist add $list $name
}

# update_iplst path/to/some.lst [list]
update_iplst() {
    name=$(basename ${1%.lst})
    ipset flush $name
    while read ips; do
        [[ $ips =~ '#' ]] && continue # ignore comments 

        update_ipset $(dirname $1)/$ips $name || return $?
    done < "$1"

    [ -z "$2" ] || ipset -exist add $2 $name
    ipset list $name
}

[ "$1" = "help" ] && usage && exit 0

# update mode: create/update ipset from *.ip or *.lst and add it to list
if [ $# -gt 0 -a "$1" != "flush" ]; then
    case "$1" in
        *.lst)
            update_iplst "$1" "$2"
            ;;
        *.ip)
            update_ipset "$1" "$2"
            ;;
        *)
            usage
            ;;
    esac
    exit $?
fi

# full mode: 
IFS='-@' read iptbl ipset route netif _ <<< "$(basename $0)"
netif=${netif%.sh} # remove tailing '.sh'

cd $(dirname $0)
echo "$PWD: $iptbl-$ipset@$route@$netif"

iptbl=$(expr $iptbl + 1)    # never use table 00 
iptmark=$iptbl
iptrule="-m set --match-set $ipset dst -j MARK --set-mark $iptmark"

if [ "$1" = "flush" ]; then
    # delete exists table 
    ip route del default table $iptbl || true
    # clear route rules 
    ip rule flush table $iptbl || true
    # clear iptables 
    iptables -t mangle -D PREROUTING $iptrule || true
    iptables -t mangle -D OUTPUT $iptrule || true
else
    # new table, may exist
    ip route add default via $route dev $netif table $iptbl 

    # create a new route rule: may exist
    ip rule flush table $iptbl 2> /dev/null || true
    ip rule add fwmark $iptmark table $iptbl

    # setup ipset
    ipfile="data/$ipset"
    case $(ls "$ipfile".*) in 
        *.lst)  update_iplst "$ipfile.lst" ;;
        *.ip)   update_ipset "$ipfile.ip"  ;;
    esac

    # route ipset to netif
    # forward 
    iptables -t mangle -C PREROUTING $iptrule > /dev/null 2>&1 ||
    iptables -t mangle -I PREROUTING $iptrule 
    # output 
    iptables -t mangle -C OUTPUT $iptrule > /dev/null 2>&1 ||
    iptables -t mangle -I OUTPUT $iptrule
fi

echo ""
echo "= route table $iptbl:"
ip route list table $iptbl
ip rule list table $iptbl
echo ""
echo "= ipset:"
ipset list $ipset
echo ""
echo "= iptables:"
iptables -t mangle -C PREROUTING $iptrule 
#!/bin/bash
# ip route management script.
# Copyright (c) Chen Fang 2023, mtdcy.chen@gmail.com.
#
# DON'T exec this script directly, create symlinks first.
#
#  <ip table id>-<ipset name>@<gateway ip>@<device name>.sh
#
#
# v0.2.1    - 20240613, add echocmd and fix tcpmss
# v0.2      - 20231125, code refactoring.
# 				   ...
# v0.1      - initial version


# root privilege is required
[ $(id -u) -eq 0 ] || exec sudo "$0" "$@"

cd $(dirname $0)

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

echocmd() {
    local cmd="${*//[[:space:]]+/ }"
    echo -e "--\\033[34m $cmd \\033[0m"
    eval -- "$cmd"
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

    #echo "cidr: $cidr"
    # destroy will fail if ipset is in use.
    ipset destroy $name &>/dev/null ||
    ipset flush $name &>/dev/null

    # create an ipset
    if [ $cidr -eq 0 ]; then
        echocmd ipset -exist create $name hash:ip
    else
        echocmd ipset -exist create $name hash:net
    fi

    #echo "ipset $name:"
    local dns=()
    while read line; do
		# remove spaces and tail comments
		IFS=' ' read host _ <<< "$line"

        [ -z "$host" ] && continue;
		[[ "$host" =~ '#' ]] && continue;

        # save dns
        [[ "$host" =~ '@' ]] && dns+=($host) && continue

        #echo $host

        # add ip to set directly
        is_host $host && ipset -exist add $name $host && continue
        is_cidr $host && ipset -exist add $name $host && continue

        #[ ${#dns[@]} -eq 0 ] || echo " ${dns[@]}"
        update_dnsmasq $host $name ${dns[@]}
    done < "$1"

    [ -z "$list" ] && return 0

    # add current ipset to list without flush
    echocmd ipset -exist add $list $name
}

# update_iplst path/to/some.lst [list]
update_iplst() {
    name=$(basename ${1%.lst})
    ipset flush $name &>/dev/null
    echocmd ipset -exist create $name list:set
    while read ips; do
        [[ $ips =~ '#' ]] && continue # ignore comments

        update_ipset $(dirname $1)/$ips $name || return $?
    done < "$1"

    [ -z "$2" ] || echocmd ipset -exist add $2 $name
    #ipset list $name
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
IFS='-@' read iptbl ipset gw dev _ <<< "$(basename $0)"
dev=${dev%.sh} # remove tailing '.sh'

echo -e "\n== $PWD: $iptbl-$ipset@$gw@$dev =="

iptbl=$(expr $iptbl + 1)    # never use table 00
iptmark=$iptbl
iptrule="-m set --match-set $ipset dst -j MARK --set-mark $iptmark"
tcpmss="-p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"

# flush fisrt
# delete exists table
ip route del default table $iptbl &>/dev/null
# clear route rules
ip rule flush table $iptbl &>/dev/null
# clear iptables
iptables -t mangle -D PREROUTING $iptrule &>/dev/null
iptables -t mangle -D OUTPUT $iptrule &>/dev/null
iptables -t mangle -D FORWARD -i $dev $tcpmss &>/dev/null
iptables -t mangle -D FORWARD -o $dev $tcpmss &>/dev/null

if ! ping -c1 $gw &>/dev/null; then
    echo "gw $gw unreachable, abort"
    exit 1
fi

# new table
echocmd ip route add default via $gw dev $dev table $iptbl

# create a new route rule
echocmd ip rule add fwmark $iptmark table $iptbl

# setup ipset
ipfile="data/$ipset"
case $(ls "$ipfile".*) in
    *.lst)  update_iplst "$ipfile.lst" ;;
    *.ip)   update_ipset "$ipfile.ip"  ;;
esac

# route ipset to dev
# forward
echocmd iptables -t mangle -I PREROUTING $iptrule
# output
echocmd iptables -t mangle -I OUTPUT $iptrule

# TCPMSS
echocmd iptables -t mangle -I FORWARD -i $dev $tcpmss
echocmd iptables -t mangle -I FORWARD -o $dev $tcpmss

#echo ""
#echo "= route table $iptbl:"
#ip route list table $iptbl
#ip rule list table $iptbl
#echo ""
#echo "= ipset:"
#ipset list $ipset
#echo ""
#echo "= iptables:"
#iptables -t mangle -C PREROUTING $iptrule
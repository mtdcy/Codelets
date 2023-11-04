#!/bin/bash
# A ip route management script.
# Copyright (c) Chen Fang 2023, mtdcy.chen@gmail.com.

dnsmasq="$(dirname $0)/dnsmasq.auto"

usage() {
    cat << EOFA 
ip route management script.
Copyright (c) Chen Fang 2023, mtdcy.chen@gmail.com.

Usage:
$(basename $0) <ip file> [ip list name]
EOF
}

# host ip ?
is_host() {
    [[ $@ =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# net cidr ?
is_cidr() {
    [[ $@ =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]
}

setup_dnsmasq() {
    [ -f $dnsmasq ] && return 0

    echo "# dnsmasq servers, generated by ip2set.sh" > $dnsmasq
}

# update_dnsmasq <domain> <@dns>
update_dnsmasq() {
    # delete records
    sed -i "/server=\/$1\/*/d" $dnsmasq 

    for s in ${@:2}; do
        echo "server=/$1/${s#@}" >> "$dnsmasq"
    done
}

# update_dnsmasq <domain> <set> <@dns> 
update_dnsmasq_v2() {
    # delete records
    sed -i "/server=\/$1\/*/d" "$dnsmasq"
    sed -i "/ipset=\/$1\/*/d" "$dnsmasq"

    for s in ${@:3}; do
        echo "server=/$1/${s#@}" >> "$dnsmasq"
        echo "ipset=/$1/$2" >> "$dnsmasq"
    done
}

# TODO: 
#  add ttl and update with crontab 
update_ipset() {
    local name=$(basename ${1%.ip})
    local target=${2:-}
    local cidr=0

    setup_dnsmasq 

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
    while read host; do
        # remove comments
        host=$(echo $host | sed 's/#.*$//')
        # remove spaces
        host=$(echo $host | tr -d ' ')

        [ -z "$host" ] && continue;

        # save dns
        [[ "$host" == @* ]] && dns+=($host) && continue

        echo $host
        
        # add ip to set directly 
        is_host $host && ipset -exist add $name $host && continue
        is_cidr $host && ipset -exist add $name $host && continue

        [ ${#dns[@]} -eq 0 ] || echo " ${dns[@]}"

        # v2: add domain to dnsmasq with ipset 
        update_dnsmasq_v2 $host $name ${dns[@]}

        # v1: resolve domain directly - deprecated 
        #dig +short "${dns[@]}" $host | while read ip; do
        #    echo "  => $ip"

        #    # ignore CNAME and errors
        #    is_host $ip || continue 

        #    ipset -exist add $name $ip
        #done 
        #update_dnsmasq $host ${dns[@]}
    done < "$1"

    #apply_dnsmasq 

    [ -z "$target" ] && return 0
    
    # add current ipset to list without flush
    ipset -exist create $target list:set
    ipset -exist add $target $name
}

update_iplst() {
    name=$(basename ${1%.lst})
    while read ips; do
        update_ipset $(dirname $1)/$ips $name || return $?
    done < "$1"

    ipset list $name
}

# ip file exists?
[ ! -f "$1" ] && echo "$1 doesn't exists, exit" && exit 255

case "$1" in 
    *.lst)
        update_iplst "$@" || exit $?
        ;;
    *.ip)
        update_ipset "$@" || exit $?
        ;;
    *)
        usage
        ;;
esac

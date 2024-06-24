#!/bin/bash
# A pretty network connection track script.
# Copyright (c) Chen Fang 2023, mtdcy.chen@gmail.com.

set -e

usage() {
    cat << EOF
A pretty network connection track script.
Copyright (c) Chen Fang 2023, mtdcy.chen@gmail.com.

Usage: $(basename $0) [options] [host]

Examples:

    1. $(basename $0)                   - view all connections
    2. $(basename $0) 192.168.0.2       - view connections from/to 192.168.0.2
    3. $(basename $0) 192.168.0.0/24    - view connections from/to 192.168.0.0/24
    4. $(basename $0) github.com        - view connections from/to github.com
EOF
}

W4=21   # width for ipv4:port
W6=45   # width for ipv6:port

WI=$W4
format_lines() {
    while read line; do
        [ -z "$line" ] && continue

        #echo -e "\n = $line"
        IFS=' ' read proto _ _ conn <<< "$line"

        state=""
        [[ "$conn" =~ ^[A-Z]+ ]] && IFS=' ' read state conn <<< "$conn"

        # connection source => destination
        case "$proto" in
            tcp|udp)
                IFS=' =' read _ src0 _ dst0 _ sp0 _ dp0 conn <<< "$conn"
                printf " %-7s %-${WI}s => %-${WI}s" "[$proto]" "$src0:$sp0" "$dst0:$dp0"
                ;;
            *)
                IFS=' =' read _ src0 _ dst0 _ _ _ conn <<< "$conn"
                printf " %-7s %-${WI}s => %-${WI}s" "[$proto]" "$dst0" "$src0"
                ;;
        esac

        # packets=n bytes=n
        #  => sysctl -w net.netfilter.nf_conntrack_acct=1
        [[ "$conn" =~ ^packets=         ]] && IFS=' ' read _ conn <<< "$conn"
        [[ "$conn" =~ ^bytes=           ]] && IFS=' =' read _ bytes conn <<< "$conn"
        # [UNREPLIED]
        [[ "$conn" =~ ^\[UNREPLIED\]    ]] && IFS=' ' read _ conn <<< "$conn" && state="UNREPLIED"

        if [ ! -z "$bytes" ]; then
            # shortten states: E - ESTABLISHED, T - TIME_WAIT, S - SYN_SENT, U - UNREPLIED
            printf ' %7s' $(numfmt --to iec "$bytes")
            [ ! -z "$state" ] && printf ' [%-.1s]' "$state"
        else
            printf ' %11s' "$state"
        fi

        # reply source => destination
        IFS=' =' read _ src1 _ dst1 conn <<< "$conn"
        case "$proto" in
            tcp|udp)
                IFS=' =' read _ sp1 _ dp1 conn <<< "$conn"
                ;;
            *)
                IFS=' ' read _ _ _ conn <<< "$conn"
                ;;
        esac

        if [ "$dst0" = "$dst1" -a "$src0" != "$src1" ] ||
           [ "$src0" = "$dst1" -a "$dst0" != "$src1" ]; then
            # > next hop
            [ ! -z "$sp1" ] && echo -ne " \t>$src1:$sp1" || echo -ne " \t>$src1"
        elif [ "$dst0" = "$src1" -a "$src0" != "$dst1" ]; then
            # @ gateway
            [ ! -z "$dp1" ] && echo -ne " \t@$dst1:$dp1" || echo -ne " \t@$dst1"
        fi

        echo ""
    done
}

[ "$1" = "help" ] && { usage; exit 0; }

[ $(id -u) -ne 0 ] && exec sudo "$0" "$@"

which dig 2>&1 > /dev/null || apt install dnsutils
which conntrack 2>&1 > /dev/null || apt install conntrack

host="$1"
IPv4="^([0-9]{1,3}\.){3}([0-9]{1,3}){1}"
IPv6="^([0-9a-fA-F]{0,4}:){7}([0-9a-fA-F]{0,4}){1}"

if [[ $host =~ $IPv4 ]]; then
    host4=$host
elif [[ $host =~ $IPv6 ]]; then
    host6=$host
elif [ ! -z "$host" ]; then
    host4=$(dig +short $host A 2> /dev/null | grep -v '\.$' || true)
    host6=$(dig +short $host AAAA 2> /dev/null | grep -v '\.$' || true)
    echo -e " #$host => |${host4//$'\n'/;}|${host6//$'\n'/;}|\n"
fi

if [ ! -z "$host4" ] || [ -z "$host" ]; then
    echo " #IPv4 Connections"
    WI=$W4
    printf " %-7s %-${WI}s => %-${WI}s %-11s \t%s\n" "#proto" "#source" "#destition" "#state" "# >next | @gw"
    if [ -z "$host" ]; then
        conntrack -f ipv4 -L 2> /dev/null || true               # list all
    else
        while read line; do
            conntrack -f ipv4 -L -s $line 2> /dev/null || true  # match source
            conntrack -f ipv4 -L -d $line 2> /dev/null || true  # match destination
            conntrack -f ipv4 -L -r $line 2> /dev/null || true  # match reply source
            conntrack -f ipv4 -L -q $line 2> /dev/null || true  # match reply destination
        done <<< "$host4"
    fi | grep -v "127.0.0.1" | format_lines
    echo ""
fi

if [ ! -z "$host6" ] || [ -z "$host" ]; then
    echo " #IPv6 Connections"
    WI=$W6
    printf " %-7s %-${WI}s => %-${WI}s %-11s \t%s\n" "#proto" "#source" "#destition" "#state" "# >next | @gw"
    if [ -z "$host" ]; then
        conntrack -f ipv6 -L 2> /dev/null || true               # list all
    else
        while read line; do
            conntrack -f ipv6 -L -s $line 2> /dev/null || true  # match source
            conntrack -f ipv6 -L -d $line 2> /dev/null || true  # match destination
            conntrack -f ipv6 -L -r $line 2> /dev/null || true  # match reply source
            conntrack -f ipv6 -L -q $line 2> /dev/null || true  # match reply destination
        done <<< "$host6"
    fi | grep -v "::1" | format_lines
    echo ""
fi
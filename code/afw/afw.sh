#!/bin/bash
# a pretty iptables script (c) Chen Fang 2023, mtdcy.chen@gmail.com.
#
# v0.1  20231030    initial version
# v0.2  20240120    add env VERBOSE

set +H
set -e

# options
VERBOSE=${VERBOSE:-1}

echo "VERBOSE:$VERBOSE"

# constants
TRACKED="-m conntrack --ctstate RELATED,ESTABLISHED"
LOCAL="-m addrtype --dst-type LOCAL"
BRIDGED="-m physdev --physdev-is-bridged"
TCPSYN="-p tcp --tcp-flags SYN,RST SYN"
TCPMSS="TCPMSS --set-mss" # suffix with mss value

usage() {
    cat <<EOF
$(basename $0) <config>
$(basename $0) COMMAND [parameters...]

Commands:
    # Target Controls
    NEW_TARGET [table]       TARGET     ["rule1" "rule2" "..."]
    ADD_TARGET [table] CHAIN new-TARGET ["rule1" "rule2" "..."]

    # Input Filters
    ALLOW   source tcp|udp[:dports] "match"          [comments]
    BLOCK   source tcp|udp[:dports] "match"          [comments]
    DNAT    source tcp|udp[:dports] ip[:port]|TARGET [comments]

    # Forward Filters
    FORWARD destination source "match" TARGET        [comments]
    SNAT    destination source "match" ip|TARGET     [comments]
    NAT1    destination source "match" ip|TARGET     [comments]

    # No Output Filter

    # Logger 
    IPLOG   source destination tcp|udp[:dports] "match" [label]

Targets:
    AFW-IPF     : Input filter target hook PREROUTING and INPUT chain
    AFW-NAT     : Forward filter target hook FORWARD and POSTROUTING chain 

    AFW-DROP    : LOG and DROP target in 'filter' and 'nat' tables

Constants: 
    LOCAL       : match connections to local, "$LOCAL"
    TRACKED     : match related or established connections, "$TRACKED"
    BRIDGED     : match packets on bridged port, "$BRIDGED"
    TCPSYN      : match tcp SYN packets, "$TCPSYN"
    TCPMSS      : set tcp MSS value, "$TCPMSS" <value>
EOF
}

# IPtable Filter Table
ipt="iptables"
IPFT="-t nat"
# => Filter @ PREROUTING => best for a LAN firewall/DMZ host

# Syntax:
#   s - source
#   d - destination
#   p - protocol
#   m - match
#   j - jump
#   t - target
#   l - label

# IPTable
# IPTtmj target "match" <ACCEPT|DROP|...> [comments]
IPTtmj() {
    #echo IPTtmj "$@"
    local rule="$1"

    [ -z "$2" ]     || rule="$rule $2"
    [ -z "$3" ]     || rule="$rule -j $3" # TARGET embbed in 'match'
    [ -z "${@:4}" ] || rule="$rule -m comment --comment \"${@:4}\""

    echo "$ipt -A $rule"
    #eval "$ipt -C $rule || $ipt -A $rule"
    eval "$ipt -A $rule"
}

# IPTp2m tcp|udp[:dports] [sports] => match-rule
#  tcp,udp:53:80 => tcp:53:80 + udp:53:80
IPTp2m() {
    IFS=':' read proto ports <<<"$@"

    for p in ${proto//,/ }; do
        #[ "$p" = "all" ] && echo "" && continue

        local match="-p $p"
        case "$ports" in
            "")         ;;
            *:* | *,*)  match="$match -m multiport --dports $ports" ;;
            *)          match="$match -m $p --dport $ports"         ;;
        esac
        echo "$match"
    done
}

# IPTs2m source[:sport] => match-rule
IPTs2m() {
    IFS=':' read source sp <<<"$@"
    [[ $source =~ ^! ]] && not="! " && source=${source#!}
    case "$source" in
        any | "*")  source="" ;;
        *.*.*.*)    source="-s $source" ;;
        *)          source="-i $source" ;;
    esac

    [ -z "$sp" ]    || source="$source -m multiport --sports $sp"
    echo "$not$source"
}

# IPTd2m destination[:dport] => match-rule
IPTd2m() {
    IFS=':' read dest dp <<<"$@"
    [[ $dest =~ ^! ]] && not="! " && dest=${dest#!}
    case "$dest" in
        any | "*")  dest="" ;;
        *.*.*.*)    dest="-d $dest" ;;
        *)          dest="-o $dest" ;;
    esac

    [ -z "$dp" ]    || dest="$dest -m multiport --dports $dp"
    echo "$not$dest"
}

# NEW_TARGET [table] TARGET ["rule1" "rule2" "..."]
#  => create a new target, otherwise flush if it already exists
NEW_TARGET() {
    #echo $0 "$@"
    local table="filter"
    # table is lowercase and TARGET is uppercase
    [[ "$1" =~ ^[a-z]+$ ]] && table="$1" && shift 1

    local target="$1"
    echo "$ipt -t $table -N $target"
    $ipt -t $table -N $target 2>/dev/null || $ipt -t $table -F $target

    for rule in "${@:2}"; do
        local cmd
        case "$rule" in
            LOG*)
                IFS=' ' read _ prefix <<<"$rule"
                cmd="$ipt -t $table -A $target -j LOG --log-prefix \"$prefix => \""
                ;;
            -j*)
                cmd="$ipt -t $table -A $target $rule"
                ;;
            *)
                cmd="$ipt -t $table -A $target -j $rule"
                ;;
        esac
        echo "$cmd"
        eval "$cmd"
    done
}

# ADD_TARGET [table] CHAIN TARGET ["rule1" "rule2" "..."]
#  => insert a new target in exists chain
ADD_TARGET() {
    echo $0 "$@"
    local table="filter"
    [[ "$1" =~ ^[a-z]+$ ]] && table="$1" && shift 1

    NEW_TARGET "$table" "$2" "${@:3}"

    local rule="$1 -j $2"

    echo "$ipt -t $table -I $rule"
    # always delete and then insert
    $ipt -t $table -D $rule >/dev/null  2>&1 
    $ipt -t $table -I $rule
    # => we prefer to insert instead of append, but which is not compatible with docker
}

# ==============================================================================
# =============================== IPtable Filter ===============================
# IPFsmj source "match" TARGET [comments]
IPFsmj() {
    # Filter input @ INPUT or PREROUTING ?
    local match="$(IPTs2m $1)"
    [ -z "$2" ] || match="$match $2"
    case "$3" in
        DNAT*)          IPTtmj "AFW-IPF -t nat" "${match# }" "$3" "${@:4}" ;;
        *)              IPTtmj "AFW-IPF $IPFT"  "${match# }" "$3" "${@:4}" ;;
    esac
}

# IPFdmj destination "destination-match" TARGET [comments]
IPFdmj() {
    #echo IPFdmj "$1" "$2"
    local match="$(IPTd2m $1)"
    [ -z "$2" ] || match="$match $2"
    case "$3" in
        MASQ* | SNAT*)  IPTtmj "AFW-NAT -t nat"     "${match# }" "$3" "${@:4}" ;;
        *)              IPTtmj "AFW-NAT -t filter"  "${match# }" "$3" "${@:4}" ;;
    esac
}

# IPFspmj source tcp|udp[:dports] "match" TARGET [comments]
IPFspmj() {
    while read match; do
        [ -z "$3" ] || match="$match $3"
        IPFsmj "$1" "${match# }" "$4" "${@:5}"
    done <<<"$( IPTp2m $2)"
}

# IPFdpmj destination tcp:udp[:dports] "match" TARGET [comments]
IPFdpmj() {
    while read match; do
        [ -z "$3" ] || match="$match $3"
        IPFdmj "$1" "${match# }" "$4" "${@:5}"
    done <<<"$( IPTp2m $2)"
}

# ==============================================================================
# BLOCK Input Traffics
# BLOCK source tcp|udp[:dports] "match" [comments]
BLOCK() {
    case "$3" in
        *-j*)   IPFspmj "$1" "$2" "$3" ""       "${@:4}" ;;
        *)      IPFspmj "$1" "$2" "$3" AFW-DROP "${@:4}" ;;
    esac
}

# ALLOW Input Traffics
# ALLOW source tcp|udp[:dports] "match" [comments]
ALLOW() {
    case "$3" in
        *-j*)   IPFspmj "$1" "$2" "$3" ""     "${@:4}" ;;
        *)      IPFspmj "$1" "$2" "$3" ACCEPT "${@:4}" ;;
    esac
}

# RETURN source tcp|udp[:dports] "match" [comments]
RETURN() {
    case "$3" in
        *-j*)   IPFspmj "$1" "$2" "$3" ""     "${@:4}" ;;
        *)      IPFspmj "$1" "$2" "$3" RETURN "${@:4}" ;;
    esac
}

# DNAT source tcp|udp:dports ip[:port]|TARGET [comments]
DNAT() {
    case "$3" in
        *.*.*.*) IPFspmj "$1" "$2" "" "DNAT --to $3" "${@:4}" ;;
        *)       IPFspmj "$1" "$2" "" "$3"           "${@:4}" ;;
    esac
    # for DMZ, it seems '$LOCAL' is excess.
    #case "$3" in
    #    *.*.*.*) IPFspmj "$1" "$2" "$LOCAL" "DNAT --to $3" "${@:4}" ;;
    #    *)       IPFspmj "$1" "$2" "$LOCAL" "$3"           "${@:4}" ;;
    #esac
}

# FORWARD destination source "match" TARGET [comments]
FORWARD() {
    local match="$(IPTs2m $2)"
    [ -z "$3" ] || match="$match $3"

    IPFdmj "$1" "${match# }" "$4" "${@:5}"
}

# SNAT destination source "match" ip|TARGET [comments]
SNAT() {
    local match="$(IPTs2m $2)"
    [ -z "$3" ] || match="$match $3"

    case "$4" in
        ^*.*.*.*)   IPFdmj "$1" "${match# }" "SNAT --to $4" "${@:5}" ;;
        *)          IPFdmj "$1" "${match# }" "$4"           "${@:5}" ;;
    esac
}

# NAT1 destination source "match" to|TARGET [comments]
NAT1() {
    # FUCK:
    #  = at least two conditions must be here for each FORWARD command
    #   => spent two days stuck here
    #    => e.g: FORWARD lan0 any "" ACCEPT won't work
    FORWARD "$1" "$2" "$3"          ACCEPT  "${@:5}"
    FORWARD "$2" "$1" "$TRACKED"    ACCEPT  "${@:5}"

    local TARGET="$4"
    case "$TARGET" in
        ^*.*.*.*)   TARGET="SNAT --to $TARGET" ;;
    esac

    if [[ $TARGET =~ ^MASQ* ]] || [[ $TARGET =~ ^SNAT* ]]; then
        case "$2" in
            *.*.*.*)    SNAT "$1" "$2" "$3" "$4" "${@:5}" ;;
            *)          SNAT "$1" any  "$3" "$4" "${@:5}" ;; # no match input devices
        esac
    fi
}

# IPLtml target tcp|udp[:dports] "match" "label"
IPLtpm() {
    while read match; do
        [ -z "$3" ] || match="$match $3"
        IPTtmj "$1" "$match" "LOG --log-prefix \"$4: \"" "$4"
    done <<< "$(IPTp2m $2)"
}

# ==============================================================================
# IPtable Logger
# IPLOG source destination tcp|udp[:dports] "match" [label]
IPLOG() {
    local match="$(IPTs2m $1) $(IPTd2m $2)"
    case "$1" in
        *.*.*.*)    pos="$match"        ;;
        *)          pos="$(IPTd2m $2)"  ;; # no input device for OUTPUT/POSTROUTING
    esac

    case "$2" in
        *.*.*.*)    inp="$match"        ;;
        *)          inp="$(IPTs2m $1)"  ;; # no output device for PREROUTING/INPUT
    esac

    IPLtpm  "AFW-IPF $IPFT" "$3" "$inp $4" "IPL:INP:${@:5}"
    IPLtpm  "AFW-NAT"       "$3" "$fwd $4" "IPL:FWD:${@:5}"
    IPLtpm  "AFW-NAT $IPFT" "$3" "$pos $4" "IPL:OUT:${@:5}"
}

[ "$1" = "help" ] && usage && exit

# always run as root
[ $(id -u) -ne 0 ] && exec sudo VERBOSE=$VERBOSE "$0" "$@"

# ==============================================================================
# INITIAL:
#  => NEVER FLUSH preset chains

# our targets:
ADD_TARGET      INPUT               AFW-IPF
ADD_TARGET nat  PREROUTING          AFW-IPF
ADD_TARGET      FORWARD             AFW-NAT
ADD_TARGET nat  POSTROUTING         AFW-NAT

# Blocked Packets: LOG -> DROP
# => DROP not allowed in nat/PREROUTING, so throw it into a black hole
if [ $VERBOSE -ne 0 ]; then
    NEW_TARGET nat  AFW-DROP        "LOG PRE:DROP"  "DNAT --to 0.0.0.1" # => Black Hole
    NEW_TARGET      AFW-DROP        "LOG NAT:DROP"  DROP
else
    NEW_TARGET nat  AFW-DROP        "DNAT --to 0.0.0.1" # => Black Hole
    NEW_TARGET      AFW-DROP        DROP
fi

# load afw config
[ $# -eq 1 ] && {
    echo "load afw config $1"
    source "$1"
    exit
}

# library mode
[ $# -gt 1 ] && {
    echo "$@"
    eval "$@"
    exit
}

# ==============================================================================
# ========================== Begin of Inline Config ============================
LAN=lan4            # IPv4 lan & wan => default route
N2N=n2n0            # secondary wan => route with ipset
NET=10.10.10.0/24   # local net cidr
LIP=10.10.10.254    # LAN ip
NIP=10.20.30.2      # N2N ip
NGW=10.20.30.1      # N2N gw

SNAT4LAN="SNAT --to $LIP"
SNAT4N2N="SNAT --to $NIP"
# ==============================================================================

# ==============================================================================
# ================================== IPLOG =====================================
#IPLOG  #source         #dest           #tcp|udp:dports     #match      #label
#IPLOG   any             any             all                 "$LOCAL"    "LOCAL"

# ==============================================================================

# ==============================================================================
# =================================== DNAT =====================================
#       #source         #tcp,udp[:dports]           #destination        #comments

DNAT    any             tcp:548,139,445             10.10.10.200        "NAS/SMB"   # AFP/SMB
DNAT    any             tcp:6690                    10.10.10.200        "NAS/DRIVE" # Synology Drive

# P2P 
DNAT    any             tcp:14662,16881             10.10.10.200        "NAS/DL" # Download Station
DNAT    any             udp:14672,16881             10.10.10.200        "NAS/DL" # Download Station

# ==============================================================================

# ==============================================================================
# ================================= Allow/Block ================================
#A/B    #source         #tcp|udp[:dports]           #match              #comments

RETURN  docker0         all                         ""                  "DOCKER compliance"

ALLOW   lo              all                         ""                  "ALLOW/lo"
ALLOW   any             all                         "$TRACKED"          "ALLOW/Tracked" # Allow Tracked Connections

ALLOW   $NET            all                         ""                  "ALLOW/Local"   # Allow All Local Traffics
ALLOW   $N2N            all                         "-s $NGW"           "ALLOW/N2N/GW"

ALLOW   any             icmp                        ""                  "ALLOW/ICMP"
ALLOW   any             igmp                        ""                  "ALLOW/IGMP"
ALLOW   any             udp:67,68                   ""                  "ALLOW/DHCP"
ALLOW   any             tcp:123                     ""                  "ALLOW/NTP"

ALLOW   any             udp:53                      ""                  "ALLOW/DNS"
ALLOW   any             tcp:80,443,8443             ""                  "ALLOW/http"    #
ALLOW   any             tcp:873                     ""                  "ALLOW/rsyncd"
ALLOW   any             tcp,udp:6677                ""                  "ALLOW/N2N"
#ALLOW   any             tcp,udp:1080                ""                  "ALLOW/Socks"

BLOCK   any             all                         ""                  "BLOCK/ALL"     # FINAL: Block All
# ==============================================================================

# ==============================================================================
# ==================================== NAT =====================================
#NAT    #dest           #source         #match      #TARGET             #comments

FORWARD 0.0.0.1         any             ""          DROP                "Black Hole"

# LAN -> N2N
FORWARD $N2N            any             "$TCPSYN"   "$TCPMSS 1300"      "N2N/TCPMSS"
NAT1    $N2N            any             ""          "$SNAT4N2N"         "NAT/N2N"

# N2N(gw only) -> LAN
FORWARD $LAN            $N2N            "-s $NGW"   ACCEPT              "NAT/N2N-LAN"

# DOCKER compatible
FORWARD docker0         any             ""          RETURN              "DOCKER compliance"
FORWARD any             docker0         ""          RETURN              "DOCKER compliance"

FORWARD $LAN            any             "$TRACKED"  ACCEPT              "NAT/LAN"
FORWARD any             $LAN            ""          ACCEPT              "NAT/LAN"

FORWARD any             any             ""          AFW-DROP            "NAT/END"       # FINAL: Abort Forwarding
# ==============================================================================

#$ipt -nvL
#$ipt -t nat -nvL

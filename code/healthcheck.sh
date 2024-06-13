#!/bin/bash

cd "$(dirname "$0")"

pidfile=/run/healthcheck.pid
pkill --pidfile "$pidfile" || true
echo "$$" > "$pidfile"

exec 1> >(tee -a /var/log/healthcheck.log) 2>&1

info () {
    echo -e "==\\033[32m $(date '+%Y/%m/%d %H:%M:%S'): $* \\033[0m=="
}

serversfile=/root/ip2route/dnsmasq.auto
JOBS=()

ip2route() {
    if /root/ip2route/tun0.sh; then
        info "setup dnsmasq serversfile $serversfile"
        uci set dhcp.@dnsmasq[0].serversfile="$serversfile"
    else
        info "clear dnsmasq serversfile"
        uci del dhcp.@dnsmasq[0].serversfile
    fi
    uci commit dhcp
    service dnsmasq restart
}

vpn_restart() {
    service sshtunnel restart
}

wan_restart() {
    ifdown wan
    ifup wan
}

reconnect() {
    read _ _ gw _ <<< $(ip route show default | sed -n '1p')
    if test -n "$gw" && ping -c1 baidu.com &> /dev/null; then
        info "check default route $gw, restart vpn"
        vpn_restart
    else
        info "check default route $gw failed, restart wan"
        wan_restart
    fi
}

info "start healthcheck($$)"

int=60
sleep 30    # start delay
ip2route    # init

while true; do
    if ping -c1 10.20.30.1 &> /dev/null; then
        if ! uci get dhcp.@dnsmasq[0].serversfile &> /dev/null; then
            ip2route
        fi
        sleep $int
    else
        if uci get dhcp.@dnsmasq[0].serversfile &> /dev/null; then
            ip2route
        fi

        reconnect
        sleep $((int / 2)) # half wait time
    fi
done &
JOBS+=($!)

while true; do
    if ! curl -s -o /dev/null -x socks5h://127.0.0.1:7070 --fail https://google.com; then
        info "check localhost:7070 failed, reconnect"
        reconnect
        sleep $((int / 2)) # half wait time
    else
        sleep $int
	fi
done &
JOBS+=($!)

cleanup() {
    kill -9 $(jobs -p | xargs) 2> /dev/null
}

trap_signal() {
    func=$1; shift
    for sig in "$@"; do
        trap "$func $sig" "$sig"
    done
}
trap_signal cleanup EXIT

info "wait for healthcheck(${JOBS[*]})"
wait "${JOBS[@]}"

info "healthcheck($$) exited, trap it"
exec "$0"
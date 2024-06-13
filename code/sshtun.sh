#!/bin/bash -e

while [ $# -gt 0 ]; do
    par="$1"; shift
    case "$par" in
        server|client)  mode="$par"     ;;
        *@*:*)          IFS='@:' read -r user host port <<< "$par"  ;;
        *@*)            IFS='@:' read -r user host <<< "$par"       ;;
        *.*.*.*)        ip="$par"       ;;
        *)              opt+=("-o $par")   ;; # ssh options
    esac
done
mode="${mode:-client}" # server or client
if [ "$mode" = "server" ]; then
    ip="${ip:-10.0.0.1}"
else
    ip="${ip:-10.0.0.254}"
fi
gw="${ip%.*}.1"
net="${ip%.*}.0/24"
port="${port:-22}"

pidfile=/run/sshtun.pid
pkill --pidfile "$pidfile" || true
echo "$$" > /run/sshtun.pid

# setup tun device if not exists
#  => openwrt: setup tun device with webui
dev=tun0
if ! ip link show "$dev"; then
    ip tuntap add "$dev" mode tun
    ip link set dev "$dev" up

    # setup ip & route
    ip addr flush dev "$dev" || true
    if [ "$mode" = "server" ]; then
        ip addr add "$gw/24" dev "$dev"
    else
        ip addr add "$ip/24" dev "$dev"
    fi
    ip route add "$net" via "$ip" || true
fi

if [ "$mode" = "server" ]; then
    # enable sshd tunnel
    if ! sshd -T | grep -q -i 'PermitTunnel yes'; then
        echo 'PermitTunnel yes' >> /etc/ssh/sshd_config
        systemctl restart sshd
    fi
    exit
fi

# debug with '-v'
ssh -v -N                       \
	-F none 					\
    -o TCPKeepAlive=yes         \
    -o ServerAliveInterval=10   \
    -o ServerAliveCountMax=3 	\
    -o Tunnel=point-to-point    \
    -w "${dev#tun}:0"           \
    "${opt[@]}"                 \
    -p "$port" "$user@$host" &
job=$!

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

# wait for background jobs
wait "$job"

# vim:ft=sh:syntax=bash:ff=unix:fenc=utf-8:et:ts=4:sw=4:sts=4
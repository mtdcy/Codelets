#!/bin/bash
# A pretty synology nas control script.
# Copyright (c) Chen Fang 2024, mtdcy.chen@gmail.com.

#set -eo pipefail

cd "$(dirname "$0")" || true

name="$(basename "$0")"

usage() {
    cat << EOF
$name <commands ...>

Supported commands:

    postinit        - [*] perform post init after boot.
    setfanspeed     - [*] set fan speed based on /etc/synoinfo.conf.
    sethosts        - [*] update /etc/hosts.
    iperfd          - [ ] start iperf3 server @ 5201.
    dockerd         - [*] setup dockerd.
    cleanup         - [ ] perform clean action on system.

Notes:
    [*] root privilege required

EOF
}

echocmd() {
    local cmd="${*//[[:space:]]+/ }"
    echo -e "--$CYAN $cmd $NC"
    eval -- "$cmd"
}

#REQUIREMENTS=(
#    inotifywait
#    iperf3
#)
#
#SYNOPKGS=(
#    inotify-tools
#    'SynoCli Monitor Tools'
#)
#
#for i in "${!REQUIREMENTS[@]}"; do
#    if ! which "${REQUIREMENTS[$i]}"; then
#        echo "== 请先安装${SYNOPKGS[$i]} =="
#        echocmd synopkg install_from_server "${SYNOPKGS[$i]}" # working?
#        which "${REQUIREMENTS[$i]}" || exit 1
#    fi
#done

info() { echo "== $(date '+%Y/%m/%d %H:%M:%S'): $name($$) $* == "; }

is_mounted() {
    mount | awk -v DIR="$1" '{ if ($3 == DIR) { exit 0 } } ENDFILE { exit -1 }'
}

postinit() {
    info "modprobe modules"
    # sensors:
    #  => refer to /usr/bin/rr-sensors.sh
    modprobe -v -a coretemp k10temp it87 adt7470 adt7475 #nct6683 nct6775

    info "apply sysctl"
    sysctl -w kernel.pid_max=4194304 # max value, or echo 4194304 > /proc/sys/kernel/pid_max
    sysctl -w fs.inotify.max_user_watches=1048576 # [8192, 1048576] since 5.11
    sysctl -w vm.swappiness=1 # default 10

    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv4.tcp_tw_reuse=1
    sysctl -w net.ipv4.tcp_fastopen=3 # FTO: tcp fast open
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 # no IPv6

    # make sure non-root user can ping
    #  => https://www.suse.com/support/kb/doc/?id=000020581
    sysctl -w net.ipv4.ping_group_range="0 2147483647"

    # bridge network filter => cause performance issue, disable it
    #modprobe br_netfilter
    #sysctl -w net.bridge.bridge-nf-call-iptables=1
    #sysctl -w net.bridge.bridge-nf-call-ip6tables=1
    #sysctl -w net.bridge.bridge-nf-call-arptables=1

    info "setup /etc/timezone"
    realpath /etc/localtime | sed 's:/usr/share/zoneinfo/::' | tee /etc/timezone
    # => also need to `export TZ=$(cat /etc/TZ)` in .profile for `date` to work properly

    info "setup ovs bridge"
    ovs-vsctl del-br ovs_eth1
    ovs-vsctl del-br ovs_eth2
    ovs-vsctl del-br ovs_eth3

    ovs-vsctl add-port ovs_eth0 eth1
    ovs-vsctl add-port ovs_eth0 eth2
    ovs-vsctl add-port ovs_eth0 eth3

    ovs-vsctl show
    #ovs-dpctl show

    # ovs-vsctl add-bond ovs_eth0 bond23 eth2 eth3 lacp=active
    # ovs-vsctl set port bond23 bond_mode=balance-slb
    # ovs-appctl bond/show

    # enable promisc
    physdev=(ovs_eth0 eth0 eth1 eth2 eth3)
    for dev in "${physdev[@]}"; do
        ip link set dev "$dev" promisc on
    done

    info "setup cpufreq"
    # turbo boost
    echo 1 > /sys/devices/system/cpu/cpufreq/boost
    # powersave performance userspace schedutil
    #  => powersave not saving power, why???
    #governor="performance"
    #cpuid=0
    #ncpu=$(grep -c processor /proc/cpuinfo)
    #while [ "$cpuid" -lt "$ncpu" ]; do
    #    echo "$governor" > /sys/devices/system/cpu/cpu$cpuid/cpufreq/scaling_governor
    #    cpuid=$((cpuid + 1))
    #done

    # 官方警告：不要在共享文件夹之外存放数据，否则升级时可能丢失
    info "setup mount points"
    while read -r dir target; do
        #umount "$target" 2>/dev/null || true
        is_mounted "$target" && continue

        mkdir -pv "$target"
        mount -v -o bind "$dir" "$target"
    done <<< "$(grep -v "^#" bindings | sed '/^$/d')"

    info "setup /etc/motd"
    echo -e "\nSynoNAS powered by M.2 x5\n" | tee /etc/motd

    info "setup docker group"
    synogroup --get docker &> /dev/null || synogroup --add docker
    # => add your user to group docker manually
    [ -e /var/run/docker.socket ] && chgrp -v docker /var/run/docker.socket
}

setfanspeed() {
    if ! [ -e /etc/fancontrol ]; then
        cat > /etc/fancontrol << EOF
INTERVAL=10
DEVPATH=hwmon2=devices/platform/it87.2608
DEVNAME=hwmon2=it8613
FCTEMPS=hwmon2/pwm3=hwmon2/temp2_input
FCFANS=hwmon2/pwm3=hwmon2/fan3_input
MINTEMP=hwmon2/pwm3=30
MAXTEMP=hwmon2/pwm3=50
MINSTART=hwmon2/pwm3=80
MINSTOP=hwmon2/pwm3=20
EOF
    fi

    IFS='=' read -r _ MODE _ <<< "$(grep fan_config_type_internal /etc/synoinfo.conf)"

    case "${MODE//\"/}" in
        low)
            sed -e 's/\(MINTEMP=.*\)=[0-9]\+$/\1=30/' \
                -e 's/\(MAXTEMP=.*\)=[0-9]\+$/\1=55/' \
                -i /etc/fancontrol
            ;;
        high)
            sed -e 's/\(MINTEMP=.*\)=[0-9]\+$/\1=30/' \
                -e 's/\(MAXTEMP=.*\)=[0-9]\+$/\1=50/' \
                -i /etc/fancontrol
            ;;
        full)
            sed -e 's/\(MINTEMP=.*\)=[0-9]\+$/\1=20/' \
                -e 's/\(MAXTEMP=.*\)=[0-9]\+$/\1=25/' \
                -i /etc/fancontrol
            ;;
    esac

    killall fancontrol || true
    rm -f /var/run/fancontrol.pid || true
    fancontrol &
}

sethosts() {
    grep -v 127.0.0.1 /etc/hosts > /tmp/hosts-$$

    {
        printf "127.0.0.1 localhost\n"
        printf "127.0.0.1 %s %s\n" \
            "$(hostname)" \
            "$(docker exec swag nginx -T 2>/dev/null | \
                grep "^\s*[^#]\s*server_name .*\.mtdcy.top" | \
                sed 's/^.*server_name\s\+\(.*\.mtdcy\.top\).*$/\1/' | \
                uniq | \
                xargs
            )"
    } >> /tmp/hosts-$$

    mv /tmp/hosts-$$ /etc/hosts
    cat /etc/hosts
}

iperfd() {
    pkill -f iperf3 || true
    iperf3 -s &
    echo "iperf3 server $! started"
}

dockerd() {
  #"registry-mirrors":["https://registry.docker-cn.com"],
cat > /var/packages/ContainerManager/etc/dockerd.json << EOF
{
  "hosts": ["unix:///var/run/docker.sock", "tcp://0.0.0.0:2375"],
  "data-root": "/var/packages/ContainerManager/var/docker",
  "storage-driver":"btrfs",
  "log-driver":"syslog",
  "log-opts": {
    "syslog-address": "udp://127.0.0.1:514",
    "syslog-format": "rfc5424",
    "syslog-facility": "daemon",
    "tag": "{{.Name}}/{{.ID}}"
  }
}
EOF
# https://docs.docker.com/config/containers/logging/syslog/
# rfc3164 => BSD, rfc5424 => IETF

echocmd synopkg restart ContainerManager & # takes time
}

cleanup() {
    if pgrep dockerd; then
        info "cleanup Docker images ..."
        docker image prune --all --force --filter "until=168h" # 7days ago

        # dangling
        info "cleanup Docker images/dangling ..."
        dangling="$(docker images --filter "dangling=true" --quiet --no-trunc)"
        [ -z "$dangling" ] || docker rmi --force "$dangling"

        info "cleanup Docker build cache ..."
        if which docker-buildx &> /dev/null; then
            docker-buildx prune --all --force --filter "until=168h"
        else
            docker buildx prune --all --force --filter "until=168h"
        fi

        #info "cleanup Container log ..."
        #find Docker -name "log" -type d |
        #    while read -r dir; do
        #        find "$dir" -type f -mtime +30 -exec rm -fv {} \;
        #    done
    fi

    if which brew &> /dev/null; then
        info "cleanup Homebrew ..."
        brew cleanup --prune=all
    fi

    while read -r path days time; do
        time="${time:-mtime}"
        info "cleanup $path old than $days days($time)..."
        if [ "$days" -gt 0 ]; then
            find "$path" -type f "-$time" "+$days" -exec rm -fv {} \;
        fi
        find "$path" -size 0 -exec rm -rfv {} \;
    done <<< "$(grep -v "^#" trashlist | sed '/^$/d')"
}

shr_sync_preinit() {
    echo ""
}

handle_commands() {
    echo "== handle $* =="
    for x in "$@"; do
        case "$x" in
            usage|help)
                usage
                continue
                ;;
        esac
        echo "== handle $x =="
        eval "$x"
    done
}

COMMANDS=(postinit setfanspeed sethosts iperfd dockerd cleanup usage)

info "start $* ..."
if [ $# -eq 0 ]; then
    PS3="Please select: "
    set -o posix # do not block trap
    select x in "${COMMANDS[@]}" quit; do
        [ "$x" = "quit" ] && break
        handle_commands "$x"
        REPLY=  # show menu again
        echo "" # newline
    done
    set +o posix
    unset PS3
else
    handle_commands "$@"
fi

#disown -a

#!/bin/bash -e

error() { echo -e "!!\\033[31m $* \\033[0m"; }
info()  { echo -e "!!\\033[32m $* \\033[0m"; }
warn()  { echo -e "!!\\033[33m $* \\033[0m"; }

echofunc() {
    local cmd="${*//[[:space:]]+/ }"
    echo -e "\n==\\033[34m $cmd \\033[0m"
    eval -- "$cmd"
}

echocmd() {
    local cmd="${*//[[:space:]]+/ }"
    echo -e "\n==\\033[35m $cmd \\033[0m"
    eval -- "$cmd"
}

# from iec to Bytes, for size math
from_iec() {
    local sz="${1:-$(cat)}"
    sz="${sz^^%B}"
    numfmt --from iec "$sz"
}

# swap on|off
swap() {
    local swapfile=/swap.img
    case "$1" in
        on)
            local bytes=${2:-$(grep MemTotal /proc/meminfo | awk '{print $2}')K}
            bytes=$(from_iec "$bytes")
            dd if=/dev/zero of=$swapfile bs=1M count=$((bytes / 1048576))
            chmod 0600 $swapfile
            echocmd mkswap $swapfile
            echocmd swapon $swapfile

            sed -i "\|$swapfile|d" /etc/fstab
            echocmd "echo $swapfile none swap sw 0 0 >> /etc/fstab"
            ;;
        off)
            echocmd swapoff

            sed -i "\|$swapfile|d" /etc/fstab
            ;;
        status|*)
            echocmd swapon --show
            ;;
    esac
}

"$@"

# vim:ft=sh:ff=unix:fenc=utf-8:et:ts=4:sw=4:sts=4

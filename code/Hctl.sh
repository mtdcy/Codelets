#!/bin/bash
#
# A Hybrid Raid control script.
# Copyright (c) Chen Fang 2024, mtdcy.chen@gmail.com
#
# Change logs:
#
# -

NAME="$(basename "$0")"
VERSION=0.1

set -eo pipefail

error() { echo -e "== \\033[31m$*\\033[39m =="; }
info()  { echo -e "== \\033[32m$*\\033[39m =="; }
warn()  { echo -e "== \\033[33m$*\\033[39m =="; }

headings() {
    cat << EOF
$NAME $VERSION (c) Chen Fang 2024, mtdcy.chen@gmail.com
EOF
}

echocmd() {
    local cmd="${*//[[:space:]]+/ }"
    echo -e "==\\033[34m cmd: $cmd \\033[39m=="
    eval -- "$cmd"
}

# $0 <value>
ans_is_true() {
    [ "$1" = "1" ] || [ "${1,,}" = "y" ] || [ "${1,,}" = "yes" ]
}

par_is_size() {
    [[ "${1^^}" =~ ^[0-9\.]+[KMGTP]?I?B?$ ]]
}

# $0 <prefix>
block_device_next() {
    for i in {0..255}; do
        if ! [ -e "$1$i" ]; then
            echo "$1$i"
            return 0
        fi
    done
}

disk_help() {
    cat << EOF
$(basename "$0") disk <command> [parameters]
$(basename "$0") disk /dev/sda <command> [parameters]

Commands and parameters:
    status                      : Dump disk informations
    gpt                         : Create a new GPT partition table
    part [size]                 : Create a new partion with given size in {K,M,G,T,P} or max
    sectors <total|free|last>   : Get total(default)/free/last sectors
    help                        : Show this help messages
EOF
}

disk() {
    # Top level: disk <command>
    case "$1" in
        info)
            echocmd lsblk -o +MODEL,SERIAL
            return
            ;;
        help)
            disk_help
            return
            ;;
    esac

    # part <disk> <command> [parameters ...]
    local DISK="$1"; shift
    local command="$1"; shift

    if ! test -b "$DISK"; then
        error "$DISK: no such block device"
        return 1
    fi

    local DISKNAME DISKTYPE
    DISKNAME="$(basename "$DISK")"
    DISKTYPE="$(lsblk "$DISK" -o TYPE 2> /dev/null | sed -n '2p')"

    case "$command" in
        status) # status [verbose]
            info "status of $DISK ($(cat "/sys/block/$DISKNAME/device/state"))"

            if [ "${1,,}" = "verbose" ]; then
                if which smartctl &> /dev/null; then
                    echocmd smartctl -i -H -n standby "$DISK" # don't wakeup DISK
                else
                    echocmd hdparm -C "$DISK"
                fi

                # show partitions
                echocmd parted "$DISK" print free
                warn "'parted' used 1000-based numbers"
            fi
            echocmd lsblk "$DISK"
            ;;
        devices) # return partitions
            local parts
            parts=($(parted "$DISK" print | grep " [0-9]\+ " | awk '{ print  $1}' | xargs))
            echo "${parts[@]/#/$DISK}"
            ;;
        size) # size [total|free], default: total, return in MB
            #!! 'size free' on partition is undefined       !!#
            local total end
            total=$(parted "$DISK" unit B print | grep "^Disk $DISK:" | awk -F':' '{print $2}')
            total="$(numfmt --from si "${total%B}")"
            case "$1" in
                free)
                    # find out the last partition:
                    # Number  Start   End        Size       File system  Name     Flags
                    #  1      1.05MB  1000205MB  1000204MB               primary
                    end=$(parted "$DISK" unit B print 2>/dev/null | grep "^ [0-9]\+ " | tail -1 | awk '{print $3}') || true
                    end=${end:-0}
                    echo "$(((total - ${end%B}) / 1048576))MB"
                    ;;
                total|*)
                    echo "$((total / 1048576))"MB
                    ;;
            esac
            ;;
        gpt)
            info "$DISK: new GPT partition table"
            read -r -p "It will erase all data from $DISK, continue? [y/N]" ans
            ans=${ans:-N}
            ans_is_true "$ans" || return 1

            wipefs --all --force "$DISK" > /dev/null
            echocmd parted -s "$DISK" mklabel gpt || {
cat << EOF

    'parted $DISK mklabel gpt' may fail because:

    1. $DISK may be busy because it is a raid member;

    Please do:

    1. find out which raid holds $DISK with 'raid ls'
    2. destroy the raid with 'raid /dev/mdX destroy'

EOF
                return 1
            }
            # 'You should reboot now before making further changes.'
            partprobe "$DISK" > /dev/null || true
            ;;
        part) # part [fs] [size], size in [KMGTP]B
            local size fs
            while test -n "$1"; do
                if par_is_size "$1"; then
                    size="$1"
                else
                    fs="$1"
                fi
                shift
            done

            local pno
            pno="$(parted "$DISK" print | grep -c "^ [0-9]\+ ")" || true
            pno=$((pno + 1))

            if test -z "$size"; then
                info "$DISK: create single partition"
                # erase all partition(s) and create a new one
                echo yes | DISK "$DISK" gpt > /dev/null
                echocmd parted -s --fix "$DISK" mkpart "part$pno" "$fs" "2048s" 100%
            else
                local nsz total start end
                # DISK /dev/sdd: 1000205MB
                total=$(parted "$DISK" unit MB print | grep "^Disk $DISK:" | awk -F':' '{print $2}')
                # Number  Start   End        Size       File system  Name   Flags
                #  1      1.05MB  1000205MB  1000204MB               part1
                start=$(parted "$DISK" unit MB print | grep "^ [0-9]\+ " | tail -1 | awk '{print $3}') || true

                # natural size
                size=$(numfmt --from iec "${size%B}")
                nsz="$(numfmt --to iec "${size}")B"

                #!! everyone use 1024-base, but parted is 1000-based !!#
                size=$((size / 1000000)) # to 1000-based MB
                info "$DISK: append a $nsz partition"

                # remove suffix MB
                total=${total%MB}
                start=${start%MB}
                free=$((total - start))

                if [ "$((start + size))" -gt "$total" ]; then
                    error "$DISK: request size($nsz) exceed limit($free)"
                    return 1
                fi

                # put ~1M free space between partitions
                if [ -n "$start" ]; then
                    start=$((start + 1))
                    end=$((start + 1 + size))
                else
                    # parted has trouble to align the first partition
                    start="2048s" # ~1M
                    end=$((1 + size))
                fi
                # double check on end
                if [ "$end" -gt "$total" ]; then
                    end="$total"
                fi
                echocmd parted -s --fix "$DISK" unit MB mkpart "part$pno" "$fs" "$start" "$end"
            fi

            echocmd partprobe "$DISK" || true

            if [ -n "$fs" ]; then
                if ! which "mkfs.$fs" &> /dev/null; then
                    error "$DISK: bad fs $fs or missing mkfs.$fs"
                    return 1
                fi

                # ugly code to get partition devfs path
                local part="$DISK$pno"

                info "$DISK: mkfs.$fs @ $part"
                echocmd wipefs --force "$part"
                echocmd mkfs -t "$fs" "$part"
            fi
            ;;
        delete)
            info "$DISK: delete from kernel"
            read -r -p "** Dangerous, are you sure to delete $DISK? [y/N]" ans
            ans_is_true ans || return 1

            echo 1 > "/sys/block/$DISKNAME/device/delete"
            ;;
        fstype)
            case "$DISKTYPE" in
                part|lvm)
                    parted "$DISK" print | grep ' [0-9]\+ ' | awk '{print $5}'
                    ;;
                *)
                    error "$DISK: get fstype on unsupported device type($DISKTYPE)"
                    return 1
                    ;;
            esac
            ;;
        mkfs) # mkfs <fstype>
            case "$DISKTYPE" in
                part|lvm)
                    echocmd mkfs -t "$1" "$DISK"
                    ;;
                *)
                    error "$DISK: mkfs on unsupported device type($DISKTYPE)"
                    return 1
                    ;;
            esac
            ;;
        *)
            disk_help
            ;;
    esac
}

raid_help() {
    cat << EOF
$(basename "$0") raid <command> [parameters]
$(basename "$0") raid /dev/md0 <command> [parameters]

Commands and parameters:
    info                                : Print all raid devices informations
    create [raid1] /dev/sda1 /dev/sdb1  : Create a new raid device with given partitions
    add /dev/sde1                       : Add or replace failure device with given partition(s)
                                        : Expand the raid with given partition(s).
    destroy                             : Destroy the raid device
    check <start|stop|status>           : Start or stop raid check, or get its status
    help                                : Show this help message

Supported levels: raid0 raid1 raid5 raid6 raid10, auto

EOF
}

raid() {
    # top level: raid <command>
    case "$1" in
        info)
            echocmd cat /proc/mdstat
            return
            ;;
        scan)
            echocmd mdadm --assemble --scan
            ;;
        ls)
            while read -r mddev; do
                echo "/dev/$mddev: $(raid /dev/$mddev devices)"
            done < <(cat /proc/mdstat | grep "^md[0-9]\+ :" | awk -F':' '{print $1}')
            ;;
        config)
            mkdir -pv /etc/mdadm

cat > /etc/mdadm/mdadm.conf << EOF
# Generated by $(basename "$0") - $(date)
HOMEHOST <ignore>
#DEVICE containers partitions
DEVICE partitions
CREATE owner=root group=disk mode=0660 auto=yes
MAILADDR root
$(mdadm --detail --scan --verbose)
EOF
            # fix md0 been reanemd to md127 after reboot
            update-initramfs -u
            ;;
        help)
            raid_help
            return
            ;;
    esac

    # raid <mddev> <command> [parameters]
    local MDDEV="$1"; shift
    local command="$1"; shift
    case "$command" in
        status) # status
            [ -b "$MDDEV" ] || return 1
            echocmd mdadm --query --detail "$MDDEV"
            ;;
        test)
            [ -b "$MDDEV" ] || return 1
            echocmd mdadm --detail --test "$MDDEV"
            ;;
        devices) # devices [active|spare], default: active
            [ -b "$MDDEV" ] || return 1
            case "$1" in
                spare)
                    mdadm --detail "$MDDEV" | grep "spare" | awk '{print $6}' | xargs
                    ;;
                active|*)
                    mdadm --detail "$MDDEV" | grep "active sync" | awk '{print $7}' | xargs
                    ;;
            esac
            ;;
        size) # <total|parts>, default: total
            [ -b "$MDDEV" ] || return 1
            local size
            case "$1" in
                part*)
                    # Used Dev Size : 976630464 (931.39 GiB 1000.07 GB)
                    size=$(mdadm --detail "$MDDEV" | grep 'Used Dev Size :' | awk -F':' '{print $2}' | awk '{print $1}')
                    ;;
                total|*)
                    # Array Size : 976630464 (931.39 GiB 1000.07 GB)
                    size=$(mdadm --detail "$MDDEV" | grep 'Array Size :' | awk -F':' '{print $2}' | awk '{print $1}')
                    ;;
            esac
            numfmt --from iec --to iec "$size"K
            ;;
        create) # create level <partitions ...>
            local level="$1"; shift
            local mindev=2
            case "$level" in
                raid0|0)    mindev=2 ;;
                raid1|1)    mindev=2 ;;
                raid5|5)    mindev=3 ;;
                raid6|6)    mindev=4 ;;
                raid10|10)  mindev=4 ;;
                auto)
                    case "$#" in
                        2)  mindev=2; level=raid1 ;;
                        *)  mindev=3; level=raid5 ;;
                    esac
                    ;;
            esac

            info "create raid $MDDEV($level) with $*"
            if [ $# -lt "$mindev" ]; then
                error "raid($level) requires at least $mindev devices"
                return 1
            fi

            #echo yes | echocmd mdadm --verbose --create "$MDDEV" --force --level="$level" --raid-devices="$#" "$@"
            echo yes | echocmd mdadm \
                --verbose            \
                --create "$MDDEV"    \
                --force              \
                --assume-clean       \
                --level="$level"     \
                --raid-devices="$#"  \
                "$@"
            ;;
        stop)
            info "stopping $MDDEV, it can be assembled again"
            echocmd mdadm --action "idle" "$MDDEV" || true
            umount "$MDDEV" || true
            echocmd mdadm --verbose --stop "$MDDEV"
            echocmd mdadm --verbose --remove "$MDDEV" 2> /dev/null || true
            ;;
        destroy) # !!! Dangerous !!!
            warn "destroying $MDDEV, it cann't be assembled again"
            read -r -p "** Dangerous, are you sure to continue? [y/N]" ans
            ans="${ans:-N}"
            ans_is_true "$ans" || return 1

            # stop check/sync
            echocmd mdadm --action "idle" "$MDDEV" || true
            umount "$MDDEV" || true

            IFS=' ' read -r -a parts <<< "$(mdadm --detail "$MDDEV" | sed -n 's@^ .*\(/dev/.*\)$@\1@p' | xargs)"

            echocmd mdadm --verbose --stop "$MDDEV"
            echocmd mdadm --verbose --remove "$MDDEV" 2> /dev/null || true

            # leave the devices as is
            for x in "${parts[@]}"; do
                echocmd mdadm --zero-superblock "$x"
            done
            ;;
        add) # add [spare] <partitions ...>
            #!! replace failed devices or grow the raid !!#
            local spare
            case "$1" in
                spare)  spare=true; shift ;;
            esac

            echocmd mdadm --action "idle" "$MDDEV"

            local MDDEVCNT
            MDDEVCNT="$(mdadm --detail "$MDDEV" | grep -F 'Raid Devices :' | awk -F':' '{print $2}')"

            # remove failed parts
            if ! mdadm --detail --test "$MDDEV" >/dev/null; then
                warn "$MDDEV: degraded, remove failed device(s)"

                # remove failed devices
                while read -r line; do
                    IFS=' ' read -r _ _ _ _ _ b _ <<< "$line"
                    echocmd mdadm --manage "$MDDEV" --fail "$b" --remove "$b" --force
                done < <(mdadm --detail "$MDDEV" | grep "faulty")

                # remove detached devices
                echocmd mdadm "$MDDEV" --fail detached --remove detached
                # add new devices
            fi
            # add devices as hot spare
            echocmd mdadm --manage "$MDDEV" --add "$@"

            # grow if not add as spare
            if test -z "$spare"; then
                echocmd mdadm --grow "$MDDEV" --raid-devices="$((MDDEVCNT + $#))"
            fi

            # check: 'Device or resource busy'?
            echocmd mdadm --action "check" "$MDDEV" || true
            ;;
        remove) #
            ;;
        extend)
            ;;
        check) # check <start|stop>, default: start
            case "$1" in
                status)
                    echocmd "cat /sys/block/$(basename "$MDDEV")/md/mismatch_cnt"
                    ;;
                stop)
                    #echocmd "echo idle > /sys/block/$(basename "$MDDEV")/md/sync_action"
                    echocmd mdadm --action "idle" "$MDDEV"
                    ;;
                repair)
                    echocmd mdadm --action "repair" "$MDDEV"
                    ;;
                start|*)
                    #echocmd "echo check > /sys/block/$(basename "$MDDEV")/md/sync_action"
                    echocmd mdadm --action "check" "$MDDEV"
                    ;;
            esac
            ;;
        set) #
            case "$1" in
                faulty)
                    warn "$MDDEV: simulate a drive failure"
                    echocmd mdadm --manage --set-faulty "$MDDEV" "$@"
                    ;;
            esac
            ;;
        help|*)
            raid_help
            ;;
    esac
}

volume_help() {
    cat << EOF
$(basename "$0") volume <command> [parameters]
$(basename "$0") volume lv0 <command> [parameters]

Commands and parameters:
    info                        : Print all|volume informations
    create /dev/md0 /dev/md1    : Create a new volume with given devices
    destroy                     : Destroy the given volume
    help                        : Print this help message
EOF
}

# volume /dev/vg0/lv0 <command> ...
volume() {
    # top level: volume <command>
    case "$1" in
        info)
            echocmd lvs
            echocmd vgs
            echocmd pvs
            return
            ;;
        help)
            volume_help
            return
            ;;
    esac

    # volume <name> <command> [options]
    local LVDEV="$1"; shift
    local command="$1"; shift

    # test LVDEV
    if [ "$command" != "create" ] && [ ! -b "$LVDEV" ] ; then
        error "$command $*: device not exists"
        return 1
    fi

    local LVNAME VGNAME LVTYPE LVSIZE
    IFS='/' read -r _ _ VGNAME LVNAME <<< "$LVDEV"

    case "$command" in
        status)
            [ -b "$LVDEV" ] || return 1
            echocmd vgdisplay --verbose "$VGNAME" -S lvname="$LVNAME"
            ;;
        size)
            [ -b "$LVDEV" ] || return 0 #
            IFS=' <' read -r _ _ _ LVSIZE <<< "$(lvs --noheadings -S lvname="$LVNAME")"
            #!! lvm use [kmgtp] with 1024 base !!#
            echo "$(numfmt --from auto --to iec --round=down "${LVSIZE^^}i")B"
            ;;
        mount) # mount [dir], if no dir, return current mount point
            if [ $# -gt 0 ]; then
                umount "$LVDEV" &>/dev/null || true
                sed -i ":^$LVDEV.*$:d;\$a $LVDEV $1 auto defaults,nofail 0 0" /etc/fstab
                mkdir -pv "$1"
                which systemctl &>/dev/null && systemctl daemon-reload || true
                mount "$1"
            else
                lsblk -o MOUNTPOINT "$LVDEV" | sed -n '2p'
            fi
            ;;
        devices)
            pvs --noheadings -S vgname="$VGNAME" -o pv_name | xargs
            ;;
        create) # create [linear|stripe|thin] [size] <pv devices ...>
            if [ -b "$LVDEV" ]; then
                error "$LVDEV: volume already exists"
                return 1
            fi

            LVTYPE="linear"
            case "$1" in
                linear|striped)
                    LVTYPE="$1"; shift
                    ;;
                thin)
                    LVTYPE="thin-pool"; shift
                    ;;
            esac
            info "$LVDEV: create $LVTYPE volume with $*"

            if par_is_size "$1"; then
                LVSIZE="$1"; shift
            fi

            # pv check: all devices must belong to the same group
            for _pv in "$@"; do
                local _vg
                IFS=' ' read -r _vg <<< "$(pvs --noheadings -o vg_name "$_pv")" || true
                if [ -n "$_vg" ] && [ "$_vg" != "$VGNAME" ]; then
                    error "$_pv belongs to group $_vg, expected $VGNAME"
                    return 1
                fi
            done

            if ! lvs "$VGNAME" > /dev/null; then
                echocmd pvcreate --verbose "$@" || true
                echocmd vgcreate --verbose "$VGNAME" "$@"
            fi

            # create logical volume, default: take 100% free space
            if [ -n "$LVSIZE" ]; then
                echo y | echocmd lvcreate   \
                    --verbose               \
                    --type "$LVTYPE"        \
                    --size "$LVSIZE"        \
                    --name "$LVNAME"        \
                    "$VGNAME"
            else
                echo y | echocmd lvcreate   \
                    --verbose               \
                    --type "$LVTYPE"        \
                    --extents '100%FREE'    \
                    --name "$LVNAME"        \
                    "$VGNAME"
            fi
            ;;
        destroy) # !! Dangerous !!
            if [ "$(lvs --noheadings -S lvname="$LVNAME" | wc -l)" -eq 0 ]; then
                error "volume $LVNAME not exists"
                return 1
            fi

            # umount volume
            echocmd umount "$LVDEV" || true

            # remove lv0
            echocmd lvremove --verbose --yes "$LVDEV"

            # remove vg if no more volume on it
            if [ "$(lvs --noheadings "$VGNAME" | wc -l)" -eq 0 ]; then
                IFS=' ' read -r -a devices <<< "$(pvs --noheadings -S vgname="$VGNAME" -o pv_name | xargs)"
                echocmd vgremove --verbose "$VGNAME" # no '--yes' here
                for dev in "${devices[@]}"; do
                    echocmd pvremove --verbose "$dev"
                done
            fi
            ;;
        add) # add <devices>
            echocmd pvcreate --verbose "$@"
            echocmd vgextend --verbose "$VGNAME" "$@"

            local fstype
            fstype="$(disk "$LVDEV" fstype)"
            case "$fstype" in
                btrfs)
                    echocmd lvextend            \
                        --verbose               \
                        --extents '+100%FREE'   \
                        "$LVDEV" "$@"

                    # BTRFS needs to be mounted to be able to resize the partition.
                    local mounted
                    mounted="$(lsblk -o MOUNTPOINT "$LVDEV" | sed -n '2p')"
                    if test -z "$mounted"; then
                        mkdir -pv /tmp/btrfs-$$
                        mount -t btrfs "$LVDEV" /tmp/btrfs-$$
                        echocmd btrfs filesystem resize max /tmp/btrfs-$$
                        umount "$LVDEV"
                    else
                        echocmd btrfs filesystem resize max "$mounted"
                    fi
                    ;;
                *)
                    echocmd lvextend            \
                        --verbose               \
                        --extents '+100%FREE'   \
                        --resizefs              \
                        "$LVDEV" "$@"
                    ;;
                esac
            ;;
        help|*)
            error "unknown command $command"
            volume_help
            ;;
    esac
}

hybrid_help() {
    cat << EOF
$(basename "$0") hybrid volume0 <command> [parameters]

Commands and parameters:
    create /dev/sda /dev/sdb            : Create a hybrid volume
EOF
}

# hybrid /dev/Hg0/H0 create /dev/sda /dev/sdb ...
hybrid() {
    # top level:
    case "$1" in
        ls)
            local name size type misc
            local OPTS="NAME,SIZE,TYPE,MOUNTPOINTS,FSTYPE,UUID"
            printf "%-14s %7s %7s %s\n" "NAME" "SIZE" "TYPE" "MISC"

            for LVNAME in $(lvs --noheadings -o lv_name | xargs); do
                # ls logical volume
                IFS=' ' read -r name size type misc <<< "$(                    \
                    lsblk -o "$OPTS" /dev/*/"$LVNAME" | sed -n '2p' \
                )"
                printf "%-14s %7s %7s %s\n" "$name" "$size" "$type" "$misc"
                for pv in $(volume "$LVNAME" devices); do
                    # ls phy volume/raid device
                    IFS=' ' read -r name size type misc <<< "$( \
                        lsblk -o "$OPTS" "$pv" | sed -n '2p'    \
                    )"
                    printf "├─%-12s %7s %7s %s\n" "$name" "$size" "$type" "$misc"
                    for part in $(raid "$pv" devices); do
                        # ls raid parts
                        IFS=' ' read -r name size type misc <<< "$( \
                            lsblk -o "$OPTS" "$part" | sed -n '2p'  \
                        )"
                        printf "│ ├─%-10s %7s %7s %s\n" "$name" "$size" "$type" "$misc"
                    done
                done
            done
            ;;
        info)
            volume info
            raid info
            disk info
            return
            ;;
        help)
            hybrid_help
            return
            ;;
    esac

    local HDEV="$1"; shift
    local command="$1"; shift

    local Hg H

    IFS='/' read -r _ _ Hg H <<< "$HDEV"
    if [ -z "$Hg" ] || [ -z "$H" ]; then
        error "$HDEV: bad devfs, expected /dev/Hg0/H0"
        return 1
    fi

    case "$command" in
        status)
            echo "    --- $HDEV ($(volume "$HDEV" mount)) ---"
            printf "%14s : %s\n" "Total Size"   "$(volume "$HDEV" size)"
            printf "%14s : %s\n" "Free Size"    "$(volume "$HDEV" size free)"
            printf "%14s : %s\n" "File System"  "$(disk "$HDEV" fstype)"

            echo -e "\n    --- devices ---"
            local devices size free
            for dev in $(hybrid "$HDEV" devices); do
                size="$(disk "$dev" size)"
                free="$(disk "$dev" size free)"
                printf "%14s : %s" "$dev" "$(numfmt --from iec --to iec "${size%B}")B"
                if [ "$free" != "0MB" ]; then
                    printf " (%s free)" "$(numfmt --from iec --to iec "${free%B}")B"
                fi
                printf "\n"
            done
            ;;
        size) # size [total|free], default: total
            volume "$HDEV" size "$@"
            ;;
        devices)
            local devices=()
            for mddev in $(volume "$HDEV" devices); do
                local parts
                read -r -a parts <<< "$(raid "$mddev" devices)"
                devices+=("${parts[@]}")
            done
            printf "%s\n" "${devices[@]}" | \
                sed 's/\(sd[a-z]\)[0-9]\+$/\1/g' | \
                sed 's/\(nvme[0-9]\+n[0-9]\+\)p[0-9]\+/\1/g' | \
                sort -u | xargs
            ;;
        mount) # mount [mountpint], if no mountpint specified, return current one
            volume "$HDEV" mount "$@"
            ;;
        destroy)
            info "destroy $HDEV"
            IFS=' ' read -r -a mddevs <<< "$(volume "$HDEV" devices)"
            volume "$HDEV" destroy
            for mddev in "${mddevs[@]}"; do
                info "destroy $mddev"
                echo yes | raid "$mddev" destroy
            done
            ;;
        create) # [fs] <devices ...>
            local FSTYPE="btrfs"
            local DEVICES=()
            while [ $# -gt 0 ]; do
                local opt="$1"; shift
                case "$opt" in
                    ext*|*fs)   FSTYPE="$opt"       ;;
                    *)          DEVICES+=("$opt")   ;;
                esac
            done

            info "$HDEV: create volume($FSTYPE) with devices ${DEVICES[*]}"
            read -r -p "The disks will be wipe out, continue? [y/N] " ans
            ans=${ans:-N}
            ans_is_true "$ans" || return 1

            # wipe disks
            for disk in "${DEVICES[@]}"; do
                echo yes | disk "$disk" gpt
            done

            local PVDEVICES=()
            while [ "${#DEVICES[@]}" -ge 2 ]; do
                local MDDEVICES=()
                local MDPARTS=()
                local MDPARTSIZE=$((2 ** 63 - 1)) # max sint

                local free
                for disk in "${DEVICES[@]}"; do
                    free=$(disk "$disk" size free)
                    free=${free%MB}
                    free=${free%.*}

                    # if free size < 128M
                    if [ "$free" -lt 128 ]; then
                        continue
                    fi

                    if [ "$free" -lt "$MDPARTSIZE" ]; then
                        MDPARTSIZE="$free"
                    fi
                    MDDEVICES+=("$disk")
                done

                # Done? OR, short of devices
                if [ "${#MDDEVICES[@]}" -lt 2 ]; then
                    break;
                fi

                # create parts
                for disk in "${MDDEVICES[@]}"; do
                    local part="$disk$((${#PVDEVICES[@]} + 1))"
                    info "create $part $MDPARTSIZE"
                    disk "$disk" part "$MDPARTSIZE"MB
                    MDPARTS+=("$part")
                done

                # create raid
                local MDDEV="$(block_device_next /dev/md)"
                raid "$MDDEV" create auto "${MDPARTS[@]}" || true

                # !! recreate raid may end with unexpected devfs !!
                if ! test -e "$MDDEV"; then
                    error "create $MDDEV failed"
cat << EOF
    Create mdadm raid failed, possible cause:

    1. The raid has been assembled by system, which make devices busy;
    2. The raid was stopped and re-created with different devfs/name;
EOF
                    return 1
                fi

                PVDEVICES+=("$MDDEV")
                DEVICES=("${MDDEVICES[@]}")
            done

            # wait until raids are ready
            sleep 3

            # create volume
            volume "$HDEV" create "${PVDEVICES[@]}"

            if [ -n "$FSTYPE" ]; then
                disk "$HDEV" mkfs "$FSTYPE"
            fi
            ;;
        add) # add <devices ...>
            local DEVICES
            IFS=' ' read -r -a DEVICES <<< "$@"

            info "$HDEV: add devices ${DEVICES[*]}"
            read -r -p "The disks will be wipe out, continue? [y/N] " ans
            ans=${ans:-N}
            ans_is_true "$ans" || return 1

            # wipe disks
            for disk in "${DEVICES[@]}"; do
                echo yes | disk "$disk" gpt
            done

            local MDDEV MDINDEX MDDEVICES MDPARTS MDPARTSIZE
            local PART FREE

            MDINDEX=0
            MDPARTS=()
            for MDDEV in $(volume "$HDEV" devices); do

                MDPARTSIZE="$(raid "$MDDEV" size part)"

                for disk in "${DEVICES[@]}"; do
                    FREE="$(disk "$disk" size free)"
                    if [ "$FREE" -lt "$MDPARTSIZE" ]; then
                        info "$disk: no more spaces(expected $MDPARTSIZE, got $FREE)"
                        continue
                    fi

                    PART="$disk$((MDINDEX + 1))"

                    # create new partition
                    info "$HDEV: create $PART for $MDDEV"
                    disk "$disk" part "$MDPARTSIZE"
                    MDPARTS+=("$PART")
                done

                # add the partition to raid
                info "$HDEV: add ${MDPARTS[*]} to $MDDEV"
                raid "$MDDEV" add "${MDPARTS[*]}"

                MDINDEX=$((MDINDEX + 1))
            done

            info "$HDEV: enough spaces to create new raid?"

            MDPARTSIZE=
            for disk in $(hybrid "$HDEV" devices); do
                FREE="$(disk "$disk" size free)"
                FREE="${FREE%[KMGTP]B}"
                if [ "$FREE" -lt 128 ]; then
                    continue
                fi
                if [ -z "$MDPARTSIZE" ] || [ "$FREE" -lt "$MDPARTSIZE" ]; then
                    MDPARTSIZE="$FREE"
                fi

                MDDEVICES+=("$disk")
            done

            if [ "${#MDDEVICES[@]}" -lt 2 ]; then
                info "$HDEV: no more device spaces"
                return 0
            fi

            # create partitions
            MDPARTS=()
            for disk in "${MDDEVICES[@]}"; do
                disk "$disk" part "$MDPARTSIZE"MB
                MDPARTS+=($(disk "$disk" devices | awk '{print $NF}'))
            done

            sleep 3

            # create raid pv
            MDDEV="$(block_device_next /dev/md)"
            raid "$MDDEV" create auto "${MDPARTS[@]}"

            # add pv to lv
            volume "$HDEV" add "$MDDEV"
            ;;
        *)
            hybrid_help
            ;;
    esac
}

examples() {
    local name="$(basename "$0")"
    cat << EOF
# disk examples
$name disk info                         # show all disks informations
$name disk /dev/sda status              # show /dev/sda status
$name disk /dev/sda init                # init disk with a gpt partition table
$name disk /dev/sda part 10G            # create a new 10G partition

# raid examples

# volume examples
EOF
}

case "$1" in
    hybrid|volume|raid|disk)
        "$@"
        ;;
    *)
        hybrid "$@"
        ;;
esac

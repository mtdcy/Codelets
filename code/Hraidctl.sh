#!/bin/bash

set -eo pipefail

error() { echo -e "== \\033[31m$*\\033[39m =="; }
info()  { echo -e "== \\033[32m$*\\033[39m =="; }
warn()  { echo -e "== \\033[33m$*\\033[39m =="; }

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
    local disk="$1"; shift
    local command="$1"; shift
    if [ ! -b "$disk" ]; then
        error "$disk: no such block device"
        return 1
    fi
    case "$command" in
        status)
            info "status of $disk ($(cat "/sys/block/$(basename "$disk")/device/state"))"

            if which smartctl &> /dev/null; then
                echocmd smartctl -i -H -n standby "$disk" # don't wakeup disk
            else
                echocmd hdparm -C "$disk"
            fi

            # show partitions
            echocmd parted "$disk" print free
            ;;
        size) # size [total|free] in {K,M,G,T,P}, default: total
            #!! 'size free' on disk partition is undefined  !!#
            local total end
            IFS=' :' read -r _ _ total <<< "$( \
                parted "$disk" unit 'MB' print 2>/dev/null | grep "^Disk $disk:" | sed 's/MB//g' \
            )"
            case "$1" in
                free)
                    # find out the last partition:
                    # Number  Start   End        Size       File system  Name     Flags
                    #  1      1.05MB  1000205MB  1000204MB               primary
                    IFS=' ' read -r _ _ end _ <<< "$( \
                        parted "$disk" unit MB print 2>/dev/null | grep "^ [0-9]\+ " | tail -1 | sed 's/MB//g' \
                    )"
                    end="${end:-0}"
                    echo "$((total - end - 1))MB"
                    #!! '-1' : gap between partitions !!#
                    ;;
                total|*)
                    echo "$total"MB
                    ;;
            esac
            ;;
        gpt)
            info "$disk: new GPT partition table"
            read -r -p "It will erase all data from $disk, continue? [y/N]" ans
            ans=${ans:-N}
            ans_is_true "$ans" || return 1

            echocmd wipefs --all --force "$disk"
            echocmd parted -s "$disk" mklabel gpt
            echocmd partprobe "$disk" || true
            # => 'You should reboot now before making further changes.'
            ;;
        part) # part [fs] [size] in {K,M,G,T,P} or sectors
            # !!! everyone use base 1024, but parted use 1000 !!!
            local sz fs
            while test -n "$1"; do
                if par_is_size "$1"; then
                    # KB - 1000, KiB - 1024
                    sz="$(("$(numfmt --from auto "${1%B}")" / 1000000))" # in MB
                elif [ -n "$1" ]; then
                    fs="$1"
                fi
                shift
            done

            local pno
            pno="$(parted "$disk" print | grep -c "^ [0-9]\+ ")" || true
            pno=$((pno + 1))

            if test -z "$sz"; then
                info "$disk: create single partition"
                # erase all partition(s) and create a new one
                echo yes | disk "$disk" gpt > /dev/null
                echocmd parted -s --fix "$disk" mkpart "part$pno" "$fs" "2048s" 100%
            else
                local nsz total start end
                # Disk /dev/sdd: 1000205MB
                IFS=' :' read -r _ _ total <<< "$( \
                    parted "$disk" unit 'MB' print | grep "^Disk $disk:" | sed 's/MB//g' \
                )"
                # Number  Start   End        Size       File system  Name   Flags
                #  1      1.05MB  1000205MB  1000204MB               part1
                IFS=' ' read -r _ _ start _ <<< "$( \
                    parted "$disk" unit MB print | grep "^ [0-9]\+ " | tail -1 | sed 's/MB//g' \
                )"

                nsz="$(numfmt --from si --to si --format "%.2f" "$sz"M)B" || true
                info "$disk: append a $nsz partition"
                if [ "$((start + sz))" -gt "$total" ]; then
                    error "$disk: request size($nsz) exceed limit($free)"
                    return 1
                fi

                # put ~1M free space between partitions
                if [ -n "$start" ]; then
                    start=$((start + 1))
                    end=$((start + 1 + sz))
                else
                    # parted has trouble to align the first partition
                    start="2048s" # ~1M
                    end=$((1 + sz))
                fi
                # double check
                if [ "$end" -gt "$total" ]; then
                    end="$total"
                fi
                echocmd parted -s --fix "$disk" unit MB mkpart "part$pno" "$fs" "$start" "$end"
            fi

            echocmd partprobe "$disk" || true

            if [ -n "$fs" ]; then
                if ! which "mkfs.$fs" &> /dev/null; then
                    error "$disk: bad fs $fs or missing mkfs.$fs"
                    return 1
                fi

                # ugly code to get partition devfs path
                local devfs="$disk$pno"

                info "$disk: mkfs.$fs @ $devfs"
                echocmd wipefs --force "$devfs"
                echocmd mkfs -t "$fs" "$devfs"
            fi
            ;;
        delete)
            info "delete $disk from kernel"
            read -r -p "** Dangerous, are you sure to delete $disk? [y/N]" ans
            ans_is_true ans || return 1

            echo 1 > "/sys/block/$(basename "$disk")/device/delete"
            ;;
        mkfs) # mkfs <type>
            IFS=' ' read -r _ _ _ _ _ type _ <<< "$(lsblk "$disk" | sed -n '2p')"
            case "$type" in
                part|lvm)
                    mkfs -t "$1" "$disk"
                    ;;
                *)
                    error "$disk: mkfs on unsupported device type($type)"
                    return 1
                    ;;
            esac
            ;;
        add)
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
        config)
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
    local mddev="$1"; shift
    local command="$1"; shift
    case "$command" in
        status) # status
            echocmd mdadm --query --detail "$mddev"
            ;;
        test)
            echocmd mdadm --detail --test "$mddev"
            ;;
        devices)
            local mdpartcnt
            mdpartcnt="$(mdadm --detail "$mddev" | grep 'Raid Devices : ' | awk -F':' '{print $2}')"
            mdadm --detail "$mddev" | tail -n"$mdpartcnt" | awk '{print $7}'
            ;;
        size) # <total|parts>, default: total
            local mdsz mdpart
            case "$1" in
                part*)
                    #!! mdadm report part size != real disk part size !!#
                    IFS=' ' read -r _ _ _ _ _ _ mdpart <<< "$( \
                        mdadm --detail "$mddev" | grep 'active sync' | tail -1 \
                    )"
                    disk "$mdpart" size
                    ;;
                total|*)
                    # Array Size : 2929887744 (2.73 TiB 3.00 TB)
                    IFS='()' read -r _ mdsz _ <<< "$(mdadm --detail "$mddev" | grep 'Array Size :')"
                    echo "$mdsz" | awk '{print $3$4}' # takes 1000 base
                    ;;
            esac
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

            info "create raid $mddev($level) with $*"
            if [ $# -lt "$mindev" ]; then
                error "raid($level) requires at least $mindev devices"
                return 1
            fi

            #echo yes | echocmd mdadm --verbose --create "$mddev" --force --level="$level" --raid-devices="$#" "$@"
            echo yes | echocmd mdadm \
                --verbose            \
                --create "$mddev"    \
                --force              \
                --assume-clean       \
                --level="$level"     \
                --raid-devices="$#"  \
                "$@"
            ;;
        stop)
            info "stopping $mddev, it can be assembled again"
            echocmd mdadm --action "idle" "$mddev" || true
            umount "$mddev" || true
            echocmd mdadm --verbose --stop "$mddev"
            echocmd mdadm --verbose --remove "$mddev" 2> /dev/null || true
            ;;
        destroy) # !!! Dangerous !!!
            warn "destroying $mddev, it cann't be assembled again"
            read -r -p "** Dangerous, are you sure to continue? [y/N]" ans
            ans="${ans:-N}"
            ans_is_true "$ans" || return 1

            # stop check/sync
            echocmd mdadm --action "idle" "$mddev" || true
            umount "$mddev" || true

            IFS=' ' read -r -a parts <<< "$(mdadm --detail "$mddev" | sed -n 's@^ .*\(/dev/.*\)$@\1@p' | xargs)"

            echocmd mdadm --verbose --stop "$mddev"
            echocmd mdadm --verbose --remove "$mddev" 2> /dev/null || true

            # leave the devices as is
            for x in "${parts[@]}"; do
                echocmd mdadm --zero-superblock "$x"
            done
            ;;
        add) # add [grow] <partitions ...>
            echocmd mdadm --action "idle" "$mddev"

            # remove failed parts
            if ! mdadm --detail --test "$mddev" >/dev/null; then
                warn "$mddev: degraded, remove failed device(s)"

                # remove failed devices
                while read -r line; do
                    IFS=' ' read -r _ _ _ _ _ b _ <<< "$line"
                    echocmd mdadm --manage "$mddev" --fail "$b" --remove "$b" --force
                done < <(mdadm --detail "$mddev" | grep "faulty")

                # remove detached devices
                echocmd mdadm "$mddev" --fail detached --remove detached
                # add new devices
                echocmd mdadm --manage "$mddev" --add "$@"
            else
                echocmd mdadm --manage "$mddev" --add-spare "$@"
            fi
            # check: 'Device or resource busy'?
            echocmd mdadm --action "check" "$mddev" || true
            ;;
        remove) #
            ;;
        extend)
            ;;
        check) # check <start|stop>, default: start
            case "$1" in
                status)
                    echocmd "cat /sys/block/$(basename "$mddev")/md/mismatch_cnt"
                    ;;
                stop)
                    #echocmd "echo idle > /sys/block/$(basename "$mddev")/md/sync_action"
                    echocmd mdadm --action "idle" "$mddev"
                    ;;
                repair)
                    echocmd mdadm --action "repair" "$mddev"
                    ;;
                start|*)
                    #echocmd "echo check > /sys/block/$(basename "$mddev")/md/sync_action"
                    echocmd mdadm --action "check" "$mddev"
                    ;;
            esac
            ;;
        set) #
            case "$1" in
                faulty)
                    warn "$mddev: simulate a drive failure"
                    echocmd mdadm --manage --set-faulty "$mddev" "$@"
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
    local lvname="$1"; shift
    local command="$1"; shift

    local vgname lvtype lvsize

    # get lvname,vgname
    lvname="$(basename "$lvname")"
    IFS=' ' read -r vgname <<< "$( \
        lvs --noheadings -S lvname="$lvname" -o vg_name \
        )"
    case "$command" in
        status)
            echocmd vgdisplay --verbose "$vgname" -S lvname="$lvname"
            ;;
        devfs)
            echo "/dev/$vgname/$lvname"
            ;;
        size)
            IFS=' <' read -r _ _ _ lvsize <<< "$(lvs --noheadings -S lvname="$lvname")"
            numfmt --from auto --to si --format="%.2f" "${lvsize^^}i"
            ;;
        devices)
            pvs --noheadings -S vgname="$vgname" -o pv_name | xargs
            ;;
        create) # create [linear|stripe|thin] [size] <pv devices ...>
            if [ "$(lvs --noheadings -S lvname="$lvname" | wc -l)" -ne 0 ]; then
                error "volume $lvname already exists"
                return 1
            fi

            lvtype="linear"
            case "$1" in
                linear|striped)
                    lvtype="$1"; shift
                    ;;
                thin)
                    lvtype="thin-pool"; shift
                    ;;
            esac

            if par_is_size "$1"; then
                lvsize="$1"; shift
            fi

            # pv check: all devices must belong to the same group
            vgname=""
            for _pv in "$@"; do
                local _vg
                _vg="$(pvs --noheadings -o vg_name "$_pv")" || true
                if [ -z "$vganme" ]; then
                    vgname="$_vg"
                fi
                if [ "$_vg" != "$vgname" ]; then
                    error "$_pv belongs to group $_vg, expected $vgname"
                    return 1
                fi
            done

            if [ -z "$vgname" ]; then
                vgname="$(block_device_next /dev/vg)"
                echocmd pvcreate --verbose "$@" || true
                echocmd vgcreate --verbose "$vgname" "$@"
            fi

            # create logical volume, default: take 100% free space
            if [ -n "$lvsize" ]; then
                echo y | echocmd lvcreate   \
                    --verbose               \
                    --type "$lvtype"        \
                    --size "$lvsize"        \
                    --name "$lvname"        \
                    "$vgname"
            else
                echo y | echocmd lvcreate   \
                    --verbose               \
                    --type "$lvtype"        \
                    --extents '100%FREE'    \
                    --name "$lvname"        \
                    "$vgname"
            fi
            ;;
        destroy) # !! Dangerous !!
            if [ "$(lvs --noheadings -S lvname="$lvname" | wc -l)" -eq 0 ]; then
                error "volume $lvname not exists"
                return 1
            fi

            local devfs="/dev/$vgname/$lvname"

            # umount volume
            echocmd umount "$devfs" || true

            # remove lv0
            echocmd lvremove --verbose --yes "$devfs"

            # remove vg if no more volume on it
            if [ "$(lvs --noheadings "$vgname" | wc -l)" -eq 0 ]; then
                IFS=' ' read -r -a devices <<< "$(pvs --noheadings -S vgname="$vgname" -o pv_name | xargs)"
                echocmd vgremove --verbose "$vgname" # no '--yes' here
                for dev in "${devices[@]}"; do
                    echocmd pvremove --verbose "$dev"
                done
            fi
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

# hybrid <name> create /dev/sda /dev/sdb ...
hybrid() {
    # top level:
    case "$1" in
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

    local LVNAME="$1"; shift
    local command="$1"; shift

    case "$command" in
        devices)
            local name size type misc
            local OPTS="NAME,SIZE,TYPE,FSTYPE"
            IFS=' ' read -r name size type misc <<< "$(                    \
                lsblk -o "$OPTS" "$(volume "$LVNAME" devfs)" | sed -n '2p' \
            )"
            printf "%-14s %7s %7s %s\n" "NAME" "SIZE" "TYPE" "MISC"
            printf "%-14s %7s %7s %s\n" "$name" "$size" "$type" "$misc"
            for pv in $(volume "$LVNAME" devices); do
                IFS=' ' read -r name size type misc <<< "$( \
                    lsblk -o "$OPTS" "$pv" | sed -n '2p'    \
                )"
                printf "├─%-12s %7s %7s %s\n" "$name" "$size" "$type" "$misc"
                for part in $(raid "$pv" devices); do
                    IFS=' ' read -r name size type misc <<< "$( \
                        lsblk -o "$OPTS" "$part" | sed -n '2p'  \
                    )"
                    printf "│ ├─%-10s %7s %7s %s\n" "$name" "$size" "$type" "$misc"
                done
            done
            ;;
        destroy)
            info "destroy $LVNAME"
            IFS=' ' read -r -a mddevs <<< "$(volume "$LVNAME" devices)"
            volume "$LVNAME" destroy
            for mddev in "${mddevs[@]}"; do
                info "destroy $mddev"
                echo yes | raid "$mddev" destroy
            done
            ;;
        create)
            IFS=' ' read -r -a DEVICES <<< "$@"

            info "create hybrid volume @ ${DEVICES[*]}"
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
                local MDDEVSIZE=$((2 ** 63 - 1)) # max sint

                # get minimal device size
                #  => no sectors here, as disks may has different sector size
                for disk in "${DEVICES[@]}"; do
                    local sizefree=$(disk "$disk" size free)
                    sizefree="${sizefree%%.*}"

                    # if free size < 128M
                    if [ "${sizefree%MB}" -lt 128 ]; then
                        continue
                    fi

                    if [ "${sizefree%MB}" -lt "${MDDEVSIZE%MB}" ]; then
                        MDDEVSIZE="$sizefree"
                    fi
                    MDDEVICES+=("$disk")
                done

                # Done? OR, short of devices
                if [ "${#MDDEVICES[@]}" -lt 2 ]; then
                    break;
                fi

                # create parts
                local MDPARTS=()
                for disk in "${MDDEVICES[@]}"; do
                    local part="$disk$((${#PVDEVICES[@]} + 1))"
                    info "create $part $MDDEVSIZE"
                    disk "$disk" part "$MDDEVSIZE"
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
                fi

                PVDEVICES+=("$MDDEV")
                DEVICES=("${MDDEVICES[@]}")
            done

            sleep 3

            # create volume
            volume "$LVNAME" create "${PVDEVICES[@]}"

            # create device mapper (DM) and cachedev

            #local devfs="$(volume "$LVNAME" devfs)"
            #disk "$devfs" init
            #disk "$devfs" part ext4
            ;;
        mkfs) # mkfs [btrfs]
            local fs="$1"
            fs="${fs:-btrfs}"
            disk "$(volume "$LVNAME" devfs)" mkfs "$fs"
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

"$@"

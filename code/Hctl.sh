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

headings() {
    cat << EOF
$NAME $VERSION (c) Chen Fang 2024, mtdcy.chen@gmail.com
EOF
}

RED="\\033[31m"
GREEN="\\033[32m"
YELLOW="\\033[33m"
BLUE="\\033[34m"
PURPLE="\\033[35m"
CYAN="\\033[36m"
NC="\\033[0m"

error() { echo -e "!!$RED $* $NC"; }
info()  { echo -e "!!$GREEN $* $NC"; }
warn()  { echo -e "!!$YELLOW $* $NC"; }

echofunc() {
    local cmd="${*//[[:space:]]+/ }"
    echo -e "\n==$BLUE $cmd $NC"
    eval -- "$cmd"
}

echocmd() {
    local cmd="${*//[[:space:]]+/ }"
    echo -e "--$CYAN $cmd $NC"
    eval -- "$cmd"
}

# prompt "text" <true|false> ans
prompt() {
    #!! make sure variable name differ than input par !!#
    local __var=$3
    echo -en "**$YELLOW $1 $NC"
    case "${2,,}" in
        y|yes|true) echo -en " [Y/n]"; eval "$__var"=Y ;;
        *)          echo -en " [y/N]"; eval "$__var"=N ;;
    esac
    eval read -r "$__var"
    echo ""
}

# $0 <value>
ans_is_true() {
    case "${1,,}" in
        1|y|yes) true  ;;
        *)       false ;;
    esac
}

par_is_size() {
    [[ "${1^^}" =~ ^[0-9\.]+[KMGTP]?I?B?$ ]]
}

par_is_fstype() {
    [[ "${1,,}" =~ ^ext[2-4] ]] || [[ "${1,,}" =~ fs$ ]]
}

# for print
to_iec() {
    numfmt --from iec --to iec --format='%.1f' "${1%B}"
}

# mainly for disk size related ops
to_iec_MB() {
    echo "$(($(numfmt --from iec "${1%B}") / 1048576))M"
}

# from iec to Bytes, for size math
from_iec() {
    numfmt --from iec "$1"
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

# raid_size level <part size> <count>
raid_size() {
    local psz="$2"
    psz="${psz%[KMGTP]}"
    case "$1" in
        raid0|0)    psz=$(("$psz" * "$3"))       ;;
        raid1|1)    ;;
        raid5|5)    psz=$(("$psz" * ("$3" - 1))) ;;
        raid6|6)    psz$(("$psz" * ("$3" - 2)))  ;;
    esac
    echo "$psz${2##*[0-9]}"
}

disk() {
    # Top level: disk <command>
    case "$1" in
        info)
            echocmd lsblk -o +MODEL,SERIAL
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
            fi
            echocmd parted "$DISK" print free
            warn "'parted' used 1000-based numbers"
            ;;
        devices) # return partitions
            local parts=()
            while IFS='' read -r line; do
                parts+=("$line")
            done < <(parted "$DISK" print | grep " [0-9]\+ " | awk '{ print  $1}')
            echo "${parts[@]/#/$DISK}"
            ;;
        size) # size [total|free], default: total, return in MB
            #!! 'size free' on partition is undefined       !!#
            local diskinfo total end

            # suppress 'unrecognised disk label' for part
            diskinfo="$(parted "$DISK" unit B print free 2>/dev/null)"

            # readlink: 'parted' shows the real path
            IFS=' :' read -r _ _ total <<< "$( \
                grep "^Disk $(readlink -f "$DISK"): " <<< "$diskinfo" \
            )"
            case "$1" in
                free)
                    # find out the last partition:
                    # Number  Start   End        Size       File system  Name     Flags
                    #  1      1.05MB  1000205MB  1000204MB               primary
                    end="$(grep "^ [0-9]\+ " <<< "$diskinfo" | tail -1 | awk '{print $3}')" || true
                    end=${end:-0}
                    to_iec "$((${total%B} - ${end%B}))"
                    ;;
                total|*)
                    to_iec "${total%B}"
                    ;;
            esac
            ;;
        mount) # mount [mountpoint]
            if [ $# -gt 0 ]; then
                umount "$DISK" 2>/dev/null || true
                sed -i "\|^$DISK|d" /etc/fstab
                echo "$DISK $1 auto defaults,nofail 0 0" >> /etc/fstab
                mkdir -pv "$1"
                which systemctl &>/dev/null && systemctl daemon-reload || true
                mount "$DISK"
            else
                lsblk -o MOUNTPOINT "$DISK" | sed -n '2p'
            fi
            ;;
        gpt)
            prompt "$DISK: new GPT partition table?" false ans
            ans_is_true "$ans" || return 1

            # remove signatures
            wipefs --all --force "$DISK" > /dev/null
            # create new gpt part table
            echocmd parted --script "$DISK" mklabel gpt || {
cat << EOF

    ===
    'parted $DISK mklabel gpt' failed, possible cause:

    1. $DISK may be busy because it is a raid member;

    Please do:

    1. find out which raid holds $DISK with 'raid ls'
    2. destroy the raid with 'raid /dev/mdX destroy'
    ===
EOF
                return 1
            }

            echocmd partprobe "$DISK" || true
            ;;
        create) # create [fstype] [size], size in [KMGTP]
            local size fstype
            while test -n "$1"; do
                if par_is_size "$1"; then
                    size="$1"
                else
                    fstype="$1"
                fi
                shift
            done

            local diskinfo part
            diskinfo="$(parted "$DISK" unit B print free 2>/dev/null)"
            part="$(grep -c "^ [0-9]\+ " <<< "$diskinfo")" || true
            part="$DISK$((part + 1))"

            if test -z "$size"; then
                info "$DISK: create a single partition"
                # erase all partition(s) and create a new one
                echo yes | disk "$DISK" gpt > /dev/null
                echocmd parted --script --fix "$DISK" \
                    mkpart "$(basename "$part")" "$fstype" "2048s" 100%
            else
                local nsz total start end
                # DISK /dev/sdd: 1000205MB
                total=$(grep "^Disk $DISK:" <<< "$diskinfo" | awk -F':' '{print $2}')
                # Number  Start   End        Size       File system  Name   Flags
                #  1      1.05MB  1000205MB  1000204MB               part1
                start=$(grep "^ [0-9]\+ " <<< "$diskinfo" | tail -1 | awk '{print $3}') || true

                # remove suffix MB
                total=${total%B}
                start=${start%B}
                free=$((total - start))

                info "$DISK: append a $(to_iec "$size") partition"

                #!! everyone use 1024-base, but parted is 1000-based !!#
                size=$(from_iec "${size%B}")

                #if [ "$((start + size))" -gt "$total" ]; then
                #    error "$DISK: request size($size) exceed limit($free)"
                #    return 1
                #fi

                # put ~1M free space between partitions
                if [ -n "$start" ]; then
                    start=$((((start + 1048575) / 1048576) * 1048576))
                    end=$((start + size))
                else
                    # parted has trouble to align the first partition
                    start="2048s" # ~1M
                    end=$((1048576 + size))
                fi
                # double check on end
                if [ "$end" -ge "$total" ]; then
                    end="$((total - 1))"
                fi
                # align to 1M ?
                end=$(((end / 1048576) * 1048576))

                echocmd parted --script --fix "$DISK" unit B \
                    mkpart "$(basename "$part")" "$fstype" "$start" "$end"
            fi

            echocmd partprobe "$DISK"

            if [ -n "$fstype" ]; then
                disk "$part" fstype "$fstype"
            fi
            ;;
        delete)
            prompt "$DISK: delete from kernel?" false ans
            ans_is_true "$ans" || return 1

            local scsi
            scsi="$(readlink -f "/sys/block/$DISKNAME")"
            scsi="$(realpath "$scsi/../../../../")"
            echo offline > "/sys/block/$DISKNAME/device/state"
            echo 1 > "/sys/block/$DISKNAME/device/delete"

            info "$DISK: online with \`echo '- - -' > $(find "$scsi" -name scan -type f)'"
            ;;
        fstype) # fstype [ext4|btrfs|...]
            if [ "$DISKTYPE" = "disk" ]; then
                error "$DISK: unsupported device type($DISKTYPE)"
                return 1
            else
                if [ -z "$1" ]; then
                    # suppress error 'unrecognised disk label'
                    parted "$DISK" print 2>/dev/null | grep ' [0-9]\+ ' | awk '{print $5}'
                else
                    echocmd mkfs -t "$1" -q "$DISK" -f
                fi
            fi
            ;;
        resizefs) # resizefs <min|max|[+/-]size>
            case "$(disk "$DISK" fstype)" in
                ext*)
                    # TODO
                    return 1
                    ;;
                btrfs)
                    # BTRFS needs to be mounted to be able to resize the partition.
                    local mounted size
                    mounted="$(lsblk -o MOUNTPOINT "$DISK" | sed -n '2p')"
                    if test -z "$mounted"; then
                        mounted="/tmp/btrfs-$$"
                        mkdir -pv "$mounted"
                        echocmd mount -t btrfs "$DISK" "$mounted"
                    fi

                    size="$1"
                    if [ "${size,,}" = "min" ]; then
                        # Free (estimated):             47.45GiB      (min: 23.73GiB)
                        size="$(btrfs filesystem usage -b "$mounted" | grep -F '(estimated)' | awk '{print $NF}')"
                        size="${size%)}"
                    fi

                    # resize btrfs
                    echocmd btrfs filesystem resize "$size" "$mounted"

                    if [[ "$mounted" =~ /tmp/btrfs- ]]; then
                        umount "$mounted"
                        rm -rf "$mounted"
                    fi

                    # fsck
                    echocmd btrfs check --force "$DISK"
                    ;;
                *)
                    error "$DISK: unsupported fstype $(disk "$DISK" fstype)"
                    return 1
                    ;;
            esac
            ;;
        *)
            error "unknown command $command"
            return 1
            ;;
    esac
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
            return
            ;;
        ls)
            while read -r mddev; do
                echo "/dev/$mddev: $(raid "/dev/$mddev" devices)"
            done < <(grep "^md[0-9]\+ :" /proc/mdstat | awk -F':' '{print $1}')
            return
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
$(mdadm --detail --scan)
EOF
            # fix md0 been reanemd to md127 after reboot
            update-initramfs -u
            return
            ;;
    esac

    # raid <mddev> <command> [parameters]
    local MDDEV="$1"; shift
    local command="$1"; shift

    if [ "$command" != "create" ] && [ ! -b "$MDDEV" ]; then
        error "$MDDEV: no such block device"
        return 1
    fi

    case "$command" in
        status) # status
            echocmd mdadm --query --detail "$MDDEV"
            ;;
        test)
            echocmd mdadm --detail --test "$MDDEV"
            ;;
        mount) # mount [mountpint]
            disk "$MDDEV" mount "$@"
            ;;
        devices) # devices [active|spare], default: active
            [ -b "$MDDEV" ] || return 1
            case "$1" in
                spare)
                    mdadm --detail "$MDDEV" | grep -Fw "spare" | awk '{print $6}' | xargs
                    ;;
                active|*)
                    mdadm --detail "$MDDEV" | grep -Fw "active sync" | awk '{print $7}' | xargs
                    ;;
            esac
            ;;
        level)
            grep "^$(basename "$MDDEV") : " /proc/mdstat | awk '{print $4}'
            ;;
        size) # <total|parts>, default: total
            [ -b "$MDDEV" ] || return 1
            local size
            case "$1" in
                part*)
                    # Used Dev Size : 976630464 (931.39 GiB 1000.07 GB)
                    # size=$(mdadm --detail "$MDDEV" | grep 'Used Dev Size :' | awk -F':' '{print $2}' | awk '{print $1}')
                    #!! 'Used Dev Size' < real partition size !!#
                    disk "$(raid "$MDDEV" devices | awk '{print $1}')" size
                    ;;
                total|*)
                    # Array Size : 976630464 (931.39 GiB 1000.07 GB)
                    size=$(mdadm --detail "$MDDEV" | grep 'Array Size :' | awk -F':' '{print $2}' | awk '{print $1}')
                    to_iec "$size"K
                    ;;
            esac
            ;;
        create) # create [level] [fstype] partitions ...
            local level mindev fstype
            while [ -n "$1" ]; do
                if par_is_fstype "$1"; then
                    fstype="$1"
                elif [[ "$1" =~ ^raid[01456] ]] || [[ "$1" =~ ^[01456]\+$ ]]; then
                    level="$1"
                else
                    break
                fi
                shift
            done

            # space efficient raid type with data parity
            if [ -z "$level" ]; then
                case "$#" in
                    2)  level=raid1 ;;
                    *)  level=raid5 ;;
                esac
            fi

            # mini devices requirements
            case "$level" in
                raid0|0)    mindev=2 ;;
                raid1|1)    mindev=2 ;;
                raid5|5)    mindev=3 ;;
                raid6|6)    mindev=4 ;;
                raid10|10)  mindev=4 ;;
            esac

            if [ $# -lt "$mindev" ]; then
                error "raid($level) requires at least $mindev devices"
                return 1
            fi

            echo yes | echocmd mdadm    \
                --verbose               \
                --create "$MDDEV"       \
                --force                 \
                --assume-clean          \
                --level="$level"        \
                --raid-devices="$#"     \
                "$@"

            if test -n "$fstype"; then
                disk "$MDDEV" fstype "$fstype"
            fi
            ;;
        stop)
            info "$MDDEV: stop, which can be assembled again"
            echocmd mdadm --action "idle" "$MDDEV" || true
            echocmd umount "$MDDEV" || true
            echocmd mdadm --stop "$MDDEV"
            echocmd mdadm --remove "$MDDEV" 2> /dev/null || true
            ;;
        destroy) # !!! Dangerous !!!
            prompt "$MDDEV: destroy, which can't be assembled again, continue?" false ans
            ans_is_true "$ans" || return 1

            # stop check/sync
            echocmd mdadm --action "idle" "$MDDEV" || true
            echocmd umount "$MDDEV" || true

            IFS=' ' read -r -a parts <<< "$(mdadm --detail "$MDDEV" | sed -n 's@^ .*\(/dev/.*\)$@\1@p' | xargs)"

            echocmd mdadm --stop "$MDDEV"
            echocmd mdadm --remove "$MDDEV" 2> /dev/null || true

            # leave the devices as is
            for x in "${parts[@]}"; do
                echocmd mdadm --zero-superblock "$x"
            done
            ;;
        add) # add [spare] partitions ...
            #!! replace failed devices or grow the raid !!#
            local spare
            case "$1" in
                spare)  spare=true; shift ;;
            esac

            echocmd mdadm --action "idle" "$MDDEV"

            local mdinfo mdcnt total final
            mdinfo="$(mdadm --detail "$MDDEV")"
            mdcnt="$(grep -F 'Raid Devices :' <<< "$mdinfo" | awk -F':' '{print $NF}')"
            total="$(grep -F 'Total Devices :' <<< "$mdinfo" | awk -F':' '{print $NF}')"

            # remove failed parts
            if ! mdadm --detail --test "$MDDEV" &>/dev/null; then
                warn "$MDDEV: degraded, remove failed device(s)"

                # remove failed devices
                while read -r part; do
                    info "$MDDEV: remove faulty $part"
                    echocmd mdadm --manage "$MDDEV" --fail "$part" --remove "$part" --force
                done < <(grep "faulty" <<< "$mdinfo" | awk '{print $NF}')

                # remove detached devices
                echocmd mdadm "$MDDEV" --fail detached --remove detached
            fi

            # add devices as hot spare
            echocmd mdadm --manage "$MDDEV" --add "$@"

            # grow if not add as spare
            if ! [ "$spare" = "true" ]; then
                mdinfo="$(mdadm --detail "$MDDEV")"
                final="$(grep -F 'Total Devices :' <<< "$mdinfo" | awk -F':' '{print $NF}')"
                #!! grow with new added devices only !!#
                if [ "$final" -gt "$mdcnt" ]; then
                    info "$MDDEV: extend raid $mdcnt -> $final"
                    echocmd mdadm --grow "$MDDEV" --raid-devices="$((mdcnt + final - total))"

cat << EOF
$(echo -e "$RED
    ---
    The mdadm raid device is growing, but its status may no be updated.
    The following code may not work as expect, so something needs to be
    updated again after the raid device resync is complete.
    ---
$NC")
EOF
                    echocmd partprobe "$MDDEV"
                    # TODO: raid1 -> raid5
                fi
            fi

            #!! no force resync here !!#
            # check: 'Device or resource busy'?
            #echocmd mdadm --action "check" "$MDDEV" || true
            ;;
        delete|shrink) # delete partition
            #!! shrink only support on simple raid device(not logical volume !!#
            #echocmd mdadm --action "idle" "$MDDEV"
            raid "$MDDEV" check stop

            local shrink=false
            local part="$1" # only allow delete one device each time
            if test -n "$part"; then
                local line
                line="$(mdadm --detail /dev/md0 | grep "[0-9]\+.*$part")"
                part="$(awk '{print $NF}' <<< "$line")"

                echocmd mdadm --manage "$MDDEV" --fail "$part" --remove "$part"
                if ! [[ "$line" =~ spare ]]; then
                    shrink=true
                fi
            fi

            # deleted device(s) except spare?
            if [ "$shrink" = "false" ]; then
                return
            fi

            # remove detached devices
            echocmd mdadm "$MDDEV" --fail detached --remove detached

            # resize to min if supported
            echofunc disk "$MDDEV" resizefs min || true

            local mdinfo mdcnt total
            mdinfo="$(mdadm --detail "$MDDEV")"
            IFS=' :' read -r _ _ mdcnt <<< "$(grep -F 'Raid Devices :' <<< "$mdinfo")"
            IFS=' :' read -r _ _ total <<< "$(grep -F 'Working Devices :' <<< "$mdinfo")"

            if [ "$total" -lt "$mdcnt" ]; then
                local level partsize raidsize
                IFS=' :' read -r _ _ level <<< "$(grep -F 'Raid Level :' <<< "$mdinfo")"
                partsize="$(raid "$MDDEV" size part)"
                raidsize="$(raid_size "$level" "$partsize" "$total")"

                # 90% ???
                #  => array-size report by error message < partsize * N, WHY???
                raidsize="$((${raidsize%[KMGTP]} * 9 / 10))${raidsize##*[0-9]}"

                # pre shrink
                echocmd umount "$MDDEV" || true
                echocmd mdadm --grow "$MDDEV" --array-size="$raidsize"

                # do shrink
                echocmd mdadm --grow "$MDDEV" \
                    --raid-devices="$total" \
                    --backup-file="/var/tmp/$(basename "$MDDEV").backup"

                # post shrink
                echocmd mdadm --grow "$MDDEV" --array-size="max"
            fi

            # resize to max
            disk "$MDDEV" resizefs max || true

            # check
            #echocmd mdadm --action "check" "$MDDEV" || true
            raid "$MDDEV" check || true
            ;;
        check) # check <start|stop>, default: start
            case "$1" in
                status)
                    echocmd "cat /sys/block/$(basename "$MDDEV")/md/mismatch_cnt"
                    ;;
                stop)
                    echocmd "echo idle > /sys/block/$(basename "$MDDEV")/md/sync_action"
                    #echocmd mdadm --action "idle" "$MDDEV"
                    ;;
                repair)
                    echocmd mdadm --action "repair" "$MDDEV"
                    ;;
                start|*)
                    echocmd "echo check > /sys/block/$(basename "$MDDEV")/md/sync_action"
                    #echocmd mdadm --action "check" "$MDDEV"
                    ;;
            esac
            ;;
        *)
            error "unknown command $command"
            return 1
            ;;
    esac
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
            echocmd vgdisplay "$VGNAME" -S lvname="$LVNAME"
            ;;
        size) # size
            #[ -b "$LVDEV" ] || return 0 #
            #LVSIZE="$(lvs --noheadings -S lvname="$LVNAME" -o lv_size | awk '{print $NF}')"
            #LVSIZE="${LVSIZE#<}" # remove leading '<'
            ##!! lvm use [kmgtp] with 1024 base !!#
            #to_iec "${LVSIZE^^}"
            disk "$LVDEV" size "$@"
            ;;
        mount) # mount [mountpint]
            disk "$LVDEV" mount "$@"
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
            #info "$LVDEV: create $LVTYPE volume with $*"

            if par_is_size "$1"; then
                LVSIZE="$1"; shift
            fi

            # pv check: all devices must belong to the same group
            for _pv in "$@"; do
                local _vg
                IFS=' ' read -r _vg <<< "$(pvs --noheadings -o vg_name "$_pv" 2>/dev/null)" || true
                if [ -n "$_vg" ] && [ "$_vg" != "$VGNAME" ]; then
                    error "$_pv belongs to group $_vg, expected $VGNAME"
                    return 1
                fi
            done

            if ! lvs "$VGNAME" 2> /dev/null; then
                echocmd pvcreate --quiet "$@" || true
                echocmd vgcreate --quiet "$VGNAME" "$@"
            fi

            # create logical volume, default: take 100% free space
            if [ -n "$LVSIZE" ]; then
                echo y | echocmd lvcreate   \
                    --quiet                 \
                    --type "$LVTYPE"        \
                    --size "$LVSIZE"        \
                    --name "$LVNAME"        \
                    "$VGNAME"
            else
                echo y | echocmd lvcreate   \
                    --quiet                 \
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
            echocmd lvremove --yes "$VGNAME" -S lvname="$LVNAME"

            # remove vg if no more volume on it
            if [ "$(lvs --noheadings "$VGNAME" | wc -l)" -eq 0 ]; then
                IFS=' ' read -r -a devices <<< "$(pvs --noheadings -S vgname="$VGNAME" -o pv_name | xargs)"
                echocmd vgremove "$VGNAME" # no '--yes' here
                for dev in "${devices[@]}"; do
                    echocmd pvremove "$dev"
                done
            fi
            ;;
        add) # add devices ...
            echocmd pvcreate "$@"
            echocmd vgextend "$VGNAME" "$@"

            # not all filesystem support resizefs with lvextend
            echocmd lvextend            \
                --extents '+100%FREE'   \
                "$LVDEV" "$@"

            echofunc disk "$LVDEV" resizefs max
            ;;
        delete)
            error "$LVDEV: delete device from volume is not supported"
            return 1
            ;;
        *)
            error "$LVDEV: unknown command $command"
            return 1
            ;;
    esac
}

# hybrid /dev/Hg0/H0 create /dev/sda /dev/sdb ...
hybrid() {
    # top level:
    case "$1" in
        ls)
            local name size type misc
            local OPTS="NAME,SIZE,TYPE,MOUNTPOINTS,FSTYPE,UUID"
            printf "%-14s %7s %7s %s\n" "NAME" "SIZE" "TYPE" "MISC"

            for lv in $(lvs --noheadings -o lv_path | xargs); do
                IFS=' ' read -r name size type misc <<< "$( \
                    lsblk -o "$OPTS" "$lv" | sed -n '2p'    \
                )"
                printf "%-14s %7s %7s %s\n" "$name" "$size" "$type" "$misc"
                for pv in $(volume "$lv" devices); do
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
                printf "%14s : %s" "$dev" "$(to_iec "${size%B}")"
                if [ "$free" != "0M" ]; then
                    printf " (%s free)" "$(to_iec "${free%B}")"
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
            disk "$HDEV" mount "$@"
            ;;
        destroy)
            info "destroy $HDEV"
            IFS=' ' read -r -a mddevs <<< "$(volume "$HDEV" devices)"
            echofunc volume "$HDEV" destroy
            for mddev in "${mddevs[@]}"; do
                echo yes | echofunc raid "$mddev" destroy
            done
            ;;
        create) # [fs] devices ...
            local FSTYPE="btrfs"
            local DEVICES=()
            while test -n "$1"; do
                if par_is_fstype "$1"; then
                    FSTYPE="$1"
                else
                    DEVICES+=("$1")
                fi
                shift
            done

            prompt "$HDEV: devices ${DEVICES[*]} will be formated, continue?" false ans
            ans_is_true "$ans" || return 1

            # wipe disks
            for disk in "${DEVICES[@]}"; do
                echo yes | echofunc disk "$disk" gpt
            done

            local PVDEVICES=()
            while [ "${#DEVICES[@]}" -ge 2 ]; do
                local MDDEVICES=()
                local MDPARTS=()
                local MDPARTSIZE=$((2 ** 63 - 1)) # max sint

                local free
                for disk in "${DEVICES[@]}"; do
                    free="$(disk "$disk" size free)"
                    free="$(from_iec "$free")"

                    # if free size < 128M
                    if [ "$free" -lt $((128 * 1048576)) ]; then
                        continue
                    fi

                    if [ "$free" -lt "$MDPARTSIZE" ]; then
                        MDPARTSIZE="$free"
                    fi
                    MDDEVICES+=("$disk")
                done
                # to iec, also truncate the size
                MDPARTSIZE="$(to_iec "$MDPARTSIZE")"

                # Done? OR, short of devices
                if [ "${#MDDEVICES[@]}" -lt 2 ]; then
                    break;
                fi

                # create parts
                for disk in "${MDDEVICES[@]}"; do
                    echofunc disk "$disk" create "$MDPARTSIZE"
                    MDPARTS+=("$(disk "$disk" devices | awk '{print $NF}')")
                done

                # create raid
                local MDDEV
                MDDEV="$(block_device_next /dev/md)"
                echofunc raid "$MDDEV" create "${MDPARTS[@]}" || true

                # !! recreate raid may end with unexpected devfs !!
                if ! test -b "$MDDEV"; then
                    error "create $MDDEV failed"
cat << EOF
    ===
    Create mdadm raid failed, possible cause:

    1. The raid has been assembled by system, which make devices busy;
    2. The raid was stopped and re-created with different devfs/name;
    3. The $MDDEV is 'Not POSIX compatible.'
    ===
EOF
                    return 1
                fi

                PVDEVICES+=("$MDDEV")
                DEVICES=("${MDDEVICES[@]}")
            done

            # wait until raids are ready
            sleep 3

            # create volume: force linear
            echofunc volume "$HDEV" create linear "${PVDEVICES[@]}" || true

            if ! test -b "$HDEV"; then
cat << EOF
    ===
    Create lvm volume failed, possible cause:

    1. The raid devices are not ready, wait for more seconds;
    ===
EOF
                return 1
            fi

            # prepare filesystem
            echofunc disk "$HDEV" fstype "$FSTYPE"
            ;;
        add) # add devices ...
            local DEVICES
            IFS=' ' read -r -a DEVICES <<< "$@"

            prompt "$HDEV: devices ${DEVICES[*]} will be formated, continue?" false ans
            ans_is_true "$ans" || return 1

            # wipe disks
            for disk in "${DEVICES[@]}"; do
                echo yes | echofunc disk "$disk" gpt
            done

            local MDDEVICES MDPARTS MDPARTSIZE

            local MDINDEX=0
            for pv in $(volume "$HDEV" devices); do
                MDPARTS=()

                MDPARTSIZE="$(raid "$pv" size part)"
                MDPARTSIZE="$(from_iec "$MDPARTSIZE")"

                info "$HDEV: prepare parts for pv/raid device $pv"
                for disk in "${DEVICES[@]}"; do
                    local free
                    free="$(disk "$disk" size free)"
                    free="$(from_iec "$free")"
                    if [ "$free" -lt "$MDPARTSIZE" ]; then
                        info "$disk: no more space left"
                        continue
                    fi

                    local part
                    part="$disk$((MDINDEX + 1))"

                    # create new partition
                    info "$HDEV: create $part for $pv"
                    echofunc disk "$disk" create "$MDPARTSIZE"
                    MDPARTS+=("$part")
                done

                info "$HDEV: resize raid device $pv"
                echofunc raid "$pv" add "${MDPARTS[@]}"

                sleep 3

                info "$HDEV: resize pv device $pv"
                echofunc pvresize --verbose "$pv"

                MDINDEX=$((MDINDEX + 1))
            done

            # enough space for new pv devce?
            MDPARTSIZE=$((2 ** 63 - 1)) # max sint
            for disk in $(hybrid "$HDEV" devices); do
                local free
                free="$(disk "$disk" size free)"
                free="$(from_iec "$free")"

                if [ "$free" -lt $((128 * 1048576)) ]; then
                    continue
                fi
                if [ "$free" -lt "$MDPARTSIZE" ]; then
                    MDPARTSIZE="$free"
                fi

                MDDEVICES+=("$disk")
            done
            MDPARTSIZE="$(to_iec "$MDPARTSIZE")"

            if [ "${#MDDEVICES[@]}" -lt 2 ]; then
                info "$HDEV: no more space left"
                return 0
            fi

            info "$HDEV: create new pv/raid device"
            # create partitions
            MDPARTS=()
            for disk in "${MDDEVICES[@]}"; do
                echofunc disk "$disk" create "$MDPARTSIZE"
                MDPARTS+=("$(disk "$disk" devices | awk '{print $NF}')")
            done

            # create raid pv
            local MDDEV
            MDDEV="$(block_device_next /dev/md)"
            echofunc raid "$MDDEV" create "${MDPARTS[@]}"

            # wait until raids are ready
            sleep 3

            # add pv to lv
            echofunc volume "$HDEV" add "$MDDEV"

cat << EOF
$(echo -e "$RED
    ---
    The hybrid volume available size may not update now, run following
    commands after the underlying raid device resync done:

    sudo partprobe $(volume "$HDEV" devices)
    sudo pvresize $(volume "$HDEV" devices)
    sudo lvextend --extents +100%FREE $HDEV

    OR

    sudo $NAME $HDEV resize max
    ---
$NC")
EOF
            ;;
        resize) # resize [max|size]
            local size="max"
            if test -n "$1"; then
                size="$1"
                shift
            fi

            local MDDEVICES=()
            IFS=' ' read -r -a MDDEVICES <<< "$(volume "$HDEV" devices)"
            echocmd partprobe "${MDDEVICES[@]}"
            echocmd pvresize "${MDDEVICES[@]}"

            # suppress 'matches existing size'
            if [ "$size" = "max" ]; then
                echocmd lvextend --extents '+100%FREE' "$HDEV" || true
            else
                echocmd lvextend --extents "$size" "$HDEV" || true
            fi

            echofunc disk "$HDEV" resizefs "$size"
            ;;
        delete)
            error "$HDEV: delete device from hybrid volume is not supported"
            return 1
            ;;
        *)
            error "unknown command $command"
            return 1
            ;;
    esac
}

examples() {
    cat << EOF
-- disk examples --
$NAME disk info                                     # show all disks informations
$NAME disk /dev/sda status                          # show /dev/sda status
$NAME disk /dev/sda gpt                             # create a gpt partition table
$NAME disk /dev/sda create 10G                      # create a new 10G partition
$NAME disk /dev/sda size free                       # get disk free space size

-- raid examples --
$NAME raid ls                                       # list all raid devices
$NAME raid info                                     # show all raid devices info
$NAME raid /dev/md0 create /dev/sd[a-d]1            # create a new raid device
$NAME raid /dev/md0 add /dev/sde1                   # add partition(s) to existing raid device
$NAME raid /dev/md0 destroy                         # destroy an existing raid device
$NAME raid /dev/md0 size part                       # get raid device's partition size

-- volume examples --
$NAME volume info                                   # show all logical volume info
$NAME volume /dev/vg0/volume0 create /dev/md[12]    # create a new logical volume
$NAME volume /dev/vg0/volume0 add /dev/md3          # add new device(s) to existing logical volume
$NAME volume /dev/vg0/volume0 destroy               # destroy an existing logical volume
$NAME volume /dev/vg0/volume0 size free             # get logical volume's free space size

-- hybrid volume examples --
$NAME ls                                            # list all hybrid volumes
$NAME /dev/vg0/volume0 create btrfs /dev/sd[a-z]    # create new hybrid volume on devices
$NAME /dev/vg0/volume0 add /dev/sde                 # add new device(s) to existing hybrid volume
$NAME /dev/vg0/volume0 status                       # check hybrid volume status
$NAME /dev/vg0/volume0 mount /services              # mount a hybrid volume
$NAME /dev/vg0/volume0 destroy                      # destroy a hybrid volume
EOF
}

case "$1" in
    hybrid|volume|raid|disk)
        echofunc "$@"
        ;;
    examples)
        examples
        ;;
    *)
        echofunc hybrid "$@"
        ;;
esac

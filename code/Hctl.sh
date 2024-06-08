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

RAID_PART_LIMIT_MIN=100000000 # ~100M
RAID_PART_LIMIT_MAX=$((2 ** 63 - 1)) # max sint

RED="\\033[31m"
GREEN="\\033[32m"
YELLOW="\\033[33m"
BLUE="\\033[34m"
PURPLE="\\033[35m"
CYAN="\\033[36m"
NC="\\033[0m"

error() { echo -e "!!$RED $* $NC";      }
info()  { echo -e "!!$GREEN $* $NC";    }
warn()  { echo -e "!!$YELLOW $* $NC";   }

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
    local __var=$3 __ans
    echo -en "**$YELLOW $1 $NC"
    case "${2,,}" in
        y|yes|true) echo -en " [Y/n]"; eval "$__var"=Y ;;
        *)          echo -en " [y/N]"; eval "$__var"=N ;;
    esac
    eval read -r __ans
    if test -n "$__ans"; then
        eval "$__var"="$__ans"
    fi
    echo ""
}

# $0 <value>
ans_is_true() {
    case "${1,,}" in
        1|y*)   true  ;;
        *)      false ;;
    esac
}

par_is_size() {
    local sz="${1^^}"
    [[ "$sz" =~ ^[0-9\.]+[KMGTP]?I?B?$ ]]
}

par_is_fstype() {
    # ext2/3/4, xfs, zfs, btrfs, ...
    local fs="${1,,}"
    [[ "$fs" =~ ^ext[2-4]$ ]] || [[ "$fs" =~ fs$ ]]
}

par_is_raidlevel() {
    local lvl="${1,,}"
    case "$lvl" in
        raid*)          return 0 ;;
        0|1|4|5|6|10)   return 0 ;;
        *)              return 1 ;;
    esac
}

# for print
to_iec() {
    local sz="${1^^%B}"
    if [ $# -eq 0 ]; then read -r sz; fi
    numfmt --from iec --to iec --round=down --format='%.2f' "$sz"
}

# mainly for disk size related ops
to_iec_MB() {
    local sz="${1^^%B}"
    if [ $# -eq 0 ]; then read -r sz; fi
    echo "$(($(numfmt --from iec "${1%B}") / 1048576))M"
}

to_iec_100MB() {
    local sz="${1^^%B}"
    if [ $# -eq 0 ]; then read -r sz; fi
    sz="$(numfmt --from iec "$sz")"
    sz="$(((sz / 104857600) * 100))"
    echo "$sz"M
}

# from iec to Bytes, for size math
from_iec() {
    local sz="${1^^%B}"
    if [ $# -eq 0 ]; then read -r sz; fi
    numfmt --from iec "$sz"
}

# $0 <prefix>
devfs_next() {
    for i in {0..255}; do
        if ! [ -b "$1$i" ]; then
            echo "$1$i"
            return 0
        fi
    done
    return 1
}

# raid_size level <part size> <count>
raid_size() {
    local psz="${2^^}"
    psz="${psz%[KMGTP]}"
    case "$1" in
        raid0|0)    psz=$(("$psz" * "$3"))       ;;
        raid1|1)    ;;
        raid5|5)    psz=$(("$psz" * ("$3" - 1))) ;;
        raid6|6)    psz=$(("$psz" * ("$3" - 2))) ;;
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

    local DISKINFO DISKNAME DISKTYPE
    #!! 'unit B': parted use 1000-based size while everyone use 1024-based !!#
    #!! '2>...' : suppress 'unrecognised disk label' for part
    DISKINFO="$(parted "$DISK" unit B print 2>/dev/null)"
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
            echocmd parted "$DISK" print
            warn "'parted' used 1000-based numbers"
            ;;
        devices) # return partitions
            local parts=()
            while IFS='' read -r line; do
                parts+=("$line")
            done < <(grep " [0-9]\+ " <<< "$DISKINFO" | awk '{ print  $1}')
            echo "${parts[@]/#/$DISK}"
            ;;
        size) # size [total|free], default: total, return in MB
            local total end

            # readlink: 'parted' shows the real path
            IFS=' :' read -r _ _ total <<< "$( \
                grep "^Disk $(readlink -f "$DISK"): " <<< "$DISKINFO" \
            )"
            total="${total%B}"
            case "$1" in
                free)
                    #!! 'size free' on partition is undefined !!#
                    [ "$DISKTYPE" = "disk" ] || return 1
                    # TODO: get free size based on fstype

                    # find out the last partition:
                    # Number  Start         End           Size          File system  Name  Flags
                    #         17408B        1048575B      1031168B      Free Space
                    #  1      1048576B      17178821119B  17177772544B               sdb1
                    #         17178821120B  17179852287B  1031168B      Free Space
                    end="$(grep "^ [0-9]\+ " <<< "$DISKINFO" | tail -1 | awk '{print $3}')" || true
                    end="${end:-0}"
                    end="${end%B}"
                    to_iec_MB "$((total - end))"
                    ;;
                total|*)
                    to_iec_MB "$total"
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
            echocmd wipefs --all --quiet --force "$DISK"
            # create new gpt part table
            echocmd parted --script --fix "$DISK" mklabel gpt || {
cat << EOF

    ---
    'parted $DISK mklabel gpt' failed, possible cause:

    1. $DISK may be busy because it is a raid member;

    Please do:

    1. find out which raid holds $DISK with 'raid ls'
    2. destroy the raid with 'raid /dev/mdX destroy'
    ---

EOF
                return 1
            }

            echocmd partprobe "$DISK" || true
            ;;
        part) # create [fstype] [size], size in [KMGTP]
            local size fstype part
            while test -n "$1"; do
                if par_is_size "$1"; then
                    size="$1"
                elif par_is_fstype "$1"; then
                    fstype="$1"
                else
                    break
                fi
                shift
            done

            part="$(grep -c "^ [0-9]\+ " <<< "$DISKINFO")" || true
            part="$DISK$((part + 1))"

            if test -z "$size"; then
                info "$DISK: create partition with remains bytes"
                # erase all partition(s) and create a new one
                echocmd parted --script --fix "$DISK" \
                    mkpart "$(basename "$part")" "$fstype" "2048s" 100%
            else
                local total start end
                # Disk /dev/sdb: 17179869184B
                total=$(grep "^Disk $DISK:" <<< "$DISKINFO" | awk '{print $NF}')
                start=$(grep "^ [0-9]\+ " <<< "$DISKINFO" | tail -1 | awk '{print $3}') || true

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
        delete) # delete [part]
            if [ "$DISKTYPE" = "part" ] || [ -n "$1" ]; then
                local part pno
                if [ "$DISKTYPE" = "part" ]; then
                    part="$DISK"
                else
                    part="$1"
                fi
                if [[ "$DISK" =~ nvme ]]; then
                    pno="${DISK##*p}"
                    DISK="${DISK%%p[0-9]*}" # nvme0n1p1
                else
                    pno="${DISK##*[a-z]}"
                    DISK="${DISK%%[0-9]*}"  # sda1
                fi
                prompt "$DISK: delete part $part?" false ans
                ans_is_true "$ans" || return 1

                echocmd parted --script --fix "$DISK" rm "$pno"
            else
                prompt "$DISK: delete from kernel?" false ans
                ans_is_true "$ans" || return 1

                local scsi
                scsi="$(readlink -f "/sys/block/$DISKNAME")"
                scsi="$(realpath "$scsi/../../../../")"
                echo offline > "/sys/block/$DISKNAME/device/state"
                echo 1 > "/sys/block/$DISKNAME/device/delete"

                info "$DISK: online with \`echo '- - -' > $(find "$scsi" -name scan -type f)'"
            fi
            ;;
        fstype) # fstype [ext4|btrfs|...]
            if [ "$DISKTYPE" = "disk" ]; then
                error "$DISK: unsupported device type($DISKTYPE)"
                return 1
            fi

            if [ -z "$1" ]; then
                grep ' [0-9]\+ ' <<< "$DISKINFO" | awk '{print $5}' || true
            else
                case "$1" in
                    btrfs)
                        echocmd mkfs.btrfs "$DISK" --quiet --force
                        ;;
                    ext2|ext3|ext4)
                        echocmd mkfs.ext4 "$DISK" -t "$1" -q
                        ;;
                    *)
                        echocmd mkfs -t "$1"
                        ;;
                esac
            fi
            ;;
        resizefs) # resizefs <min|max|[+/-]size>
            if [ "$DISKTYPE" = "disk" ]; then
                error "$DISK: unsupported device type($DISKTYPE)"
                return 1
            fi

            local size="$1"
            local fstype mounted
            fstype="$(disk "$DISK" fstype)"
            mounted="$(lsblk -o MOUNTPOINT "$DISK" | sed -n '2p')"
            case "$fstype" in
                ext2|ext3|ext4)
                    if test -n "$mounted"; then
                        echocmd umount "$DISK"
                    fi
                    case "$size" in
                        min)
                            echocmd resize2fs -M "$DISK"
                            ;;
                        max)
                            size="$(disk "$DISK" size)"
                            size="$(to_iec_MB "$size")"
                            echocmd resize2fs "$DISK" "$size"
                            ;;
                        *)
                            echocmd resize2fs "$DISK" "$size"
                            ;;
                    esac
                    if test -n "$mounted"; then
                        echocmd mount -t "$fstype" "$DISK" "$mounted"
                    fi
                    ;;
                btrfs)
                    # BTRFS needs to be mounted to be able to resize the partition.
                    if test -z "$mounted"; then
                        mounted="/tmp/btrfs-$$"
                        mkdir -pv "$mounted"
                        echocmd mount -t btrfs "$DISK" "$mounted"
                    fi

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
                    ;;
                *)
                    error "$DISK: unsupported fstype $fstype"
                    return 1
                    ;;
            esac

            # pass through
            disk "$DISK" fsck
            ;;
        fsck)
            if [ "$DISKTYPE" = "disk" ]; then
                error "$DISK: unsupported device type($DISKTYPE)"
                return 1
            fi

            local fstype
            fstype="$(disk "$DISK" fstype)"
            case "$fstype" in
                ext2|ext3|ext4)
                    echocmd e2fsck -f "$DISK"
                    ;;
                btrfs)
                    echocmd btrfs check --force "$DISK"
                    ;;
                *)
                    error "$DISK: unsupported fstype $fstype"
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
        config) # [update]
            mkdir -pv /etc/mdadm

            cp /etc/mdadm/mdadm.conf "mdadm-$(date '+%Y%m%d-%H%M%S').conf" || true

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

    local MDINFO MDLEVEL
    if [ -b "$MDDEV" ]; then
        MDINFO="$(mdadm --detail "$MDDEV")"
        MDLEVEL="$(grep -F 'Raid Level :' <<< "$MDINFO" | awk '{print $NF}')"
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
            case "$1" in
                spare)
                    grep -Fw "spare" <<< "$MDINFO" | awk '{print $NF}' | xargs
                    ;;
                active|*)
                    grep -Fw "active sync" <<< "$MDINFO" | awk '{print $NF}' | xargs
                    ;;
            esac
            ;;
        level)
            test -z "$MDLEVEL" && return 1 || echo "$MDLEVEL"
            ;;
        size) # <total|parts>, default: total
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
                    size=$(grep 'Array Size :' <<< "$MDINFO" | awk '{print $4}')
                    to_iec "$size"K
                    ;;
            esac
            ;;
        create) # create [level] [fstype] partitions ...
            local mindev fstype
            while [ -n "$1" ]; do
                if par_is_fstype "$1"; then
                    fstype="$1"
                elif par_is_raidlevel "$1"; then
                    MDLEVEL="$1"
                else
                    break
                fi
                shift
            done

            # space efficient raid type with data parity
            if [ -z "$MDLEVEL" ]; then
                case "$#" in
                    2)  MDLEVEL=raid1 ;;
                    *)  MDLEVEL=raid5 ;;
                esac
            fi

            # mini devices requirements
            case "$MDLEVEL" in
                raid0|0)    mindev=2 ;;
                raid1|1)    mindev=2 ;;
                raid5|5)    mindev=3 ;;
                raid6|6)    mindev=4 ;;
                raid10|10)  mindev=4 ;;
            esac

            if [ $# -lt "$mindev" ]; then
                error "$MDDEV: $MDLEVEL requires at least $mindev devices"
                return 1
            fi

            echo yes | echocmd mdadm    \
                --verbose               \
                --create "$MDDEV"       \
                --force                 \
                --assume-clean          \
                --level="$MDLEVEL"      \
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

            IFS=' ' read -r -a parts <<< "$(raid "$MDDEV" devices)"

            echocmd mdadm --action "idle" "$MDDEV" || true
            echocmd umount "$MDDEV" || true
            echocmd mdadm --stop "$MDDEV"
            echocmd mdadm --remove "$MDDEV" 2> /dev/null || true

            # remove superblocks
            for part in "${parts[@]}"; do
                echocmd mdadm --zero-superblock "$part"
            done
            ;;
        add) # add [spare] partitions ...
            #!! replace failed devices or grow the raid !!#
            local spare
            case "$1" in
                spare)  spare=true; shift ;;
            esac

            echocmd mdadm --action "idle" "$MDDEV"

            local mdcnt total final
            mdcnt="$(grep -F 'Raid Devices :'  <<< "$MDINFO" | awk '{print $NF}')"
            total="$(grep -F 'Total Devices :' <<< "$MDINFO" | awk '{print $NF}')"

            # remove failed parts
            if ! mdadm --detail --test "$MDDEV" &>/dev/null; then
                warn "$MDDEV: degraded, remove failed device(s)"

                # remove failed devices
                while read -r part; do
                    info "$MDDEV: remove faulty $part"
                    echocmd mdadm --manage "$MDDEV" --fail "$part" --remove "$part" --force
                done < <(grep "faulty" <<< "$MDINFO" | awk '{print $NF}')

                # remove detached devices
                echocmd mdadm "$MDDEV" --fail detached --remove detached
            fi

            # add devices as hot spare
            echocmd mdadm --manage "$MDDEV" --add "$@"

            # grow if not add as spare
            if ! [ "$spare" = "true" ]; then
                # update MDINFO
                MDINFO="$(mdadm --detail "$MDDEV")"
                final="$(grep -F 'Total Devices :' <<< "$MDINFO" | awk '{print $NF}')"
                #!! grow with new added devices only !!#
                if [ "$final" -gt "$mdcnt" ]; then
                    # raid1 -> raid5
                    if [[ "$MDLEVEL" =~ raid1 ]]; then
                        info "$MDDEV: raid1 => raid5"
                        MDLEVEL=raid5
                        echocmd mdadm --grow "$MDDEV" --level="$MDLEVEL"
                    fi

                    info "$MDDEV: extend raid $mdcnt -> $final"
                    echocmd mdadm --grow "$MDDEV" --raid-devices="$((mdcnt + final - total))"

                    echocmd partprobe "$MDDEV"
cat << EOF
$(echo -e "$RED
    ---
    The mdadm raid device is growing, but its status may no be updated.
    The following code may not work as expect, so something needs to be
    updated again after the raid device resync is complete.
    ---
$NC")
EOF
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

            local mdcnt total
            mdcnt="$(grep -F 'Raid Devices :' <<< "$MDINFO" | awk '{print $NF}')"
            total="$(grep -F 'Working Devices :' <<< "$MDINFO" | awk '{print $NF}')"

            if [ "$total" -lt "$mdcnt" ]; then
                local partsize raidsize
                partsize="$(raid "$MDDEV" size part)"
                raidsize="$(raid_size "$MDLEVEL" "$partsize" "$total")"

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
            #echocmd vgdisplay "$VGNAME" -S lvname="$LVNAME"
            echocmd lvdisplay "$LVDEV" --maps
            ;;
        size) # size
            #[ -b "$LVDEV" ] || return 0 #
            #LVSIZE="$(lvs --noheadings -S lvname="$LVNAME" -o lv_size | awk '{print $NF}')"
            #LVSIZE="${LVSIZE#<}" # remove leading '<'
            ##!! lvm use [kmgtp] with 1024 base !!#
            #to_iec "${LVSIZE^^}"
            disk "$LVDEV" size "$@" | to_iec
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
            # zfs_member signature detected on ...
            yes | echocmd pvcreate "$@"
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
        resize) # resize <min|max|size>
            local size="$1"
            size="${size:-max}"

            # resize fs to minimal first
            echofunc disk "$LVDEV" resizefs min

            echocmd pvresize "$(volume "$LVDEV" devices)"
            case "$size" in
                max)
                    echocmd lvextend --extents '+100%FREE' "$LVDEV"
                    ;;
                *)
                    echocmd lvextend --extents "$size" "$LVDEV"
                    ;;
            esac
            echofunc disk "$LVDEV" resizefs "$size"
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
            return 0
            ;;
    esac

    local HDEV="$1"; shift
    local command="$1"; shift

    # vg0-volume0 => vg0/volume0
    HDEV="${HDEV/-//}"
    # prepend /dev
    [[ "$HDEV" =~ ^/dev ]] || HDEV="/dev/$HDEV"

    local VGNAME LVNAME
    IFS='/' read -r _ _ VGNAME LVNAME <<< "$HDEV"
    if [ -z "$VGNAME" ] || [ -z "$LVNAME" ]; then
        error "$HDEV: bad devfs, expected /dev/Hg0/H0"
        return 1
    fi

    case "$command" in
        status)
            echo "    --- $HDEV ($(volume "$HDEV" mount)) ---"
            printf "%14s : %s\n" "Total Size"   "$(volume "$HDEV" size | to_iec)"
            printf "%14s : %s\n" "Free Size"    "$(volume "$HDEV" size free | to_iec)"
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
                sed 's/\(.*sd[a-z]\+\).*$/\1/g' | \
                sed 's/\(.*nvme[0-9]\+n[0-9]\+\)p.*$/\1/g' | \
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
            local fstype="btrfs" # default
            while test -n "$1"; do
                if par_is_fstype "$1"; then
                    fstype="$1"
                else
                    break
                fi
                shift
            done

            local topoinfo="/tmp/hybrid-create-topoinfo-$$"

            # save disks info
            for disk in "$@"; do
                local dsz
                dsz="$(disk "$disk" size)"
                printf "%s %s %s\n"                     \
                    "$disk"                             \
                    "$(to_iec "$dsz")"                  \
                    "$(to_iec_MB "$dsz" | from_iec)"
            done | map_disks_to_raid > "$topoinfo"

            echo -e "\n--- hybrid volume topology ---"
            cat "$topoinfo"
            echo -e "--- end ---\n"

            prompt "$HDEV: devices $* will be formated, continue?" false ans
            ans_is_true "$ans" || return 1

            # wipe disks
            for disk in "$@"; do
                echo yes | echofunc disk "$disk" gpt
            done

            local devices=()
            while read -r pv _ psz disks; do
                local parts=()
                for disk in $disks; do
                    echofunc disk "$disk" part "$psz"
                    parts+=("$(disk "$disk" devices | awk '{print $NF}')")
                done

                echofunc raid "$pv" create "${parts[@]}" || true
                devices+=("$pv")

                if ! test -b "$pv"; then
                    error "$HDEV: create $pv failed"
cat << EOF

    ===
    Create pv/raid device failed, possible cause:

    1. The raid has been assembled by system, which cause device busy;
    2. The raid was stopped and re-created with different devfs/name;
    3. The $pv is 'Not POSIX compatible.'
    ===

EOF
                fi
            done < "$topoinfo"

            echo -e "\n--- pv/raid state ---"
            cat /proc/mdstat
            echo -e "--- end ---\n"

            # ugly code:
            warn "$HDEV: wait until pv/raid device(s) ready"
            sleep 3

            # create volume: force linear
            echofunc volume "$HDEV" create linear "${devices[@]}" || true

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
            echofunc disk "$HDEV" fstype "$fstype"
            ;;
        add) # add devices ...
            local diskinfo="/tmp/hybrid-add-diskinfo-$$"
            local topoinfo="/tmp/hybrid-add-topoinfo-$$"

            # save disks info, ascend
            for disk in "$@"; do
                local dsz
                dsz="$(disk "$disk" size)"
                printf "%s %s %s\n"                     \
                    "$disk"                             \
                    "$(to_iec "$dsz")"                  \
                    "$(to_iec_MB "$dsz" | from_iec)"
            done | sort -k 3 -n -s > "$diskinfo"

            # update hybrid volume topology
            for pv in $(volume "$HDEV" devices); do
                local psz
                psz="$(raid "$pv" size part)"
                # /dev/md0 1G <1G in Bytes>
                printf "%s %s %s\n" "$pv" "$(to_iec "$psz")" "$(from_iec "$psz")"
            done > "$topoinfo"

            #!! descend by part size, so match biggest part first !!#
            local descend
            descend="$(sort -k 3 -nr -s < "$topoinfo")"

            while read -r disk _ dsz; do
                while read -r pv _ psz; do
                    if [ "$psz" -gt "$dsz" ]; then
                        continue
                    fi
                    dsz=$((dsz - psz))
                    sed -i "s|$pv.*$|& $disk|" "$topoinfo"
                done <<< "$descend"

                # disk remains size
                printf "%s %s %s\n" "$disk" "$(to_iec "$dsz")" "$dsz"
            done < "$diskinfo" > "$diskinfo.1"

            ## append with remains size
            for disk in $(hybrid "$HDEV" devices); do
                local dsz
                dsz="$(disk "$disk" size free)"
                printf "%s %s %s\n"                     \
                    "$disk"                             \
                    "$(to_iec "$dsz")"                  \
                    "$(to_iec_MB "$dsz" | from_iec)"
            done >> "$diskinfo.1"

            map_disks_to_raid < "$diskinfo.1" >> "$topoinfo"

            echo -e "\n--- hybrid volume topology ---"
            cat "$topoinfo"
            echo -e "--- hybrid volume topology ---\n"

            prompt "$HDEV: $* will be formated, continue?" false ans
            ans_is_true "$ans" || return 1

            for disk in "$@"; do
                # wipe disks
                echo yes | echofunc disk "$disk" gpt
            done

            local extra=()
            while read -r pv _ psz disks; do
                info "$HDEV: prepare parts for pv/raid device $pv"

                local parts=()
                for disk in $disks; do
                    echofunc disk "$disk" part "$psz"
                    parts+=("$(disk "$disk" devices | awk '{print $NF}')")
                done

                if [ -b "$pv" ]; then
                    info "$HDEV: add ${parts[*]} to $pv"
                    echofunc raid "$pv" add "${parts[@]}"
                else
                    info "$HDEV: new $pv with ${parts[*]}"
                    echofunc raid "$pv" create "${parts[@]}"
                    extra+=("$pv")
                fi
            done < "$topoinfo"

            if test -n "${extra[*]}"; then
                info "$HDEV: extend with ${extra[*]}"
                echofunc volume "$HDEV" add "${extra[@]}"
            fi

            prompt "$HDEV: wait for pv/raid device(s) reshaping (it takes minutes to hours)?" false ans
            if ans_is_true "$ans"; then
                while grep -F "reshape" /proc/mdstat &>/dev/null; do
                    warn "$HDEV: wait until pv/raid device(s) reshape done"
                    sleep 3
                done
                # Known Issue:
                #  'New size (nnnn extents) matches existing size'
                # fall through to resize:
                echofunc volume "$HDEV" resize max || true
            else
cat << EOF
$(echo -e "$RED
    ---
    The hybrid volume size doesn't update now, as the pv/raid device
    is reshaping, run command when its done:

    sudo partprobe $(volume "$HDEV" devices)
    sudo pvresize $(volume "$HDEV" devices)
    sudo lvextend --extents +100%FREE $HDEV

    OR

    sudo $NAME $HDEV resize max
    ---
$NC")
EOF
            fi
            ;;
        resize) # resize [max|size]
            volume "$HDEV" resize "$@"
            ;;
        delete)
            error "TODO: delete device from hybrid volume"
            # => may have to move data around
            return 1
            ;;
        *)
            error "unknown command $command"
            return 1
            ;;
    esac
}

# /dev/sdb 10.00G 10737418240
# /dev/sdc 20.00G 21474836480
# /dev/sdd 20.00G 21474836480
#
# =>
#
# /dev/md0 10.00G 10737418240 /dev/sdb /dev/sdc /dev/sdd
# /dev/md1 10.00G 10737418240 /dev/sdc /dev/sdd

map_disks_to_raid() {
    local diskinfo

    # ascend disks info <pipe>
    diskinfo="$(sort -k 3 -n -s)"

    local mdno=0
    while test -b "/dev/md$mdno"; do
        mdno=$((mdno + 1))
    done

    local lino=0 used=0
    while read -r disk _ dsz; do
        local pv psz disks=()

        IFS=' ' read -r -a disks <<< "$(
            awk "NR > $lino {print \$1}" <<< "$diskinfo" | xargs
        )"
        if [ "${#disks[@]}" -lt 2 ]; then
            break # no more disks
        fi

        # check free spaces
        psz=$((dsz - used))
        if [ "$psz" -ge "$RAID_PART_LIMIT_MIN" ]; then
            used=$((used + psz))

            pv="/dev/md$mdno"
            printf "%s %s %s %s\n"      \
                "$pv"                   \
                "$(to_iec "$psz")"      \
                "$(from_iec "$psz")"    \
                "${disks[*]}"
            mdno=$((mdno + 1))
        fi
        lino=$((lino + 1))
    done <<< "$diskinfo"
}

examples() {
    cat << EOF
-- disk examples --
$NAME disk info                                     # show all disks informations
$NAME disk /dev/sda status                          # show /dev/sda status
$NAME disk /dev/sda gpt                             # create a gpt partition table
$NAME disk /dev/sda part 10G                        # create a new 10G partition
$NAME disk /dev/sda size free                       # get disk free space size

-- raid examples --
$NAME raid ls                                       # list all raid devices
$NAME raid info                                     # show all raid devices info
$NAME raid /dev/md0 create /dev/sd[a-d]1            # create a new raid device
$NAME raid /dev/md0 add /dev/sde1                   # add partition(s) to existing raid device
$NAME raid /dev/md0 size part                       # get raid device's partition size
$NAME raid /dev/md0 destroy                         # destroy an existing raid device
$NAME raid /dev/md0 status                          # show raid device status

-- volume examples --
$NAME volume info                                   # show all logical volume info
$NAME volume /dev/vg0/volume0 create /dev/md[12]    # create a new logical volume
$NAME volume /dev/vg0/volume0 add /dev/md3          # add new device(s) to existing logical volume
$NAME volume /dev/vg0/volume0 destroy               # destroy an existing logical volume
$NAME volume /dev/vg0/volume0 size                  # get logical volume size
$NAME volume /dev/vg0/volume0 show                  # show logical volume status

-- hybrid volume examples --
$NAME ls                                            # list all hybrid volumes
$NAME /dev/vg0/volume0 create btrfs /dev/sd[a-z]    # create new hybrid volume on devices
$NAME /dev/vg0/volume0 add /dev/sde                 # add new device(s) to existing hybrid volume
$NAME /dev/vg0/volume0 destroy                      # destroy a hybrid volume
$NAME /dev/vg0/volume0 status                       # show hybrid volume status
$NAME /dev/vg0/volume0 mount /services              # mount a hybrid volume
EOF
}

case "$1" in
    hybrid|volume|raid|disk)
        echofunc "$@"
        ;;
    examples)
        examples
        ;;
    "")
        hybrid ls
        ;;
    *)
        echofunc hybrid "$@"
        ;;
esac

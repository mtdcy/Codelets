#!/bin/bash
#
# origin: https://ubuntuforums.org/showthread.php?t=1494846

# NEED FOLLOWING UTILS
# -- hdparm
# -- lvm


# Add VM tuning stuff?
#vm.swappiness = 1               # set low to limit swapping
#vm.vfs_cache_pressure = 50      # set lower to cache more inodes / dir entries
#vm.dirty_background_ratio = 5   # set low on systems with lots of memory
                                 # Too HIGH on systems with lots of memory
                                 # means huge page flushes which will hurt IO performance
#vm.dirty_ratio = 10             # set low on systems with lots of memory


# DEFAULTS
MDDEV=${1:-md0}         # e.g. md51 for /dev/md51
BLOCKSIZE=4		        # of filesystem in KB (should I determine?)
FORCECHUNKSIZE=true	    # force max  sectors KB to chunk size > 512
TUNEFS=true		        # run tune2fs on filesystem if ext[3|4]
SCHEDULER=deadline      # cfq / noop / anticipatory / deadline
NR_REQUESTS=64          # NR REQUESTS
NCQDEPTH=31             # NCQ DEPTH
MDSPEEDLIMIT=200000     # Array speed_limit_max in KB/s



# ----------------------------------------------------------------------
#
# BODY
#
# ----------------------------------------------------------------------

# INIT VARIABLES
RAIDLEVEL=0
NDEVICES=0
CHUNKSIZE=0
MDDEVSTATUS=0
DISKS=""
SPARES=""
NUMDISKS=0
NUMSPARES=0
NUMPARITY=0
NCQ=0
NUMNCQDISKS=0

RASIZE=0
MDRASIZE=0
STRIPECACHESIZE=0
MINMAXHWSECKB=999999999

STRIDE=0
STRIPEWIDTH=0

[ -e "/dev/$MDDEV" ] || {
    echo "/dev/$MDDEV not exists, abort."
    exit 1
}

# GET DETAILS OF MDDEV
IFS=' :' read -r _ _ RAIDLEVEL <<< "$(mdadm --detail /dev/$MDDEV | grep -F "Raid Level")"

case $RAIDLEVEL in
    "raid6")    NUMPARITY=2 ;;
    "raid5")    NUMPARITY=1 ;;
    "raid4")    NUMPARITY=1 ;;
    "raid3")    NUMPARITY=1 ;;
    "raid1")    NUMPARITY=1 ;;
    "raid0")    NUMPARITY=0 ;;
    *)          echo "Unknown RAID level" && exit 1 ;;
esac

echo ""
echo "======================================================================"
echo "FOUND MDDEV - $MDDEV / $RAIDLEVEL"
IFS=' :' read -r _ _ CHUNKSIZE <<< "$(mdadm --detail "/dev/$MDDEV" | grep -F "Chunk Size")"
CHUNKSIZE="${CHUNKSIZE%K}"

echo "-- Chunk Size = $CHUNKSIZE KB"

IFS=' :' read -r _ MDDEVSTATUS _ DEVICES <<< "$(grep "^$MDDEV : " /proc/mdstat)"

# GET LIST OF DISKS IN MDDEV
echo ""
echo "Getting active devices and spares list"
for DISK in $DEVICES; do
    IFS='[]()' read -r LETTER _ <<< "$DISK" # => partition
    case $LETTER in
        nvme*)  LETTER=${LETTER%p[[:digit:]]}   ;;
        sd*)    LETTER=${LETTER%[[:digit:]]}    ;;
    esac

    if ! grep -F "(S)" <<< "$DISK"; then
        echo "-- $DISK - Active"
        DISKS="$DISKS $LETTER"
        NUMDISKS=$((NUMDISKS+1))
    else
        echo "-- $DISK - Spare"
        SPARES="$SPARES $LETTER"
        NUMSPARES=$((NUMDISKS+1))
    fi
done
echo ""
echo "Active Disks ($NUMDISKS) - $DISKS"
echo "Spares Disks ($NUMSPARES) - $SPARES"

# DETERMINE SETTINGS
RASIZE=$((NUMDISKS * (NUMDISKS - NUMPARITY) * 2 * CHUNKSIZE))   # Disk read ahead in 512byte blocks
MDRASIZE=$((RASIZE * NUMDISKS))                                 # Array read ahead in 512byte blocks
STRIPECACHESIZE=$((RASIZE * 2 / 8))                             # in pages per device

for DISK in $DISKS $SPARES; do
    # check max_hw_sectors_kb
    max_hw_sectors_kb="$(cat "/sys/block/$DISK/queue/max_hw_sectors_kb")"
    if [ "$max_hw_sectors_kb" -lt "$MINMAXHWSECKB" ]; then
        MINMAXHWSECKB=$max_hw_sectors_kb
    fi

    # check NCQ
    if hdparm -I "/dev/$DISK" | grep NCQ &> /dev/null; then
        NUMNCQDISKS=$((NUMNCQDISKS + 1))
    fi
done

if [ "$CHUNKSIZE" -le "$MINMAXHWSECKB" ]; then
    MINMAXHWSECKB=$CHUNKSIZE
fi

if [ "$NUMNCQDISKS" -lt "$NUMDISKS" ]; then
    NCQDEPTH=1
    echo "WARNING! ONLY $NUMNCQDISKS DISKS ARE NCQ CAPABLE!"
fi

echo ""
echo "TUNED SETTINGS"
echo "-- DISK READ AHEAD  = $RASIZE blocks"
echo "-- MDDEV READ AHEAD = $MDRASIZE blocks"
echo "-- STRIPE CACHE     = $STRIPECACHESIZE pages"
echo "-- MAX SECTORS KB   = $MINMAXHWSECKB KB"
echo "-- NCQ DEPTH        = $NCQDEPTH"

# TUNE MDDEV
echo ""
echo "TUNING MDDEV"
echo "-- $MDDEV read ahead set to $MDRASIZE blocks"
echo "-- $MDDEV stripe_cache_size set to $STRIPECACHESIZE pages"
echo "-- $MDDEV speed_limit_max set to $MDSPEEDLIMIT"

blockdev --setra "$MDRASIZE" "/dev/$MDDEV" # TODO: blocks to kb
#echo $MDRASIZE          > "/sys/block/$MDDEV/queue/read_ahead_kb"
echo $STRIPECACHESIZE   > "/sys/block/$MDDEV/md/stripe_cache_size"
#echo 32768              > "/sys/block/$MDDEV/md/stripe_cache_size"
echo $MDSPEEDLIMIT      > /proc/sys/dev/raid/speed_limit_max

# TUNE DISKS
echo ""
echo "TUNING DISKS"
echo "Settings : "
echo "        read ahead = $RASIZE blocks"
echo "    max_sectors_kb = $MINMAXHWSECKB KB"
echo "         scheduler = $SCHEDULER"
echo "       nr_requests = $NR_REQUESTS"
echo "       queue_depth = $NCQDEPTH"

for DISK in $DISKS $SPARES; do
    echo "-- Tuning $DISK"
    blockdev --setra $RASIZE "/dev/$DISK"
    #echo $RASIZE        > "/sys/block/$DISK/queue/read_ahead_kb"
    echo $MINMAXHWSECKB > "/sys/block/$DISK/queue/max_sectors_kb"
    echo $SCHEDULER     > "/sys/block/$DISK/queue/scheduler"
    echo $NR_REQUESTS   > "/sys/block/$DISK/queue/nr_requests"

    # no queue_depth for nvme
    [ -w "/sys/block/$DISK/device/queue_depth" ] &&
    echo $NCQDEPTH      > "/sys/block/$DISK/device/queue_depth"
done

# TUNE ext3/exti4 FILESYSTEMS
STRIDE=$((CHUNKSIZE / BLOCKSIZE))
STRIPEWIDTH=$((CHUNKSIZE / BLOCKSIZE * (NUMDISKS - $NUMPARITY)))
echo ""
echo "TUNING FILESYSTEMS"
echo "For each filesystem on this array, run the following command:"
echo "  tune2fs -E stride=$STRIDE,stripe-width=$STRIPEWIDTH <filesystem>"
echo ""

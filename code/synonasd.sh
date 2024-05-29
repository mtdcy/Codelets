#!/bin/bash
# A pretty synology nas monitor script.
# Copyright (c) Chen Fang 2024, mtdcy.chen@gmail.com.
#
# Howto:
#  控制面板 - 任务计划 - 添加开机任务(root):
#   /path/to/synonasd.sh &

NAME="$(basename "$0")"

# custom path(s)
WORKDIR="/volume1/Workspace"
NOTIFIER="$WORKDIR/Docker/Messages/chanify-sender.sh"
LOGFILE="$WORKDIR/Logs/${NAME/%.sh/.log}"
PIDFILE=/var/run/synonasd.pid
USER=mtdcy

[ "$(id -u)" -ne 0 ] && exec sudo "$0" "$@"

cd "$(dirname "$0")" || true

mkdir -pv "$(dirname "$LOGFILE")"
exec 1> >(tee -a "$LOGFILE") 2>&1

[ -f $PIDFILE ] && pkill --pidfile $PIDFILE
echo $$ > $PIDFILE

run_as_user() {
    sudo -u $USER "$@"
}

info() { echo "== $(date '+%Y/%m/%d %H:%M:%S'): $NAME($$) $* == "; }

# init
./synonasctl.sh postinit setfanspeed sethosts iperfd

#!! no space in filenames
TARGETS=(
    /etc
    "$WORKDIR/Docker/Web/swag/etc/letsencrypt/live/mtdcy.top/privkey.pem"
    "$WORKDIR/Shares/uploads/data.ip"
    "$WORKDIR/Shares/uploads/static"
)

info "start @ ${TARGETS[*]}"

inotifywait --exclude '\.db' -q -r -m -e close_write,move,delete "${TARGETS[@]}" |
while read -r target event file; do
    info "event > $target $event $file"
    case "$target" in
        /etc*)
            case "$file" in
                synoinfo.conf)
                    ./synonasctl.sh setfanspeed
                    ;;
                hosts)
                    ./synonasctl.sh sethosts
                    ;;
            esac
            ;;
        */etc/letsencrypt/*)
            # takes long time
            "$WORKDIR/Docker/Web/install-letsencrypt-cert.sh" &
            ;;
        */uploads/data.ip/*)
            run_as_user "$WORKDIR/Shares/uploads/install-ip2route-data.sh"
            ;;
        */uploads/static/*)
            run_as_user "$WORKDIR/Shares/uploads/install-static.sh"
            ;;
    esac
done & # run in background, or inotifywait will block trap

#=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=#
# post processing
cleanup() {
    info "stopped, cleanup < $*"
    kill -9 $(jobs -p) 2> /dev/null

    PID=$(cat "$PIDFILE")

    if [ $$ -eq "$PID" ] || ! ps -p "$PID" > /dev/null; then
        info "stopped, notify clients ..."

        if test -n "$NOTIFIER"; then
cat << EOF | "$NOTIFIER" &> /dev/null
$NAME 停止运行

$(date '+%Y/%m/%d %H:%M:%S')

----

$(tail -n 5 "Logs/$LOGFILE")
EOF
        fi
    fi
}

trap_signal() {
    func=$1; shift
    for sig in "$@"; do
        trap "$func $sig" "$sig"
    done
}
trap_signal cleanup EXIT

while test -n "$(jobs)"; do
    info "wait for background jobs ..."
    wait
done

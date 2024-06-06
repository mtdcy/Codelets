#!/bin/bash
# A pretty synology nas monitor script.
# Copyright (c) Chen Fang 2024, mtdcy.chen@gmail.com.
#
# Howto:
#  控制面板 - 任务计划 - 添加开机任务(root):
#   /path/to/synonasd.sh &

NAME="$(basename "$0")"

# custom path(s)
NOTIFIER="./notify.sh"
LOGFILE="./Logs/${NAME/%.sh/.log}"
PIDFILE=/var/run/synonasd.pid
USER=mtdcy

[ "$(id -u)" -ne 0 ] && exec sudo "$0" "$@"

cd "$(dirname "$0")" || true

#mkdir -pv "$(dirname "$LOGFILE")"
#exec 1> >(tee -a "$LOGFILE") 2>&1

[ -f $PIDFILE ] && pkill --pidfile $PIDFILE
echo $$ > $PIDFILE

# run_as_user <username> commands ...
run_as_user() {
    sudo -u "$1" "${@:2}"
}

info() { echo "== $(date '+%Y/%m/%d %H:%M:%S'): $NAME($$) $* == "; }

# init
./synonasctl.sh postinit setfanspeed iperfd

info "$0 start"

watchrc="${1:-watchrc}"

IFS=' ' read -r -a LIST <<< "$(grep -v '^#' "$watchrc" | sed '/^$/d' | awk '{print $1}' | xargs)"

# attrib: file been replaced
inotifywait -q -r -m \
    -e modify,attrib,close_write,move,delete \
    "$watchrc" "${LIST[@]}" |
while read -r target event file; do
    info "event > $target $event $file"

    if [ "$target" = "$watchrc" ]; then
        info "$NAME $watchrc updated, restart..."
        exec "$0" "$@"
    fi

    IFS=' ' read -r _ action username <<< "$(grep -Fw "$target" "$watchrc")"
    if [ -f "$action" ]; then
        if test -n "$username"; then
            info "run $action as $username"
            run_as_user "$username" "$action"
        else
            info "run $action"
            $SHELL "$action"
        fi
    elif test -n "$action"; then
        if test -n "$username"; then
            info "run synonasctl.sh $action as $username"
            run_as_user "$username" ./synonasctl.sh "$action"
        else
            info "run synonasctl.sh $action"
            $SHELL synonasctl.sh "$action"
        fi
    fi

    # ugly code: 'attrib' only work the first time
    #  => solution: force reload
    if [ "$event" = "ATTRIB" ]; then
        sleep 3
        exec "$0" "$@"
    fi
done & # run in background, or inotifywait will block trap
BG=$!

#=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=#
# post processing
cleanup() {
    info "stopped, cleanup < $*"
    kill -9 $(jobs -p | xargs) 2> /dev/null

    PID=$(cat "$PIDFILE")

    if [ $$ -eq "$PID" ]; then
        info "stopped, notify clients ..."

        if test -n "$NOTIFIER"; then
cat << EOF | "$NOTIFIER" &> /dev/null
$NAME 停止运行

$(date '+%Y/%m/%d %H:%M:%S')

----

$(tail -n 5 "$LOGFILE")
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

sleep 3
info "$NAME wait for background jobs $(jobs -p | xargs)..."
wait $BG

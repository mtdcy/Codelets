#!/bin/bash

DISABLE_COLOR=false

BLACK="\e[30m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
LIGHT_GRAY="\e[37m"
DARK_GRAY="\e[90m"
LIGHT_RED="\e[91m"
LIGHT_GREEN="\e[92m"
LIGHT_YELLOW="\e[93m"
LIGHT_BLUE="\e[94m"
LIGHT_MAGENTA="\e[95m"
LIGHT_CYAN="\e[96m"
WHITE="\e[97m"
END="\e[0m"

if [ $DISABLE_COLOR == true ]; then
    BLACK=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    MAGENTA=""
    CYAN=""
    LIGHT_GRAY=""
    DARK_GRAY=""
    LIGHT_RED=""
    LIGHT_GREEN=""
    LIGHT_YELLOW=""
    LIGHT_BLUE=""
    LIGHT_MAGENTA=""
    LIGHT_CYAN=""
    WHITE=""
    END=""
fi

# 群晖DS 任务状态定义
TASK_STATUS_WAITING=1
TASK_STATUS_DOWNLOADING=2
TASK_STATUS_PAUSED=3
TASK_STATUS_FINISHING=4
TASK_STATUS_FINISHED=5
TASK_STATUS_HASH_CHECKING=6
TASK_STATUS_SEEDING=7
TASK_STATUS_FILEHOSTING_WAITING=8
TASK_STATUS_EXTRACTING=9
TASK_STATUS_ERROR=10
TASK_STATUS_BROKEN_LINK=11
TASK_STATUS_DESTINATION_NOT_EXIST=12
TASK_STATUS_DESTINATION_DENIED=13
TASK_STATUS_DISK_FULL=14
TASK_STATUS_QUOTA_REACHED=15
TASK_STATUS_TIMEOUT=16
TASK_STATUS_EXCEED_MAX_FILE_SYSTEM_SIZE=17
TASK_STATUS_EXCEED_MAX_DESTINATION_SIZE=18
TASK_STATUS_EXCEED_MAX_TEMP_SIZE=19
TASK_STATUS_ENCRYPTED_NAME_TOO_LONG=20
TASK_STATUS_NAME_TOO_LONG=21
TASK_STATUS_TORRENT_DUPLICATE=22
TASK_STATUS_FILE_NOT_EXIST=23
TASK_STATUS_REQUIRED_PREMIUM_ACCOUNT=24
TASK_STATUS_NOT_SUPPORTED_TYPE=25
TASK_STATUS_TRY_IT_LATER=26
TASK_STATUS_TASK_ENCRYPTION=27
TASK_STATUS_MISSING_PYTHON=28
TASK_STATUS_PRIVATE_VIDEO=29
TASK_STATUS_FTP_ENCRYPTION_NOT_SUPPORTED_TYPE=30
TASK_STATUS_EXTRACT_FAILED=31
TASK_STATUS_EXTRACT_FAILED_WRONG_PASSWORD=32
TASK_STATUS_EXTRACT_FAILED_INVALID_ARCHIVE=33
TASK_STATUS_EXTRACT_FAILED_QUOTA_REACHED=34
TASK_STATUS_EXTRACT_FAILED_DISK_FULL=35
TASK_STATUS_UNKNOWN=36

#trackerlistUrl="https://cdn.jsdelivr.net/gh/ngosang/trackerslist@master/trackers_all.txt"
trackerlistUrl="https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt"

trackerList=$(curl -f $trackerlistUrl 2>/dev/null)
if [[ $? != 0 ]]; then
    echo "Tracker list url unavailable please check url: $trackerlistUrl"
    exit 1
fi
trackerList=$(echo '"'$trackerList'"' | jq -c 'split(" ")')
trackerListLength=$(jq 'length' <<<$trackerList)

if [[ $trackerListLength == 0 ]]; then
    echo "No found tracker please check tracker list: $trackerlistUrl"
    exit 1
fi

pakcageList=$(synowebapi --exec api=SYNO.Core.Package method=list version=2 additional='["status"]' 2>/dev/null | jq -c '.data.packages | map(select(.id == "DownloadStation"))')

isRunning=$(jq -r 'map(select(.id == "DownloadStation") | .additional.status) | .[]' <<<$pakcageList)

if [ $isRunning != "running" ]; then
    echo -e "Download Station$RED not running$END exit"
    exit
fi

echo "Download Station is running go next step"

downloadList=$(synowebapi --exec api=SYNO.DownloadStation2.Task method=list version=2 limit=-1 "status=[$TASK_STATUS_DOWNLOADING]" 2>/dev/null | jq -c '.data.task | map(select(.type == "bt"))')
downloadListCount=$(jq 'length' <<<$downloadList)

if [[ $downloadListCount -eq 0 ]]; then
    echo "Not found bt download task"
    exit
fi

echo "Download tasks count: $downloadListCount"

for idx in $(seq 0 $((downloadListCount - 1))); do
    echo "----------------Task [$idx]------------------"
    task=$(jq -c ".[$idx]" <<<$downloadList)
    taskId=$(jq -r .id <<<$task)
    taskName=$(jq -r .title <<<$task)
    taskTrackerList=$(synowebapi --exec api=SYNO.DownloadStation2.Task.BT.Tracker method=list version=2 task_id="$taskId" limit=-1 2>/dev/null | jq -c '.')
    taskTrackerListMap=$(jq -c '.data.items | reduce .[] as $i ({}; .[$i.url] = 1)' 2>/dev/null <<<$taskTrackerList)
    if [[ $? != 0 ]]; then
        echo "Task: 【$taskName】 is busy skip task; $taskTrackerList"
        continue
    fi
    taskTrackerListCount=$(jq '.data.total' <<<$taskTrackerList)
    echo "Task:【$taskName】 has tracker count: $taskTrackerListCount"
    needAddedTrackerList=$(jq -c --argjson hashMap $taskTrackerListMap 'map(select(. | in($hashMap) == false))' <<<$trackerList)
    needAddedTrackerListLength=$(jq 'length' <<<$needAddedTrackerList)

    if [[ $needAddedTrackerListLength == 0 ]]; then
        echo "The task does not need to add a new tracker"
        continue
    fi

    echo "A list of trackers that need to be added to the task: $needAddedTrackerList , count: $needAddedTrackerListLength"

    result=$(synowebapi --exec api=SYNO.DownloadStation2.Task.BT.Tracker method=add version=2 task_id=$taskId tracker=$needAddedTrackerList 2>/dev/null)

    if [[ $(jq '.success' <<<$result) == true ]]; then
        echo "Task: [$taskName] tracker list add success"
    else
        echo "Task: [$taskName] tracker list add fail"
    fi
done

echo "Automatically add tracker script to complete"

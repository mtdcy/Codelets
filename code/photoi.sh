#!/bin/bash
# A photo import and organize script 
# Copyright (c) Chen Fang 2023, mtdcy.chen@gmail.com. 
# 
# v0.1  - 20231122, initial version
#
[ -f $(dirname $0)/xlib.sh ] && . $(dirname $0)/xlib.sh || xlog() { echo $@; }

usage() {
    cat << EOF
# A photo import and organize script 
# Copyright (c) Chen Fang 2023, mtdcy.chen@gmail.com. 
#
$(basename $0) <source dir> <dest dir> 

EOF
}
[ $# -lt 2 ] && usage && exit 1

src="$1"
dst="$2"

is_video_file() {
    case $(echo "$1" | tr 'A-Z' 'a-z') in 
        *.mov|*.mp4|*.mkv|*.m4a|*.3gp)	return 0;;
        *)								return 1;;
    esac
}

# get creation time => y m d H M S
creation_time() {
    local ts 
    if which exiftool 2>&1 > /dev/null; then
        # video files has a field 'Creation Date', which has time zone info.
        # but image files don't have it, yet its 'Create Date' has time zone info
        #  => WHY?
        if is_video_file "$1"; then
            ts=$(exiftool -T -creationDate "$1" 2> /dev/null)
        else
            ts=$(exiftool -T -createDate "$1" 2> /dev/null)
        fi
        # exiftool does not return error if field missing
        [ "$ts" = "-" ] && ts=""
    else
        # for synology only
        if is_video_file "$1"; then
            ts=$(synomediaparser "$1" 2> /dev/null | grep "szMDate" | cut -d'"' -f4)
        else
            ts=$(exiv2 -g Exif.Image.DateTime -Pv "$1" 2> /dev/null)
            # skip fake value
            [ "$ts" = "0000:00:00 00:00:00" ] && ts=""
        fi
    fi

    # empty string ?
    [ ! -z "$ts" -a "$ts" != " " ] && echo "$ts" && return 0

    # take modify date instead 
    echo $(stat -c %y "$1" | cut -d. -f1) && return 0
}

findc="find \"$src\" -type f"

# ignore @eaDir for DSM
findc+=" -not -path \"*/@eaDir/*\""
findc+=" -not -path \".DS_Store\""

eval $findc | while read file; do
#ts=$(creation_time "$file")
#echo -e "$(basename $file) \t${ts:=-}"
#continue

    # parse time string
    IFS=' :.-+' read y m d H M S _ <<< $(creation_time "$file")

    p="IMG"
    is_video_file "$file" && p="VID"

    # check whether target exists
    target="$dst/$y/$m/${p}_$y$m${d}_$H$M$S."${file##*.}

    exists=0
    while [ -f "$target" ]; do
        sum0=$(md5sum "$file" | cut -d' ' -f1)
        sum1=$(md5sum "$target" | cut -d' ' -f1)

        [ "$sum0" = "$sum1" ] && exists=1 && break

        S=$(expr $S + 1)

        target="$dst/$y/$m/${p}_$y$m${d}_$H$M$S."${file##*.}
    done

    # inplace import?
    [ "$file" = "$target" ] && xlog "$file skipped ..." && continue

    # already exists?
    if [ $exists -gt 0 ]; then 
        # when doing inplace importing, delete files will be danger
        if [ "$src" = "$dst" ]; then
            xlog "$file => $target, duplicate files ..."
            mkdir -p "$dst.dup/${target#$dst}"
            mv "$target" "$dst.dup/${target#$dst}"
        else
            xlog "$file => $target exists ..." 
        fi
        continue
    fi

    xlog "$file => $target"

    mkdir -pv $(dirname "$target")

    # inplace import?
    [ "$src" = "$dst" ] && mv "$file" "$target" || cp -a "$file" "$target"
done

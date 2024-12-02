#!/bin/bash

info () {
    echo -e "==\\033[31m $(date '+%Y/%m/%d %H:%M:%S'): $* \\033[0m=="
}

if ! which docker; then
    info "Please install docker first"
    exit 1
fi

if ! docker images | grep openwrt-builder; then
    docker build -t openwrt-builder                         \
        --build-arg LANG=$LANG                                  \
        --build-arg TZ=$(realpath --relative-to /usr/share/zoneinfo /etc/localtime) \
        --build-arg MIRROR=http://mirrors.mtdcy.top         \
        -f Dockerfile.openwrt
fi

# reuse packages
if ! test -d dl; then
    mkdir -p dl
    mount -o bind /volume2/public/packages dl
fi

# reuse packages
test -d dl || mkdir -p dl
PACKAGES=/volume2/public/packages

run() {
    docker run --rm -it                     \
        -u $(id -u):$(id -g)                \
        -v $PWD:$PWD                        \
        -v $PACKAGES:$PWD/dl                \
        openwrt-builder bash -li -c "cd $PWD && $*"
}

sed -i 's@https://git.openwrt.org/feed/packages.git@https://git.mtdcy.top:8443/mtdcy/openwrt-feed-packages.git@' feeds.conf.default
sed -i 's@https://git.openwrt.org/feed/routing.git@https://git.mtdcy.top:8443/mtdcy/openwrt-feeds-routing.git@' feeds.conf.default
sed -i 's@https://git.openwrt.org/feed/telephony.git@https://git.mtdcy.top:8443/mtdcy/openwrt-feeds-telephony.git@' feeds.conf.default
sed -i 's@https://github.com/destan19/fros-packages-openwrt.git@https://git.mtdcy.top:8443/mtdcy/fros-packages-openwrt.git@' feeds.conf.default

# update feeds
run ./scripts/feeds update -a
run ./scripts/feeds install -a

rm .config
touch .config
echo "CONFIG_TARGET_x86=y" >> .config
echo "CONFIG_TARGET_x86_64=y" >> .config
echo "CONFIG_USES_EXT4=y" >> .config
echo "CONFIG_VMDK_IMAGES=y" >> .config

# fros
echo "CONFIG_PACKAGE_fros=y" >> .config
echo "CONFIG_PACKAGE_fros_files=y" >> .config
echo "CONFIG_PACKAGE_luci-app-fros=y" >> .config

#run make menuconfig; exit
run make defconfig
run make V=s -j4

# vim:ft=sh:ff=unix:fenc=utf-8:et:ts=4:sw=4:sts=4
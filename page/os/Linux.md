
# Linux

## systemd 

```shell
#1. 以树形结构显示所有/某个服务启动耗时
systemd-analyze critical-chain
systemd-analyze critical-chain remote-fs.target

#2. 以树形结构显示所有/某个服务的状态
systemctl status
systemctl status remote-fs.target

#3. 以树形结构显示所有/某个服务之间的依赖关系
systemctl list-dependencies
systemctl list-dependencies remote-fs.target
```

### 默认编辑器

```shell
#1.
export SYSTEMD_EDITOR=vim 

sudo visudo
# add this line
Defaults env_keep += "SYSTEMD_EDITOR"

#2.
sudo update-alternatives --config editor
```

### 启动时间太长

```shell
sudo vim /etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service
# => 修改ExecStart参数
ExecStart=/lib/systemd/systemd-networkd-wait-online --any --timeout=30
```

## 必须禁用的服务

有些服务真的不是普通用户（包括一般服务器）需要的。真的搞不懂为什么要默认开启，而且CPU占用还不低。

```shell
sudo systemctl disable multipathd.service # 多路径存储
```

### 禁用cloud-init

```shell
#1. stop cloud-init 
sudo touch /etc/cloud/cloud-init.disabled
sudo reboot 

#2. Uninstall 
sudo dpkg-reconfigure cloud-init # uncheck everything except 'None'
sudo apt-get purge cloud-init
sudo rm -rf /etc/cloud/ && sudo rm -rf /var/lib/cloud/
```

## 同时使用`iptables`和`nft`

目前多数版本都已经切换到nftables后端，但前端支持同时使用`iptables`和`nft`。

如果遇到以下错误，则说明`iptables`和`nft`产生了冲突，这是由于`nft`已经定义了`iptables`所需要的三个表

`iptables v1.8.7 (nf_tables): table `filter' is incompatible, use 'nft' tool.`

```shell
sudo vim /etc/nftables.conf
# 删除该文件中以下三个表: table ip filter/nat/mangle

# 或者，禁用nftables.service
sudo systemctl disable nftables.service 
```

## netplan网卡脚本关联

参考[https://netplan.io/faq](https://netplan.io/faq)

Ubuntu默认使用netplan，为了兼容网卡的启动脚本，创建一个勾子：

```shell
vim /etc/networkd-dispatcher/routable.d/50-ifup-hooks

#!/bin/sh
for d in up post-up; do
    hookdir=/etc/network/if-${d}.d
    [ -e $hookdir ] && /bin/run-parts $hookdir
done
exit 0
```

## mount NFS 

```shell
sudo apt install nfs-common
```

### nfs client 

```shell
sudo mount <ip>:/path/to/nfs  /nfs/mount/pointer
```

### fstab 

```shell 
sudo vim /etc/fstab 

ip:/path/to/nfs /nfs/mount/pointer  nfs auto,bg,retry=30,nofail,noatime,nolock,tcp,actimeo=1800 0 0
# options: 
#   auto
#   retry=30    - retry for 30 min
#   noatime     - no not update inode access time
```

### systemd 

```shell 
cat << EOF | sudo tee '/etc/systemd/system/nfs-mount-poiner.mount'
[Unit]
Description=Mount NFS share
After=network-online.target

[Mount]
What=<ip>:/path/to/nfs
Where=/nfs/mount/pointer
Options=auto,bg,retry=30,nofail,noatime,nolock,tcp,actimeo=1800
Type=nfs
TimeoutSec=60

[Install]
WantedBy=remote-fs.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable nfs-mount-poiner.mount
sudo systemctl start nfs-mount-poiner.mount
sudo systemctl status nfs-mount-pointer.mount

# pros and cons 
sudo mount /nfs/mount/pointer  # Fail
sudo umount /nfs/mount/pointer # Ok
```

使用systemd挂载NFS的好处在于，可以将NFS做为其他service的依赖关系，直接将nfs.mount添加到service的After中即可。

== 2023.09.08 

mount unit 无法恰当处理mount出错的情况，这种情况可以使用service unit

```shell
[Unit]
Description=Mount NFS share
After=network-online.target

StartLimitIntervalSec=30
StartLimitBurst=30

[Service]
Restart=on-failure
ExecStart=/bin/mount -o auto,noatime,nolock,tcp,actimeo=1800 <ip>:/path/to/nfs /nfs/mount/pointer

[Install]
WantedBy=remote-fs.target
```

## GPU

### AMD 

官方[指导](https://amdgpu-install.readthedocs.io/en/latest/)

下载[驱动](https://www.amd.com/en/support/linux-drivers)

```shell
#1. 安装驱动
sudo apt install ./amdgpu-install_5.7.00.48.50700-1_all.deb
sudo amdgpu-install --no-32 --usecase=multimedia,opencl --vulkan=amdvlk --opencl=legacy,rocr # 根据自己的需求调整

sudo usermod -a -G render,video $LOGNAME
# => jellyfin需要使用gpu
sudo usermod -a -G render,video jellyfin

#2. 安装gpu工具rocm-smi等
sudo apt install rocm-smi-lib vainfo vulkan-tools radeontop

#3. 修正bug
sudo vim /etc/udev/rules.d/70-amdgpu.rules
# GROUP="video"
sudo vim /etc/default/grub
# => add amdgpu.dc=0 to GRUB_CMDLINE_LINUX_DEFAULT
# ===> 只有在遇到问题时才需要添加这个参数

#4. 重启
sudo update-grub
sudo reboot

#5. 验证 
journalctl -b -k -g amd # 查看驱动是否加载正常

sudo vainfo --display drm --device /dev/dri/renderD129
sudo vulkaninfo --summary | grep deviceName

/usr/lib/jellyfin-ffmpeg/ffmpeg -v debug -init_hw_device opencl
/usr/lib/jellyfin-ffmpeg/ffmpeg -v debug -init_hw_device vulkan
```

### Docker 

[参考](https://jellyfin.org/docs/general/administration/hardware-acceleration/amd/#configure-with-linux-virtualization)

```shell
sudo docker exec -u root -it jellyfin bash

apt update && apt install -y curl gpg
mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key | gpg --dearmor -o /etc/apt/keyrings/rocm.gpg
cat <<EOF | tee /etc/apt/sources.list.d/rocm.sources
Types: deb
URIs: https://repo.radeon.com/rocm/apt/latest
Suites: ubuntu
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/rocm.gpg
EOF
apt update && apt install -y rocm-opencl-runtime
exit
```

**主机和Docker的gpu驱动必须配置为一样的**

**调用错误的OpenCL**

在AMD平台上，Jellyfin可能调用错误的OpenCL库，删除不需要的icd文件

`rm /etc/OpenCL/vendors/nvidia.icd`

**No devices found on platform "AMD Accelerated Parallel Processing"**

`echo /opt/rocm/opencl/lib/libamdocl64.so > /etc/OpenCL/vendors/amdocl*.icd` 

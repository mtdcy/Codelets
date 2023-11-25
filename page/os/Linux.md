
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

### 禁用`multipathd`

多路径存储

```shell
sudo systemctl disable multipathd.socket
sudo systemctl mask multipathd.socket 
sudo systemctl disable multipathd.service
sudo systemctl mask multipathd.service 
```

### 禁用`cloud-init`

```shell
#1. stop cloud-init 
sudo touch /etc/cloud/cloud-init.disabled
sudo reboot 

#2. Uninstall 
sudo dpkg-reconfigure cloud-init # uncheck everything except 'None'
sudo apt-get purge cloud-init
sudo rm -rf /etc/cloud/ && sudo rm -rf /var/lib/cloud/
```

### 启用`/etc/rc.local`

```shell
sudo systemctl enable rc-local.service
sudo touch /etc/rc.local
sudo chmod a+x /etc/rc.local
```

`rc.local`内容：

```bash
#!/bin/bash
exec 1> >(logger -t $(basename $0)) 2>&1

# your code here

exit 0
```

## `sysctl.conf`

### IPv4 & IPv6



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

### NVidia

https://developer.nvidia.com/video-encode-decode-gpu-support-matrix

```shell
sudo ubuntu-drivers install nvidia:525
sudo reboot 
# check 
cat /proc/driver/nvidia/version
nvidia-smi
```

#### 多GPU处理

GPU初始化顺序可能与PCI插槽顺序无关：
```shell
ls -l /dev/dri/by-path                                                                                                                                    

lrwxrwxrwx 1 root root  8 Nov 24 23:45 pci-0000:05:00.0-card -> ../card1
lrwxrwxrwx 1 root root 13 Nov 24 23:45 pci-0000:05:00.0-render -> ../renderD129
lrwxrwxrwx 1 root root  8 Nov 24 23:56 pci-0000:06:00.0-card -> ../card0
lrwxrwxrwx 1 root root 13 Nov 24 23:45 pci-0000:06:00.0-render -> ../renderD128
```

```shell
sudo nvidia-xconfig
```

### AMD 

官方[指导](https://amdgpu-install.readthedocs.io/en/latest/)

下载[驱动](https://www.amd.com/en/support/linux-drivers)

```shell
#1. 安装驱动
wget https://repo.radeon.com/amdgpu-install/23.20.00.48/ubuntu/jammy/amdgpu-install_5.7.00.48.50700-1_all.deb
sudo apt install ./amdgpu-install_5.7.00.48.50700-1_all.deb
sudo amdgpu-install --no-32 --usecase=graphics,multimedia,opencl --vulkan=amdvlk --opencl=legacy,rocr # 根据自己的需求调整

sudo usermod -a -G render,video $LOGNAME
# => jellyfin需要使用gpu
sudo usermod -a -G render,video jellyfin

#2. 安装gpu工具rocm-smi等
sudo apt install rocm-smi-lib vainfo vulkan-tools radeontop

#3. 修正bug
sudo vim /etc/udev/rules.d/70-amdgpu.rules
# GROUP="video"

sudo vim /etc/default/grub && sudo update-grub
# => add amdgpu.dc=0 to GRUB_CMDLINE_LINUX_DEFAULT
# ===> 只有在遇到问题时才需要添加这个参数

#4. 重启
sudo reboot

#5. 验证 
journalctl -b -k -g amd # 查看驱动是否加载正常

sudo vainfo --display drm --device /dev/dri/renderD129
sudo vulkaninfo --summary | grep deviceName

/usr/lib/jellyfin-ffmpeg/ffmpeg -v debug -init_hw_device opencl
/usr/lib/jellyfin-ffmpeg/ffmpeg -v debug -init_hw_device vulkan
```

**打开或关闭`Secure Boot`需要重新安装驱动**

**No devices found on platform "AMD Accelerated Parallel Processing"**

`echo /opt/rocm/opencl/lib/libamdocl64.so > /etc/OpenCL/vendors/amdocl*.icd` 

**调用错误的OpenCL**

在AMD平台上，Jellyfin可能调用错误的OpenCL库，删除不需要的icd文件

`rm /etc/OpenCL/vendors/nvidia.icd`

**`opencl=legacy`可能安装不上，这时需要禁用`Jellyfin`的`OpenCl`**

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


### VA-API

```shell
vainfo --display drm --device /dev/dri/renderD129

Trying display: drm
libva info: VA-API version 1.18.0
libva info: Trying to open /usr/lib/x86_64-linux-gnu/dri/radeonsi_drv_video.so
libva info: Found init function __vaDriverInit_1_14
libva info: va_openDriver() returns 0
vainfo: VA-API version: 1.18 (libva 2.18.0)
vainfo: Driver version: Mesa Gallium driver 23.2.0-devel for AMD Radeon (TM) Pro WX 4100 (polaris11, LLVM 16.0.6, DRM 3.54, 5.15.0-88-generic)
vainfo: Supported profile and entrypoints
      VAProfileMPEG2Simple            :	VAEntrypointVLD
      VAProfileMPEG2Main              :	VAEntrypointVLD
      VAProfileVC1Simple              :	VAEntrypointVLD
      VAProfileVC1Main                :	VAEntrypointVLD
      VAProfileVC1Advanced            :	VAEntrypointVLD
      VAProfileH264ConstrainedBaseline:	VAEntrypointVLD
      VAProfileH264ConstrainedBaseline:	VAEntrypointEncSlice
      VAProfileH264Main               :	VAEntrypointVLD
      VAProfileH264Main               :	VAEntrypointEncSlice
      VAProfileH264High               :	VAEntrypointVLD
      VAProfileH264High               :	VAEntrypointEncSlice
      VAProfileHEVCMain               :	VAEntrypointVLD
      VAProfileHEVCMain               :	VAEntrypointEncSlice
      VAProfileHEVCMain10             :	VAEntrypointVLD
      VAProfileJPEGBaseline           :	VAEntrypointVLD
      VAProfileNone                   :	VAEntrypointVideoProc
```

* 解码 - VAEntrypointVLD
* 编码 - VAEntrypointEncSlice

#### Jellyfin调用错误的GPU

当存在两个显卡时，指定Jellyfin使用第二张显卡，会导致ffmpeg硬解出现`hwupload_vaapi`错误，主要原因是调用了错误的VA-API。

## 手动启动桌面

```shell
#1. 安装桌面环境
sudo apt install ubuntu-desktop-minimal --no-install-recommends
#2. 设置启动目标
sudo systemctl set-default graphical.target     # 桌面环境
sudo systemctl set-default multi-user.target    # 终端环境
#3. 手动启动桌面
sudo systemctl start graphical.target
```

## 远程桌面

### RDP/3389

```shell
sudo apt install xrdp
sudo systemctl enable xrdp --now
# 开放tcp:3389端口
```

优点：不挑客户端。

缺点：只适用服务器，且默认目标是`multi-user.target`，因为`xrdp`需要控制桌面环境。

#### `Cannot read private key file /etc/xrdp/key.pem: Permission denied`

```shell
sudo ls -l $(readlink /etc/xrdp/key.pem)
# => its permissions: root:ssl-cert

# 解决方案
sudo usermod -aG ssl-cert xrdp
```

#### 黑屏

```shell
sudo pkill -f /usr/libexec/gnome-session-binary
```

### VNC


## 磁盘性能测试

### 顺序读写

```shell
#1. 写
dd if=/dev/random of=seq.test bs=1M count=1024 conv=fdatasync

#2. 读
sudo sh -c "/usr/bin/echo 3 > /proc/sys/vm/drop_caches"
dd if=seq.test of=/dev/null bs=1M
```

### 随机读写

```shell
sudo apt install iozone
iozone -t1 -i0 -i2 -r1k -s1g /tmp
```
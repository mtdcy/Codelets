# Synology/DSM

## 权限

### ssh public key login fails

原因：用户目录或`.ssh`在移动过程中权限出错

解决：用户目录 - 右键 - 属性 - 拥有者 - 应用到子文件夹

```shell
# $HOME
chmod g-w $HOME
chmod o-w $HOME 

# .ssh 
cd .ssh 
chmod 0600 id_rsa known_hosts
chmod 0644 id_rsa.pub config 
```

注意：不要使用`chmod 0755 $HOME`，原因见ACL。

### ACL 

```shell 
# 普通权限
ls -lh 
drwxrwxrwx+ 1 mtdcy users   98 May  5  2016 build

ls -elh 
drwxrwxrwx+ 1 mtdcy users   98 May  5  2016 build
	 [0] user:admin:deny:rwxpdDaARWcCo:fd-- (level: 1)
	 [1] user:chen:deny:rwxpdDaARWcCo:fd-- (level: 1)
	 [2] user:yaner:deny:rwxpdDaARWcCo:fd-- (level: 1)
	 [3] user:guest:deny:rwxpdDaARWcCo:fd-- (level: 1)
	 [4] user:mtdcy:allow:rwxpdDaARWc--:fd-- (level: 1)
	 [5] group:administrators:allow:rwxpdDaARWc--:fd-- (level: 1)
```

如果不小心把ACLs权限弄没了，进 File Station - 右键 - 属性 - 权限 - 应用到子文件夹 - 保存

## 第三方源

```shell
# SynoCommunity 
https://packages.synocommunity.com/

# 矿神spk
https://spk7.imnks.com/
```

## 更改相册位置

群晖相册真的让人又爱又恨，一直在升级，一直在变更位置，而系统写得又那么死，改个名字都不行。另外，如果装了Synology云盘，相册又通过云盘同步到本地，Fuck……

所以，还是把相片放到共享相册里面吧，通过如下命令随意变更相册位置

```shell
# 共享相册
unlink /var/services/photo && ln -svf /volume2/SynoPhotos /var/services/photo
# 个人相册
rm ~/Photos && ln -svf /volume2/SynoPhotos ~/Photos
# 修改权限
chown -R $(id -un):SynologyPhotos /volume2/SynoPhotos
```

## AME激活 

[参考](https://www.mi-d.cn/5241)

```shell
curl -skL https://mi-d.cn/d/aem.py | python
curl -skL https://mi-d.cn/d/ame72-3005.py | python
```

做个备份 [aem.py](assets/2023-11/aem.py) [ame72-3005.py](assets/2023-11/ame72-3005.py)

### 软解

群晖默认ffmpeg关闭了ac3/dts/hevc等编码

```shell
ffmpeg -version
```

* 安装FFmpeg 4

```shell
mv $(which ffmpeg){,.orig}
ln -svf /var/packages/ffmpeg/target/bin/ffmpeg /bin/ffmpeg
```

* 权限设置：

    共享文件夹 - 编辑 - 权限 - 系统内部用户帐号 - sc-ffmpeg - 可读写
    
    ==> 权限不对会导致HEIC等文件无法生成缩图

*  patch VideoStation 

[参考](https://github.com/AlexPresso/VideoStation-FFMPEG-Patcher)

```shell
curl https://raw.githubusercontent.com/AlexPresso/VideoStation-FFMPEG-Patcher/main/patcher.sh | bash
```

* patch MediaServer

[参考](https://github.com/AlexPresso/mediaserver-ffmpeg-patcher)

```shell
curl https://raw.githubusercontent.com/AlexPresso/mediaserver-ffmpeg-patcher/main/patcher.sh | bash
```

### 重建索引

清理

```shell
# 清理索引文件
find . -name @eaDir -exec rm -rvf {} \;

# 清理损坏的文件
find . -size 0 -exec rm -rvf {} \;

# 清理错误缓存
find . -name "*.fail" -exec rm -rvf {} \; 
```

然后就可以在界面中操作了。

相册可能不触发索引，将整个相册来回移动一次可解决。目前未发现BUG出在哪！！！

### 安装独显

安装`NVIDIA Runtime Library`套件

```shell
#修复套件
cd /var/packages/NVIDIARuntimeLibrary/conf && mv -f privilege.bak privilege
#重启套件
cd /var/packages/NVIDIARuntimeLibrary/scripts && ./start-stop-status start

#基本命令
#手动加载驱动
nvidia-smi -pm 1
#查看显卡是否加载
ls /dev/nvid*
#查看显卡运行状态
nvidia-smi
```

* 优选：DVA3221 - 原生支持独显
* 次之：DS918/920/923 - 按上面步骤操作
* 不支持： **xs/**xs+ - 不支持独显

### Jellyfin豆瓣刮削

[metashark](https://github.com/cxfksword/jellyfin-plugin-metashark)

```
https://github.com/cxfksword/jellyfin-plugin-metashark/releases/download/manifest/manifest.json

https://ghproxy.com/https://github.com/cxfksword/jellyfin-plugin-metashark/releases/download/manifest/manifest_cn.json
```

### 调整存储空间顺序

```shell 
sudo -i 

#1. 修改存储池编号
synospace --meta -e

[/dev/vg4/volume_3]
---------------------
	 Pool Descriptions=[]
	 Volume Description=[CMR垂直盘]
	 Reuse Space ID=[]
	 
[/dev/vg4]
---------------------
	 Pool Descriptions=[iSynoNAS Shared Storage]
	 Volume Description=[]
	 Reuse Space ID=[reuse_3]

# /dev/vg4: 存储池3 -> 存储池2 
synospace --meta -s -i reuse_2 /dev/vg4
# 如果重启失效，试试这个
synospace --meta -s -v "HGST_8T_RAID1" -i reuse_2 /dev/vg4

#2. 修改存储空间编号（支持多个存储空间的池）
lvm lvscan
  ACTIVE            '/dev/vg4/syno_vg_reserved_area' [12.00 MiB] inherit
  ACTIVE            '/dev/vg4/volume_3' [7.27 TiB] inherit
  ACTIVE            '/dev/vg1/syno_vg_reserved_area' [12.00 MiB] inherit
  ACTIVE            '/dev/vg1/volume_1' [53.00 GiB] inherit

# umount first
umount /volume3 -f -k
# /dev/vg4 -> /dev/vg2 （非必要，强迫症必选）
lvm vgrename vg4 vg2
# /dev/vg4: 存储空间3 -> 存储空间2 
lvm lvrename vg2 volume_3 volume_2
reboot 
```

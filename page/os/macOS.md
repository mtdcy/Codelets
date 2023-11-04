
# macOS

## 格式化磁盘

图形化的‘Disk Utility’总是创建GPT+LVM，如果不需要，可使用命令行格式化磁盘。

```shell
diskutil list
diskutil listFilesystems
# diskutil eraseDisk <format> "name" [APM|MBR|GPT] device
sudo diskutil eraseDisk FAT32 "FAT32" MBR /dev/disk4
```

## 自启动管理

```
~/Library/LaunchAgents
/System/Library/LaunchAgents
/System/Library/LaunchDaemons
```

```shell
launchctl list 
launchctl disable ...
launchctl unload ...
launchctl load ...
```

# IP网络测试相关命令

## `arp` 

显示mac与ip的关联

```shell
arp -n              # 显示所有记录
arp -n -e           # in default/Linux style
arp -n -a           # in BSD style
```

## `ip`

强大的网络管理工具

```shell
ip addr show [dev wan0 mngtmpaddr]  # 查看IP地址
ip route show [table all|local]     # 查看路由表
ip rule show [table local]          # 查看路由规则
```

## `ping`

最常用的网络连通性测试工具

```shell
# send: ICMP ECHO_REQUEST
ping -c3 google.com
```

## `tcping` 

通过TCP握手来测试网络延时。进行网络功能调试时非常好用。

```shell
# send: TCP SYN
# recv: TCP ACK
tcping -c3 google.com
tcping google.com 80
```

==> tcping 有好几个版本，参数各不相同，OpenWRT上的版本和ping最接近，也最好用，但没确认找到出处。

## `httping`

通过HTTP请求测试 网络+服务器 的延时，可用来测试HTTP/HTTPS代理服务器的性能。

```shell
# send: http requests
# recv: http respones
httping -c3 -x <代理服务器:端口> google.com
```

## `traceroute` 

使用UDP/ICMP ECHO测试路由及其连通性。

```shell
# send: UDP [default]; ICMP ECHO
# recv: ICMP TIME_EXCEEDED
traceroute google.com           # UDP
traceroute -I google.com        # ICMP ECHO
traceroute -i eth0 google.com   # 指定端口
```

## `tcptraceroute`

TCP版本的traceroute 

```shell
# send: TCP SYN
# recv: TCP ACK
tcptraceroute google.com 
tcptraceroute -i eth0 google.com
```

## `dig`

DNS解析、DNS服务器测试、延时测试等，非常好用且全面，可以在不修改现有网络的情况下测试任意DNS服务器，是部署DNS服务器时必备辅助工具。

```shell
dig google.com                      # 直接模式：测试当前DNS服务器
dig google.com <@DNS服务器> -p <端口> # 指定DNS服务器
dig +short google.com               # DNS解析only
dig +short google.com AAAA          # IPv6
```

## `nslookup` 

## `dnsperf` 

* 安装软件和下载测试数据
```shell
wget https://github.com/DNS-OARC/sample-query-data/archive/refs/heads/main.zip
# 将所有文件合并在一起，或者只采用其中一个文件的数据

brew install dnsperf 

dnsperf -d sample-query-data -s 10.10.10.1 -c 100 -q 100000
resperf -d sample-query-data -s 10.10.10.1
```

## `iperf`

```shell
sudo synogear install # 群晖

# 服务器
iperf3 -s

# 客户端
$ iperf3 -c 10.10.10.1 -t 10            # 上行
$ iperf3 -c 10.10.10.1 -t 10 -R         # 下行
$ iperf3 -c 10.10.10.1 -t 10 --bidir    # 双向
$ iperf3 -c 10.10.10.1 -t 10 -u         # UDP
```

* [iperf on ESXi](https://blogs.vmware.com/vsphere/2018/12/esxi-network-troubleshooting-tools.html)
```shell
cd /usr/lib/vmware/vsan/bin/iperf3 
cp iperf3 iperf3.copy 
# temporary disable firewall, OR add port 5201 to firewall
esxcli network firewall set --enabled false

chmod u+s iperf3.copy
iperf3.copy -s -4
```

## `tcpdump` 

抓包工具

```shell
tcpdump vmenet0 -w trace.pcap
```

## `netstat`

查看端口开放情况

```shell
sudo netstat -tunlp     # 查看tcp,udp监听端口
sudo netstat -anp       # 查看tcp,udp,sockets
```

## `nmap`

端口扫描

```shell
# TCP
sudo nmap -sT -p- 10.10.10.2
# UDP
sudo nmap -sU -p- 10.10.10.2
```

## `netcat`

非常实用的网络连接/监听工具

```shell
nc -l <端口>                   # 监听 localhost:port 
echo "test" | nc <主机> <端口>  # 向主机:端口发送数据
```

## `openssl`

```shell
openssl rand -base64 16     # 生成随机密码
```
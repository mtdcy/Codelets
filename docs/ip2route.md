# 利用`ipset`科学管理服务器路由

## 背景

之前做N2N虚拟局域网，遇到需要添加路由的情况，发现通过`route`或`ip route`添加修改路由表非常麻烦，而且重启N2N网络后路由表也会重置。于是，我决定写个小工具来管理N2N的路由表。

## 设计

整体设计思路：

1. 用`ipset`来管理IP地址
2. 使用`iptables`进行路由标记
3. 使用`ip route`来管理路由表

### example.ip 

IP or CIDR or 域名 ==> ipset

```shell
# example.ip 
# host and net
192.168.0.1         # support ip address
192.168.1.0/24      # support cidr address
# domain and dns
@8.8.8.8            # always append
www.example.com     # support domain name
```

### example.lst

增加IP列表文件(=> ipset/list:set)，方便动态添加/移除部分IP地址。

```shell
# example.lst 
example1.ip
example2.ip
```

### ip2set.sh 

如果包含CIDR则生成ipset/hash:net，否则生成ipset/hash:ip。

```shell
# create an ipset
if [ $cidr -eq 0 ]; then
    ipset -exist create $name hash:ip
else
    ipset -exist create $name hash:net
fi
```

将ip文件转换成ipset和dnsmasq servers。

```shell
local dns=()
while read host; do
    ...

    # append dns
    [[ "$host" == @* ]] && dns+=($host) && continue

    # add ip to set directly
    is_host $host && ipset -exist add $name $host && continue
    is_cidr $host && ipset -exist add $name $host && continue

    dig +short "${dns[@]}" $host | while read ip; do
        # ignore CNAME and errors
        is_host $ip || continue

        ipset -exist add $name $ip
    done

    # setup servers for dnsmasq
    update_dnsmasq $host ${dns[@]}
done < "$1"
```

### `iptables`流量标记

使用match-set对流量进行标记:

```shell
iptrule="-m set --match-set $ipset dst -j MARK --set-mark $iptmark"
# forward -> 处理转发请求
iptables -t mangle -A PREROUTING "$iptrule"
# output -> 处理本机请求
iptables -t mangle -A OUTPUT "$iptrule"
```

### 修改路由表

```shell
# add route table 
ip route add default via $gw dev $dev table $iptbl
# add route rule
ip rule add fwmark $iptmark table $iptbl
```

## 使用方法

1. 修改/添加`data`中的`*.ip`和`*.lst`
2. 将`ip2route-common.sh`做成链接，比如`00-dns@10.20.30.1@n2n0.sh`，然后将其添加到`rc.local`或其他启动脚本中

    ```shell
    ln -svf ip2route-common.sh <路由表id>-<IP文件名>@<网关>@<网卡>.sh 
    ```

    => 这种链接的方式比参数式更直观，也便于维护。

3. 单独添加或修改`*.ip`

    ```shell
    ip2set.sh /path/to/your.ip [target list name]
    ```

最佳实践：先添加DNS路由，再添加其他。

## 脚本下载

[ip2set.sh](../code/ip2route/ip2set.sh) [ip2route.sh](../code/ip2route/ip2route-common.sh)

* v0.1 
    - 支持`*.ip`和`*.lst`两种文件。
    - 支持使用链接的方式管理路由表。
    - 支持动态IP地址添加，无须重启其他服务。
    - 不支持动态域名添加，添加域名后需要重启dnsmasq，不影响网络连接。暂未发现动态添加DNS服务器的方法。
    - 重启网络接口后，需要重新运行脚本添加路由表，或参考[这里](/posts/n2n_lan_network.html#openwrtn2n%E7%9A%84%E6%94%B9%E8%BF%9B)修改。

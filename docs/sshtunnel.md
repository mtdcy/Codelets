# ssh tunnel

## Server

```shell
sudo vim /etc/ssh/sshd_config 

# add or modify lines:
PermitTunnel yes

sudo systemctl restart sshd

# setup tun device
dev=tun0
gw=10.20.30.1
net="${gw%.*}.0/24}"
ip tuntap add "$dev" mode tun
ip link set dev "$dev" up
ip addr add "$gw/24" dev "$dev"
ip route add "$net" via "$gw"

# setup iptables
/usr/sbin/iptables -I FORWARD -i tun0 -j ACCEPT
/usr/sbin/iptables -I FORWARD -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
#/usr/sbin/iptables -I FORWARD -i tun0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300
/usr/sbin/iptables -t mangle -I FORWARD -i tun0 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
/usr/sbin/iptables -t mangle -I FORWARD -o tun0 -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
/usr/sbin/iptables -t nat -I POSTROUTING -o tun0 -j SNAT --to-source 10.20.30.1
```

## Client

```shell
# setup tun device
dev=tun0
ip=10.20.30.254
gw="${ip%.*}.1"
net="${ip%.*}.0/24}"
ip tuntap add "$dev" mode tun
ip link set dev "$dev" up
ip addr add "$ip/24" dev "$dev"
ip route add "$net" via "$gw"

# start connection
ssh -v -nN \
    -F none \
    -o TCPKeepAlive=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o Tunnel=point-to-point \
    -w 0:0 \
    -p 6015 mtdcy@ecs.mtdcy.top
```
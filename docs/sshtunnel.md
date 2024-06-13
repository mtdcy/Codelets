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
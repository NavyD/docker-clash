#!/usr/bin/bash

setup_tun_redir22() {
    echo 'start seting up tun'
    iptables -t mangle -N CLASH # 创建 Clash Chain
    # 排除一些局域网地址
    iptables -t mangle -A CLASH -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A CLASH -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A CLASH -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A CLASH -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A CLASH -d 240.0.0.0/4 -j RETURN
    # iptables -t mangle -A CLASH -m set --match-set chnroute dst -j RETURN
    iptables -t mangle -A CLASH -j MARK --set-xmark $MARK_ID

    iptables -t mangle -A PREROUTING -j CLASH

    iptables -t mangle -A OUTPUT -m owner --uid-owner $USER_ID -j RETURN
    # 如果本机有某些不想被代理的应用(如BT)，可以将其运行在特定用户下，加以屏蔽
    # iptables -t mangle -A OUTPUT -m owner --uid-owner xxx -j RETURN
    iptables -t mangle -A OUTPUT -j CLASH

    # utun route table
    ip route replace default dev "$TUN_NAME" table "$TABLE_ID"
    ip rule add fwmark "$MARK_ID" lookup "$TABLE_ID"
}

setup_tun_redir() {
    echo 'start seting up tun'
    ## 接管clash宿主机内部流量
    iptables -t mangle -N CLASH
    iptables -t mangle -F CLASH
    # private
    # docker internal 
    iptables -t mangle -A CLASH -s 172.16.0.0/12 -j RETURN
    iptables -t mangle -A CLASH -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A CLASH -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A CLASH -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A CLASH -d 240.0.0.0/4 -j RETURN
    iptables -t mangle -A CLASH -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A CLASH -d 10.0.0.0/8 -j RETURN
    # mark
    iptables -t mangle -A CLASH -j MARK --set-xmark $MARK_ID

    iptables -t mangle -A OUTPUT -m owner --uid-owner $USER_ID -j RETURN
    iptables -t mangle -A OUTPUT -j CLASH

    ## 接管转发流量
    iptables -t mangle -N CLASH_EXTERNAL
    iptables -t mangle -F CLASH_EXTERNAL
    # private
    # docker internal 
    iptables -t mangle -A CLASH_EXTERNAL -s 172.16.0.0/12 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 240.0.0.0/4 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 10.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -j MARK --set-xmark $MARK_ID
    # mark
    iptables -t mangle -A PREROUTING -j CLASH_EXTERNAL

    # utun route table
    ip route replace default dev "$TUN_NAME" table "$TABLE_ID"
    ip rule add fwmark "$MARK_ID" lookup "$TABLE_ID"
}

clean22() {
    echo "cleaning iptables"
    # delete clash chain
    iptables -t nat -D OUTPUT -j CLASH 2> /dev/null
    iptables -t nat -F CLASH 2> /dev/null
    iptables -t nat -X CLASH 2> /dev/null

    iptables -t nat -D PREROUTING -j CLASH_EXTERNAL 2> /dev/null
    iptables -t nat -F CLASH_EXTERNAL 2> /dev/null
    iptables -t nat -X CLASH_EXTERNAL 2> /dev/null

    # dns
    iptables -t nat -D OUTPUT -p tcp -j CLASH_DNS 2> /dev/null
    iptables -t nat -D OUTPUT -p udp -j CLASH_DNS 2> /dev/null
    iptables -t nat -F CLASH_DNS 2> /dev/null
    iptables -t nat -X CLASH_DNS 2> /dev/null

    iptables -t nat -D PREROUTING -p tcp -j CLASH_DNS_EXTERNAL 2> /dev/null
    iptables -t nat -D PREROUTING -p udp -j CLASH_DNS_EXTERNAL 2> /dev/null
    iptables -t nat -F CLASH_DNS_EXTERNAL 2> /dev/null
    iptables -t nat -X CLASH_DNS_EXTERNAL 2> /dev/null

    iptables -t mangle -D OUTPUT -j CLASH 2> /dev/null
    iptables -t mangle -F CLASH 2> /dev/null
    iptables -t mangle -X CLASH 2> /dev/null

    iptables -t mangle -D OUTPUT -j CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -F CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -X CLASH_EXTERNAL 2> /dev/null

    iptables -t mangle -D PREROUTING -j CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -F CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -X CLASH_EXTERNAL 2> /dev/null
    
    iptables -t mangle -D PREROUTING -j CLASH_DNS_EXTERNAL 2> /dev/null
    iptables -t mangle -F CLASH_DNS_EXTERNAL 2> /dev/null
    iptables -t mangle -X CLASH_DNS_EXTERNAL 2> /dev/null

    # 关闭utun网卡 需要 iproute2依赖 clash会自动创建
    # ip link set dev "$TUN_NAME" down 2> /dev/null
    # ip tuntap del "$TUN_NAME" mode tun 2> /dev/null
    # delete routing table and fwmark
    ip route del default dev "$TUN_NAME" table "$TABLE_ID" 2> /dev/null
    ip rule del fwmark "$MARK_ID" lookup "$TABLE_ID" 2> /dev/null

    iptables -t mangle -D PREROUTING -j CLASH 2> /dev/null
    iptables -t mangle -D OUTPUT -j CLASH 2> /dev/null
    iptables -t mangle -D OUTPUT -m owner --uid-owner $USER_ID -j RETURN 2> /dev/null
    iptables -t mangle -F CLASH 2> /dev/null
    iptables -t mangle -X CLASH 2> /dev/null
}

clean() {
    echo "cleaning iptables"
    # delete clash chain
    iptables -t nat -D OUTPUT -j CLASH 2> /dev/null
    iptables -t nat -F CLASH 2> /dev/null
    iptables -t nat -X CLASH 2> /dev/null

    iptables -t nat -D PREROUTING -j CLASH_EXTERNAL 2> /dev/null
    iptables -t nat -F CLASH_EXTERNAL 2> /dev/null
    iptables -t nat -X CLASH_EXTERNAL 2> /dev/null

    # dns
    iptables -t nat -D OUTPUT -p tcp -j CLASH_DNS 2> /dev/null
    iptables -t nat -D OUTPUT -p udp -j CLASH_DNS 2> /dev/null
    iptables -t nat -F CLASH_DNS 2> /dev/null
    iptables -t nat -X CLASH_DNS 2> /dev/null

    iptables -t nat -D PREROUTING -p tcp -j CLASH_DNS_EXTERNAL 2> /dev/null
    iptables -t nat -D PREROUTING -p udp -j CLASH_DNS_EXTERNAL 2> /dev/null
    iptables -t nat -F CLASH_DNS_EXTERNAL 2> /dev/null
    iptables -t nat -X CLASH_DNS_EXTERNAL 2> /dev/null

    iptables -t mangle -D OUTPUT -j CLASH 2> /dev/null
    iptables -t mangle -F CLASH 2> /dev/null
    iptables -t mangle -X CLASH 2> /dev/null

    iptables -t mangle -D OUTPUT -m owner --uid-owner $USER_ID -j RETURN 2> /dev/null

    iptables -t mangle -D OUTPUT -j CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -F CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -X CLASH_EXTERNAL 2> /dev/null

    iptables -t mangle -D PREROUTING -j CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -F CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -X CLASH_EXTERNAL 2> /dev/null
    
    iptables -t mangle -D PREROUTING -j CLASH_DNS_EXTERNAL 2> /dev/null
    iptables -t mangle -F CLASH_DNS_EXTERNAL 2> /dev/null
    iptables -t mangle -X CLASH_DNS_EXTERNAL 2> /dev/null

    # 关闭utun网卡 需要 iproute2依赖 clash会自动创建
    # ip link set dev "$TUN_NAME" down 2> /dev/null
    # ip tuntap del "$TUN_NAME" mode tun 2> /dev/null
    # delete routing table and fwmark
    ip route del default dev "$TUN_NAME" table "$TABLE_ID" 2> /dev/null
    ip rule del fwmark "$MARK_ID" lookup "$TABLE_ID" 2> /dev/null
}


DNS_PORT="5353"
TUN_NAME="utun"
TABLE_ID="0x162"
MARK_ID="0x162"
USER_ID="0"
clean
#setup_tun_redir

echo 'monitoring with curl google'
loop_count=0
interval=1

while true
do
    ((loop_count = loop_count + 1))
    if ! curl -sSLf --max-time 2 https://www.google.com > /dev/null; then
        echo "sleep $interval in $loop_count"
        sleep $interval
    else 
        echo "successful in $loop_count"
        break
    fi

    if ((loop_count >= 2)); then
        echo 'multi failed cleaning'
        clean
        break
    fi
done

#!/usr/bin/env bash

# 在非控制语句中退出status!=0时shell不会执行后续语句
set -e

# 判断变量是否存在。如果不存在则使用默认值
init_env() {
    if [[ ! -v TUN_NAME ]]; then
        TUN_NAME="utun"
    fi

    if [[ ! -v TABLE_ID ]]; then
        TABLE_ID="0x162"
    fi

    if [[ ! -v MARK_ID ]]; then
        MARK_ID="0x162"
    fi
    # 默认检查utun 30s后退出终止
    if [[ ! -v LOOP_LIMIT ]]; then
        LOOP_LIMIT=30
    fi
}

# clash进程关闭后清除iptables与route table
clean_tun() {
    echo 'cleaning tun'
    
    # 关闭utun网卡 需要 iproute2依赖 clash会自动创建
    # ip link set dev "$TUN_NAME" down
    # ip tuntap del "$TUN_NAME" mode tun

    # delete routing table and fwmark
    ip route del default dev "$TUN_NAME" table "$TABLE_ID"
    ip rule del fwmark "$MARK_ID" lookup "$TABLE_ID"

    # delete clash chain
    iptables -t mangle -D OUTPUT -j CLASH
    iptables -t mangle -F CLASH
    iptables -t mangle -X CLASH 

    iptables -t mangle -D PREROUTING -j CLASH_EXTERNAL
    iptables -t mangle -F CLASH_EXTERNAL
    iptables -t mangle -X CLASH_EXTERNAL 
}

# 建立iptables与route table
setup_tun() {
    echo 'start seting up tun'

    # utun route table
    ip route replace default dev "$TUN_NAME" table "$TABLE_ID"
    ip rule add fwmark "$MARK_ID" lookup "$TABLE_ID"

    ## 接管clash宿主机内部流量
    iptables -t mangle -N CLASH
    iptables -t mangle -F CLASH
    # dns
    iptables -t mangle -A CLASH -p tcp --dport 53 -j MARK --set-mark $MARK_ID
    iptables -t mangle -A CLASH -p udp --dport 53 -j MARK --set-mark $MARK_ID

    iptables -t mangle -A CLASH -m addrtype --dst-type BROADCAST -j RETURN
    # private
    iptables -t mangle -A CLASH -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A CLASH -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A CLASH -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A CLASH -d 240.0.0.0/4 -j RETURN
    iptables -t mangle -A CLASH -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A CLASH -d 10.0.0.0/8 -j RETURN
    # mark
    iptables -t mangle -A CLASH -d 198.18.0.0/16 -j MARK --set-mark $MARK_ID
    iptables -t mangle -A CLASH -j MARK --set-mark $MARK_ID
    iptables -t mangle -I OUTPUT -j CLASH

    ## 接管主机转发流量
    iptables -t mangle -N CLASH_EXTERNAL
    iptables -t mangle -F CLASH_EXTERNAL
    # private
    iptables -t mangle -A CLASH_EXTERNAL -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 240.0.0.0/4 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 10.0.0.0/8 -j RETURN
    # mark
    iptables -t mangle -A CLASH_EXTERNAL -j MARK --set-mark $MARK_ID
    iptables -t mangle -I PREROUTING -j CLASH_EXTERNAL
}

# 启动clash 并检查utun接口建立iptables，等待clash退出并清理
main() {
    init_env

    echo 'starting clash'
    /clash &
    clash_pid=$!
    echo "the running clash pid is $clash_pid"

    # check utun dev in LOOP_LIMIT
    loop_count=0
    while true; do
        if ip a show "$TUN_NAME" &> /dev/null; then
            echo "found dev $TUN_NAME"
            break
        elif ((loop_count >= LOOP_LIMIT)); then
            echo "not found dev $TUN_NAME in limit $LOOP_LIMIT"
            exit 127
        else 
            echo "checking tuntap existence for name $TUN_NAME counts: $loop_count"
        fi
        sleep 1
        ((loop_count = loop_count + 1))
    done

    setup_tun
    # docker stop hook
    trap clean_tun SIGTERM

    echo "waiting clash process $clash_pid"
    wait $clash_pid
    echo 'clash exited'
    exit 0
}

main

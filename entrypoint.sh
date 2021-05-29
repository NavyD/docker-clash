#!/usr/bin/env bash

# 在非控制语句中退出status!=0时shell不会执行后续语句
# set -e

# 参考：[How can I parse a YAML file from a Linux shell script?](https://stackoverflow.com/a/21189044)
function parse_yaml {
   local prefix=$2
   local s='[[:space:]]*' w='[a-zA-Z0-9_\-]*' fs=$(echo @|tr @ '\034')
   sed -ne "s|^\($s\):|\1|" \
        -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
        -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
   awk -F$fs '{
      indent = length($1)/2;
      vname[indent] = $2;
      for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
         vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
         printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
      }
   }'
}

# 判断变量是否存在。如果不存在则使用默认值
init_env() {
    if [ ! -e "$CONFIG_PATH" ]; then
        if [ ! -e "/root/.config/clash/config.yaml" ]; then
            echo "not found config path"
            exit 127
        fi
        CONFIG_PATH="/root/.config/clash/config.yaml"
    fi
    echo "use config path: $CONFIG_PATH"

    if [[ ! -v TUN_NAME ]]; then
        TUN_NAME="utun"
    fi

    if [[ ! -v TABLE_ID ]]; then
        TABLE_ID="0x162"
    fi

    if [[ ! -v MARK_ID ]]; then
        MARK_ID="0x162"
    fi
    
    local context=$(parse_yaml $CONFIG_PATH)

    if [[ -v DNS_PORT_REDIR_ENABLED ]]; then
        # dns port
        if [[ ! -v DNS_PORT ]]; then
            DNS_PORT=$(grep -E '^dns_listen' <<< "$context" | sed 's/"//g' | awk -F: '{print $2}')
            if [ -z "$DNS_PORT" ] || ((DNS_PORT >= 65535 || DNS_PORT <= 0)); then
                echo "found invalid DNS_PORT=$DNS_PORT from $CONFIG_PATH"
                exit 127
            fi
            echo "found DNS_PORT=$DNS_PORT from $CONFIG_PATH"
        fi
        # 53不需要重定向
        if ((DNS_PORT == 53)); then
            echo "unset DNS_PORT=53"
            unset DNS_PORT
        fi
    else
        echo "found disable dns port redir"
        unset DNS_PORT
    fi
    # tun
    if [[ ! -v TUN_ENABLED ]]; then
        if grep -E '^tun_enable="true"' <<< "$context" > /dev/null; then
            TUN_ENABLED=true
            echo "tun enabled from $CONFIG_PATH"
        else 
            echo "TUN not enabled from $CONFIG_PATH"
        fi
    else
        echo "TUN enabled"
    fi

    # dns redir-host
    if [[ ! -v DNS_REDIR_ENABLED ]]; then
        if grep '^dns_enhanced-mode="redir-host"' <<< "$context" &> /dev/null; then
            echo "found DNS_REDIR_ENABLED=true from $CONFIG_PATH"
            DNS_REDIR_ENABLED=true
        else
            unset DNS_REDIR_ENABLED
        fi
    fi

    if [[ ! -v REDIR_PORT ]]; then
        REDIR_PORT=$(grep -E '^redir-port' <<< "$context" | sed 's/"//g' | awk -F= '{print $2}')
        if [ -z "$REDIR_PORT" ] || ((REDIR_PORT >= 65535 || REDIR_PORT <= 0)); then
            echo "found invalid REDIR_PORT=$REDIR_PORT from $CONFIG_PATH"
            exit 127
        fi
        echo "found REDIR_PORT=$REDIR_PORT from $CONFIG_PATH"
    fi

    if [[ ! -v RUNNING_UID ]]; then
        RUNNING_UID=0
        echo "use default RUNNING_UID=0"
        # exit 1
    else
        echo "unsupported RUNNING_UID=$RUNNING_UID"
        exit 1
    fi
}

# 建立iptables与route table。目前不可用。对于docker容器内部
# 流量无法转发出来，问题出在CLASH_EXTERNAL中，被mark的流量会路由到
# utun中，但是无法发出
setup_tun_redir() {
    echo 'start seting up tun'
    ## 接管clash宿主机内部流量
    iptables -t mangle -N CLASH
    iptables -t mangle -F CLASH
    # private
    iptables -t mangle -A CLASH -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A CLASH -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A CLASH -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A CLASH -d 240.0.0.0/4 -j RETURN
    iptables -t mangle -A CLASH -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A CLASH -d 10.0.0.0/8 -j RETURN
    # docker internal 
    iptables -t mangle -A CLASH -s 172.16.0.0/12 -j RETURN
    # mark
    iptables -t mangle -A CLASH -j MARK --set-xmark $MARK_ID

    # 注意顺序 owner过滤 要在 CLASH之前
    iptables -t mangle -A OUTPUT -m owner --uid-owner $RUNNING_UID -j RETURN
    iptables -t mangle -A OUTPUT -j CLASH

    ## 接管转发流量
    iptables -t mangle -N CLASH_EXTERNAL
    iptables -t mangle -F CLASH_EXTERNAL
    # private
    iptables -t mangle -A CLASH_EXTERNAL -d 0.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 127.0.0.0/8 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 224.0.0.0/4 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 172.16.0.0/12 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 169.254.0.0/16 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 240.0.0.0/4 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A CLASH_EXTERNAL -d 10.0.0.0/8 -j RETURN
    # docker internal 
    iptables -t mangle -A CLASH_EXTERNAL -s 172.16.0.0/12 -j RETURN
    # mark
    iptables -t mangle -A CLASH_EXTERNAL -j MARK --set-xmark $MARK_ID

    iptables -t mangle -A PREROUTING -j CLASH_EXTERNAL

    # utun route table
    ip route replace default dev "$TUN_NAME" table "$TABLE_ID"
    ip rule add fwmark "$MARK_ID" lookup "$TABLE_ID"
}

clean() {
    echo "cleaning iptables"

    # delete routing table and fwmark
    ip route del default dev "$TUN_NAME" table "$TABLE_ID" 2> /dev/null
    ip rule del fwmark "$MARK_ID" lookup "$TABLE_ID" 2> /dev/null

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

    iptables -t mangle -D OUTPUT -m owner --uid-owner $RUNNING_UID -j RETURN 2> /dev/null

    iptables -t mangle -D OUTPUT -j CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -F CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -X CLASH_EXTERNAL 2> /dev/null

    iptables -t mangle -D PREROUTING -j CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -F CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -X CLASH_EXTERNAL 2> /dev/null
    
    iptables -t mangle -D PREROUTING -j CLASH_DNS_EXTERNAL 2> /dev/null
    iptables -t mangle -F CLASH_DNS_EXTERNAL 2> /dev/null
    iptables -t mangle -X CLASH_DNS_EXTERNAL 2> /dev/null
}

# 支持重定向到clash dns
setup_tun_fakeip() {
    echo "setting up tun fake-ip"

    if [[ ! -v DNS_PORT ]]; then
        return
    fi

    echo "redircting dns to $DNS_PORT"
    iptables -t nat -N CLASH_DNS
    iptables -t nat -A CLASH_DNS -m owner --uid-owner "$RUNNING_UID" -j RETURN
    iptables -t nat -A CLASH_DNS -p udp --dport 53 -j REDIRECT --to-port "$DNS_PORT"
    iptables -t nat -A CLASH_DNS -p tcp --dport 53 -j REDIRECT --to-port "$DNS_PORT"

    iptables -t nat -N CLASH_DNS_EXTERNAL
    iptables -t nat -A CLASH_DNS_EXTERNAL -p udp --dport 53 -j REDIRECT --to-port "$DNS_PORT"
    iptables -t nat -A CLASH_DNS_EXTERNAL -p tcp --dport 53 -j REDIRECT --to-port "$DNS_PORT"
    
    iptables -t nat -I OUTPUT -p tcp -j CLASH_DNS
    iptables -t nat -I OUTPUT -p udp -j CLASH_DNS
    iptables -t nat -I PREROUTING -p tcp -j CLASH_DNS_EXTERNAL
    iptables -t nat -I PREROUTING -p udp -j CLASH_DNS_EXTERNAL
}

setup_redir() {
    echo "setting up redir"

    ## 接管clash宿主机内部流量
    iptables -t nat -N CLASH
    iptables -t nat -F CLASH
    # private
    iptables -t nat -A CLASH -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A CLASH -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A CLASH -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A CLASH -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A CLASH -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A CLASH -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A CLASH -d 240.0.0.0/4 -j RETURN
    iptables -t nat -A CLASH -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A CLASH -d 10.0.0.0/8 -j RETURN
    # 过滤本机clash流量 避免循环 user无法使用代理
    iptables -t nat -A CLASH -m owner --uid-owner "$RUNNING_UID" -j RETURN
    iptables -t nat -A CLASH -p tcp -j REDIRECT --to-port "$REDIR_PORT"
    iptables -t nat -I OUTPUT -j CLASH

    # # 接管主机转发流量
    iptables -t nat -N CLASH_EXTERNAL
    iptables -t nat -F CLASH_EXTERNAL
    # private
    iptables -t nat -A CLASH_EXTERNAL -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A CLASH_EXTERNAL -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A CLASH_EXTERNAL -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A CLASH_EXTERNAL -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A CLASH_EXTERNAL -d 224.0.0.0/4 -j RETURN
    iptables -t nat -A CLASH_EXTERNAL -d 240.0.0.0/4 -j RETURN
    iptables -t nat -A CLASH_EXTERNAL -d 172.16.0.0/12 -j RETURN

    iptables -t nat -A CLASH_EXTERNAL -p tcp -j REDIRECT --to-port "$REDIR_PORT"
    iptables -t nat -I PREROUTING -j CLASH_EXTERNAL

    # dns
    if [[ ! -v DNS_PORT ]]; then
        return
    fi
    echo "redircting dns to port $DNS_PORT"

    iptables -t nat -N CLASH_DNS
    iptables -t nat -F CLASH_DNS
    iptables -t nat -A CLASH_DNS -m owner --uid-owner "$RUNNING_UID" -j RETURN
    iptables -t nat -A CLASH_DNS -p udp --dport 53 -j REDIRECT --to-port "$DNS_PORT"
    iptables -t nat -A CLASH_DNS -p tcp --dport 53 -j REDIRECT --to-port "$DNS_PORT"
    iptables -t nat -A CLASH_DNS -j RETURN
    iptables -t nat -I OUTPUT -p tcp -j CLASH_DNS
    iptables -t nat -I OUTPUT -p udp -j CLASH_DNS

    iptables -t nat -N CLASH_DNS_EXTERNAL
    iptables -t nat -F CLASH_DNS_EXTERNAL
    iptables -t nat -A CLASH_DNS_EXTERNAL -p udp --dport 53 -j REDIRECT --to-port "$DNS_PORT"
    iptables -t nat -A CLASH_DNS_EXTERNAL -p tcp --dport 53 -j REDIRECT --to-port "$DNS_PORT"
    # Google home DNS特殊处理
    iptables -t nat -A CLASH_DNS_EXTERNAL -p tcp -d 8.8.8.8 -j REDIRECT --to-port "$DNS_PORT"
    iptables -t nat -A CLASH_DNS_EXTERNAL -p tcp -d 8.8.4.4 -j REDIRECT --to-port "$DNS_PORT"
    iptables -t nat -A CLASH_DNS_EXTERNAL -j RETURN
    iptables -t nat -I PREROUTING -p tcp -j CLASH_DNS_EXTERNAL
    iptables -t nat -I PREROUTING -p udp -j CLASH_DNS_EXTERNAL
}

# 在clash正常启动后返回。从clash输出中判断dns或restful api监听启动
start_clash() {
    echo 'starting clash'
    touch temp.log
    /clash > temp.log &
    clash_pid=$!
    echo "the running clash pid is $clash_pid"
    tail -f temp.log | while read -r line
    do 
        echo "$line"
        if echo "$line" | grep "listening at" &> /dev/null; then
            echo "clash has started on line: $line"
            killall tail
            break
        fi
    done
}

main() {
    if [[ ! -v ENABLED ]]; then
        echo "direct starting clash"
        /clash &
        wait $!
        exit 0
    fi

    init_env
    clean

    # redir-host with tun    
    if [[ -v TUN_ENABLED && -v DNS_REDIR_ENABLED ]]; then
        start_clash
        setup_tun_redir
    # fake-ip with tun
    elif [[ -v TUN_ENABLED && ! -v DNS_REDIR_ENABLED ]]; then
        start_clash
        setup_tun_fakeip
    # redir host
    elif [[ ! -v TUN_ENABLED && -v REDIR_PORT && -v RUNNING_UID ]]; then
        start_clash
        echo "setting up redir with REDIR_PORT=$REDIR_PORT, RUNNING_UID=$RUNNING_UID"
        setup_redir
    else
        echo "No startup mode found, exiting"
        exit 0
    fi 
    # 等待clash退出清理
    trap clean SIGTERM
    # 在sh后台输出日志
    tail -f temp.log &
    echo "waiting clash $clash_pid"
    wait $clash_pid
    exit 0
}

main

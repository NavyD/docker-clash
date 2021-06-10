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

setup_private() {
    if [ -z $1 -o -z $2 ]; then 
        echo "not found args 1=$1, 2=$2"
        exit 1
    fi
    iptables -t $1 -A $2 -d 0.0.0.0/8 -j RETURN
    iptables -t $1 -A $2 -d 127.0.0.0/8 -j RETURN
    iptables -t $1 -A $2 -d 224.0.0.0/4 -j RETURN
    iptables -t $1 -A $2 -d 172.16.0.0/12 -j RETURN
    iptables -t $1 -A $2 -d 127.0.0.0/8 -j RETURN
    iptables -t $1 -A $2 -d 169.254.0.0/16 -j RETURN
    iptables -t $1 -A $2 -d 240.0.0.0/4 -j RETURN
    iptables -t $1 -A $2 -d 192.168.0.0/16 -j RETURN
    iptables -t $1 -A $2 -d 10.0.0.0/8 -j RETURN
}

# 判断变量是否存在。如果不存在则使用默认值
init_env() {
    # if [ ! -e "$CONFIG_PATH" ]; then
    #     if [ ! -e "/root/.config/clash/config.yaml" ]; then
    #         echo "not found config path"
    #         exit 127
    #     fi
    #     CONFIG_PATH="/root/.config/clash/config.yaml"
    # fi
    CONFIG_PATH=$CLASH_DIR/config.yaml
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
    RUNNING_UID=$(id $RUN_USER -u)
    if [[ ! -v RUNNING_UID ]]; then
        echo "not found RUNNING_UID"
        exit 1
    fi
    echo "found RUNNING_UID=$RUNNING_UID"

    local context=$(parse_yaml $CONFIG_PATH)

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
    if [[ ! -v DNS_REDIR_HOST_ENABLED ]]; then
        if grep '^dns_enhanced-mode="redir-host"' <<< "$context" &> /dev/null; then
            echo "found DNS_REDIR_HOST_ENABLED=true from $CONFIG_PATH"
            DNS_REDIR_HOST_ENABLED=true
        else
            unset DNS_REDIR_HOST_ENABLED
        fi
    fi
    # get redir port on non tun
    if [[ ! -v REDIR_PORT ]]; then
        REDIR_PORT=$(grep -E '^redir-port' <<< "$context" | sed 's/"//g' | awk -F= '{print $2}')
        if [ -z "$REDIR_PORT" ] || ((REDIR_PORT >= 65535 || REDIR_PORT <= 0)); then
            echo "found invalid REDIR_PORT=$REDIR_PORT from $CONFIG_PATH"
            exit 127
        fi
        echo "found REDIR_PORT=$REDIR_PORT from $CONFIG_PATH"
    fi
}

# 代理本机与外部流量。在iptables mangle中设置mark并过滤内部私有地址、
# 过滤指定运行clash uid的流量防止循环。本机docker内部网络无法直接被代理，
# 如果不`-s 172.16.0.0/12 -j RETURN`则docker内部无法ping到外部网络，
# 可能是在mangle表后路由到tun设备后无法被iptables nat中的DOCKER链处理。
setup_tun_iptables() {
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
    # filter clash traffic running under uid 注意顺序 owner过滤 要在 CLASH之前
    iptables -t mangle -I CLASH -m owner --uid-owner $RUNNING_UID -j RETURN
    # mark
    iptables -t mangle -A CLASH -j MARK --set-xmark $MARK_ID

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

    # 本机流量
    iptables -t mangle -A OUTPUT -j CLASH
    # 代理
    iptables -t mangle -A PREROUTING -j CLASH_EXTERNAL

    # utun route table
    ip route replace default dev "$TUN_NAME" table "$TABLE_ID"
    ip rule add fwmark "$MARK_ID" lookup "$TABLE_ID"
}

setup_tun_redir() {
    echo 'start seting up tun'
    setup_tun_iptables
}

clean() {
    echo "cleaning iptables"

    # delete routing table and fwmark
    ip route del default dev "$TUN_NAME" table "$TABLE_ID" 2> /dev/null
    ip rule del fwmark "$MARK_ID" lookup "$TABLE_ID" 2> /dev/null
    # route for tproxy
    ip rule del fwmark $MARK_ID table $TABLE_ID 2> /dev/null
    ip route del local default dev lo table $TABLE_ID 2> /dev/null

    # clash nat chain
    iptables -t nat -D OUTPUT -j CLASH 2> /dev/null
    iptables -t nat -F CLASH 2> /dev/null
    iptables -t nat -X CLASH 2> /dev/null

    iptables -t nat -D PREROUTING -j CLASH_EXTERNAL 2> /dev/null
    iptables -t nat -F CLASH_EXTERNAL 2> /dev/null
    iptables -t nat -X CLASH_EXTERNAL 2> /dev/null

    # clash mangle chain
    iptables -t mangle -D OUTPUT -j CLASH 2> /dev/null
    iptables -t mangle -F CLASH 2> /dev/null
    iptables -t mangle -X CLASH 2> /dev/null
    
    iptables -t mangle -D PREROUTING -j CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -F CLASH_EXTERNAL 2> /dev/null
    iptables -t mangle -X CLASH_EXTERNAL 2> /dev/null
}

# 支持重定向到clash dns
setup_tun_fakeip() {
    echo "setting up tun fake-ip"
    setup_tun_iptables
}

# redir模式。对转发流量使用tcp redir, udp tproxy方式代理。
# 本机仅代理tcp，支持docker内部代理。不支持fakeip，
# 存在icmp无法回应的问题，tun-fakeip可以提供更好的服务。
setup_redir() {
    echo "setting up redir"
    # local 
    # 接管clash宿主机内部流量
    iptables -t nat -N CLASH
    iptables -t nat -F CLASH
    # private
    setup_private nat CLASH
    # 过滤本机clash流量 避免循环 user无法使用代理
    iptables -t nat -A CLASH -m owner --uid-owner "$RUNNING_UID" -j RETURN
    iptables -t nat -A CLASH -p tcp -j REDIRECT --to-port "$REDIR_PORT"

    iptables -t nat -A OUTPUT -j CLASH

    # 转发流量 tcp redir
    iptables -t nat -N CLASH_EXTERNAL
    iptables -t nat -F CLASH_EXTERNAL
    # google dns first
    iptables -t nat -A CLASH_EXTERNAL -p tcp -d 8.8.8.8 -j REDIRECT --to-port "$REDIR_PORT"
    iptables -t nat -A CLASH_EXTERNAL -p tcp -d 8.8.4.4 -j REDIRECT --to-port "$REDIR_PORT"
    # private
    setup_private nat CLASH_EXTERNAL
    # tcp redir
    iptables -t nat -A CLASH_EXTERNAL -p tcp -j REDIRECT --to-port "$REDIR_PORT"

    iptables -t nat -A PREROUTING -j CLASH_EXTERNAL

    # 转发流量 udp tproxy
    iptables -t mangle -N CLASH_EXTERNAL
    iptables -t mangle -F CLASH_EXTERNAL
    # private
    setup_private mangle CLASH_EXTERNAL
    # udp tproxy redir
    iptables -t mangle -A CLASH_EXTERNAL -p udp -j TPROXY --on-port "$REDIR_PORT" --tproxy-mark $MARK_ID

    iptables -t mangle -A PREROUTING -j CLASH_EXTERNAL

    # route udp
    ip rule add fwmark $MARK_ID table $TABLE_ID
    ip route add local default dev lo table $TABLE_ID
}

# 在clash正常启动后返回。从clash输出中判断dns或restful api监听启动
start_clash() {
    echo 'starting clash'
    sudo -H -u $RUN_USER clash -d $CLASH_DIR > $CLASH_DIR/temp.log &
    clash_pid=$!
    echo "the running clash pid is $clash_pid"
    tail -f $CLASH_DIR/temp.log | while read -r line
    do 
        echo "$line"
        if echo "$line" | grep "listening at" &> /dev/null; then
            echo "clash has started on line: $line"
            killall tail
            break
        fi
    done
}

if [[ ! -v ENABLED ]]; then
    # echo "direct starting clash"
    # mkdir -p /home/clash/.config/clash
    # chown -R clash /home/clash/.config/clash
    # cp /root/.config/clash/config.yaml /home/clash/.config/clash/
    # chown clash /clash
    # setcap 'cap_net_admin,cap_net_bind_service=+ep' /clash
    # exec sudo -H -u clash /clash

    echo "direct starting clash"
    exec sudo -H -u $RUN_USER clash -d $CLASH_DIR
else
    init_env
    clean

    # redir-host with tun    
    if [[ -v TUN_ENABLED && -v DNS_REDIR_HOST_ENABLED ]]; then
        start_clash
        setup_tun_redir
    # fake-ip with tun
    elif [[ -v TUN_ENABLED && ! -v DNS_REDIR_HOST_ENABLED ]]; then
        start_clash
        setup_tun_fakeip
    # redir host
    elif [[ ! -v TUN_ENABLED && -v REDIR_PORT ]]; then
        start_clash
        setup_redir
    else
        echo "No startup mode found, exiting"
        exit 0
    fi 
    # 等待clash退出清理
    trap clean SIGTERM
    # 在sh后台输出日志
    tail -f $CLASH_DIR/temp.log &
    echo "waiting clash $clash_pid"
    wait $clash_pid
fi

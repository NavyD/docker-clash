# docker透明代理部署

使用docker部署clash-premium 基于tun的透明代理。目前只支持tun，请确保clash config.yml中开启了tun

```yml
tun:
  enable: true
#...
```

## 使用方法

必须在linux主机上打开ipv4转发：`sysctl -w net/ipv4/ip_forward=1`

持久化：`echo net.ipv4.ip_forward=1 | sudo tee -a /etc/sysctl.conf`

使用docker-compose文件运行`docker-compose up -d`

```yml
version: "3"

services:
  clash-premium-ui:
    image: clash-premium-ui
    container_name: clash
    network_mode: host
    restart: always
    # 使用clash-premium的docker镜像无法创建tun: https://github.com/Dreamacro/clash/issues/736
    cap_add: 
      - NET_ADMIN
    devices:
      - /dev/net/tun
    volumes: 
      - type: bind
        source: "${PWD}/config.yaml"
        target: /root/.config/clash/config.yaml
        read_only: true
```

支持的环境变量：

| name       | default | desc                                                  |
| ---------- | ------- | ----------------------------------------------------- |
| TUN_NAME   | `utun`  | nic tun name                                          |
| TABLE_ID   | `0x162` | tun route table id                                    |
| MARK_ID    | `0x162` | traffic mark                                          |
| LOOP_LIMIT | `30`    | The number of times to check if tun exists at startup |
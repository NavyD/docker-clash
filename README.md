# docker透明代理部署

使用docker部署clash-premium 基于tun的透明代理。支持从配置文件中读取clash工作模式做出不同配置

- redir
- fake-ip
- tun-redir
- tun-fake-ip

## 使用方法

使用docker-compose文件运行`docker-compose up -d`。如果要更改clash工作模式如：redir -> tun-fakeip，只需要修改对应配置文件重启docker容器即可

```yml
version: "3"

services:
  clash-premium-ui:
    image: navyd/clash-premium-ui:latest
    container_name: clash
    network_mode: host
    restart: always
    environment: 
      # 启用配置。否则将直接启动clash不做任何配置
      - ENABLED=true
    # 仅使用cap_add将无法代理本机docker
    # cap_add: 
    #   # 使用clash-premium的docker镜像无法创建tun: https://github.com/Dreamacro/clash/issues/736
    #   - NET_ADMIN
    # 使用sysctl支持代理本机docker内部流量。否则将无法代理本机docker
    privileged: true
    devices:
      - /dev/net/tun
    volumes: 
      - type: bind
        source: ./config.yaml
        # 默认的clash工作目录为/clash如：clash -d /clash
        target: /clash/config.yaml
        read_only: true
    # 自定义dns 当clash作为本地上游dns时 clash启动时无法找到可用的dns
    dns: 
      - 8.8.8.8
      - 119.29.29.29
      - 127.0.0.1

```

支持的环境变量：

| name       | default | desc                                                  |
| ---------- | ------- | ----------------------------------------------------- |
| TUN_NAME   | `utun`  | nic tun name                                          |
| TABLE_ID   | `0x162` | tun route table id                                    |
| MARK_ID    | `0x162` | traffic mark                                          |

## 注意

- 如果没有给docker privileged权限将无法修改本机sys属性，可能会遇到ip无法转发、无法代理docker bridge流量、tun接口rp_filter反射路由的问题。如果清楚clash工作原理，可以仅配置`cap_add: - NET_ADMIN`
- 使用`nobody`启动clash区分clash流量循环
- 非tun模式对本机不支持udp代理，但本机docker支持udp代理

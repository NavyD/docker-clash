# clash透明代理

使用docker部署clash-premium 基于tun的透明代理。支持从配置文件中读取clash工作模式做出不同配置

- redir
- fake-ip
- tun-redir
- tun-fake-ip

支持[yacd web ui](https://github.com/haishanh/yacd)访问`http://localhost:9090/ui`，在配置文件中添加：

```yml
# socks-port: 7891
external-controller: 0.0.0.0:9090
external-ui: /ui
# ...
```

## 使用方法

使用docker-compose文件运行`docker-compose up -d`。如果需要实时查看容器后台日志：`docker-compose up`或`docker logs <container_name> -f`

```yml
version: "3"

services:
  clash-premium-ui:
    image: navyd/clash-premium-ui:latest
    container_name: clash
    # 使用linux 主机网络
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

然后配置clash作为系统dns `127.0.0.1:53`端口启动。如果使用dnsmasq作为本机dns，clash可作为dnsmasq上游dns不需要在53端口启动

如果要更改clash工作模式如：`redir -> tun-fakeip`，只需要修改对应配置文件重启docker容器即可

```yml
# redir
tun:
  enable: false
#...
dns:
  enable: true
  enhanced-mode: redir-host

# restart clash after tun-fakeip
tun:
  enable: true
#...
dns:
  enable: true
  enhanced-mode: fake-ip
```

支持的环境变量：

| name        | default | desc                                 |
| ----------- | ------- | ------------------------------------ |
| TUN_NAME    | `utun`  | nic tun name                         |
| TABLE_ID    | `0x162` | tun route table id                   |
| MARK_ID     | `0x162` | traffic mark                         |
| TUN_ENABLED |         | config.yaml:`tun: enable:true\|false`|
| REDIR_PORT  |         | config.yaml:`redir-port:xxxx`        |

## 注意

- 不允许修改环境变量：`RUN_USER=nobody,CLASH_DIR=/clash`，由于在Dockerfile中指定，直接修改将无法启动容器。如果将dockerfile中修改到shell中，可能无法`chown -R $CLASH_DIR`中挂载的config.yaml权限
- 如果没有给docker privileged权限将无法修改本机sys属性，可能会遇到ip无法转发、无法代理docker bridge流量、tun接口rp_filter反射路由的问题。如果清楚clash工作原理，可以仅配置`cap_add: - NET_ADMIN`
- 使用`nobody`启动clash区分clash流量循环
- 非tun模式对本机不支持udp代理，但本机docker支持udp代理
- 仅支持linux host模式，性能与原生linux应用一致
- 当前在rasp4 arm64与wsl2 amd64平台测试过工作正常
- docker hub由github actions自动构建

links:

- [git repo](https://github.com/NavyD/docker-clash)
- [docker hub repo](https://hub.docker.com/repository/docker/navyd/clash)

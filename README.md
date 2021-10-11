# clashutil

一个clash透明代理工具，使用docker部署基于[clash-premium](https://github.com/Dreamacro/clash)的透明代理。支持从配置文件中读取clash工作模式做出不同配置

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

### cli

使用poetry构建

```bash
$ clashutil --help
Usage: clashutil [OPTIONS]

  a clash transparent proxy tool

Options:
  --clean                  clear all configuration for clash
  -f, --config-path PATH   config file of clash. default read config file from
                           `.`, `$HOME/.config/.clash/`
  -p, --clash-pid INTEGER  pid of clash. if not specified, find the
                           corresponding clash process from the configuration
                           port
  -v, --verbose            log level. default fatal. level: error: -v to
                           debug: -vvvv
  -b, --clash-bin PATH     the name or path of clash binary. if not specified,
                           the clash process must already exist
  -d, --clash-home PATH    clash options: -d
  -D, --detach             exit directly instead of waiting for the clash
                           process
  -u, --user TEXT          indicates the user who started the clash process,
                           the default is the user of the current process
  -t, --wait-time FLOAT    wait for seconds to check the start of clash. exit
                           if it timeout  [default: 15]
  --help                   Show this message and exit.
```

### docker

查看命令用法：`docker run --rm navyd/clash:latest --help`

使用docker-compose文件运行`docker-compose up -d`。如果需要实时查看容器后台日志：`docker-compose up`或`docker logs -f <container_name>`

```yml
version: "3"

services:
  clash:
    image: navyd/clash:latest
    container_name: clash
    network_mode: host
    restart: always
    # [How do I break a string in YAML over multiple lines?](https://stackoverflow.com/a/21699210/8566831)
    command: >
      -f /config.yaml
      -b clash
      -d /clash_dir
      -u nobody
      -vvv

    # 仅使用cap_add将无法代理本机docker
    # cap_add:
    # 使用clash-premium的docker镜像无法创建tun: https://github.com/Dreamacro/clash/issues/736
    #   - NET_ADMIN
    # 使用sysctl支持代理本机docker 内部流量
    privileged: true
    devices:
      - /dev/net/tun
    volumes:
      - type: bind
        source: ./config.yaml
        target: /config.yaml
        read_only: true
    # 自定义dns 当clash作为本地上游dns时 clash启动时无法找到可用的dns
    dns:
      - 8.8.8.8
      - 119.29.29.29
      - 127.0.0.1
```

然后配置clash作为系统dns `53`端口启动。如果使用dnsmasq作为本机dns，clash可作为dnsmasq上游dns不需要在53端口启动

如果要更改clash工作模式如：`redir -> tun-fakeip`，只需要修改对应配置文件重启docker容器即可如：

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

## 注意

- 如果没有给docker privileged权限将无法修改本机sys属性，可能会遇到ip无法转发、无法代理docker bridge流量、tun接口rp_filter反射路由的问题。如果清楚clash工作原理，可以仅配置`cap_add: - NET_ADMIN`
- 使用`nobody`启动以避免clash流量循环
- 非tun模式对本机不支持udp代理，但本机docker支持udp代理
- 仅支持linux host模式，性能与原生linux应用一致
- 当前在ras pi4 arm64与wsl2 amd64平台测试过工作正常

links:

- [git repo](https://github.com/NavyD/docker-clash)
- [docker hub repo](https://hub.docker.com/r/navyd/clash)

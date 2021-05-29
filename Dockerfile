FROM dreamacro/clash-premium:2021.05.08

LABEL maintainer ="dhjnavyd@gmail.com"

RUN wget -O yacd.zip 'https://github.com/haishanh/yacd/archive/gh-pages.zip' \
    && mkdir /ui \
    && unzip yacd.zip -d /ui \
    && mv /ui/yacd-gh-pages/* /ui \
    && rm -rf /ui/yacd-gh-pages \
    && rm -rf yacd.zip \
    && apk add --no-cache bash iptables

COPY entrypoint.sh /

ENTRYPOINT [ "bash", "/entrypoint.sh" ]

FROM dreamacro/clash-premium:latest

RUN wget -O yacd.zip 'https://github.com/haishanh/yacd/archive/gh-pages.zip' \
    && mkdir /ui \
    && unzip yacd.zip -d /ui \
    && mv /ui/yacd-gh-pages/* /ui \
    && rm -rf /ui/yacd-gh-pages \
    && rm -rf yacd.zip \
    && apk add --no-cache bash iptables

COPY entrypoint.sh /

ENTRYPOINT [ "bash", "/entrypoint.sh" ]

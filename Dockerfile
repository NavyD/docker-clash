FROM dreamacro/clash-premium:2021.05.08

LABEL maintainer ="dhjnavyd@gmail.com"

RUN wget -O yacd.zip 'https://github.com/haishanh/yacd/archive/gh-pages.zip' \
    && mkdir /ui \
    && unzip yacd.zip -d /ui \
    && mv /ui/yacd-gh-pages/* /ui \
    && rm -rf /ui/yacd-gh-pages \
    && rm -rf yacd.zip \
    && apk add --no-cache bash iptables

RUN apk add --no-cache sudo libcap

ENV RUN_USER=nobody CLASH_DIR=/clash

RUN mv /clash /usr/bin \
    && chown $RUN_USER /usr/bin/clash \
    && setcap 'cap_net_admin,cap_net_bind_service=+ep' /usr/bin/clash \
    && mkdir -p $CLASH_DIR \
    && chown -R $RUN_USER $CLASH_DIR

COPY entrypoint.sh /

ENTRYPOINT [ "bash", "/entrypoint.sh" ]

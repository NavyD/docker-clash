FROM dreamacro/clash-premium:2021.07.03

LABEL maintainer = "dhjnavyd@gmail.com"

ENV RUN_USER=nobody CLASH_DIR=/clash UI_DIR=/ui

# yacd ui
RUN wget -O yacd.zip 'https://github.com/haishanh/yacd/archive/gh-pages.zip' \
    && mkdir $UI_DIR \
    && unzip yacd.zip -d $UI_DIR \
    && mv $UI_DIR/yacd-gh-pages/* $UI_DIR \
    && rm -rf $UI_DIR/yacd-gh-pages \
    && rm -rf yacd.zip \
    # && sed -i 's/dl-cdn.alpinelinux.org/mirrors.tuna.tsinghua.edu.cn/g' /etc/apk/repositories
    # install
    && apk add --no-cache bash iptables sudo libcap strace \
    # clash user settings
    && mv /clash /usr/bin \
    && chown $RUN_USER /usr/bin/clash \
    && setcap 'cap_net_admin,cap_net_bind_service=+ep' /usr/bin/clash \
    && mkdir -p $CLASH_DIR \
    && chown -R $RUN_USER $CLASH_DIR

COPY entrypoint.sh /

ENTRYPOINT [ "/entrypoint.sh" ]

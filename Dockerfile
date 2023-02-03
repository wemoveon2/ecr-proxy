ARG DEBIAN_HASH
FROM debian@sha256:${DEBIAN_HASH}

ARG CONFIG_DIR
ADD ${CONFIG_DIR} /config

ARG SCRIPTS_DIR
ADD ${SCRIPTS_DIR} /usr/local/bin

RUN packages-install

RUN echo "/usr/lib/x86_64-linux-gnu/faketime/libfaketime.so.1" \
    > /etc/ld.so.preload

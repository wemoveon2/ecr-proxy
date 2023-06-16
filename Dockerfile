ARG DEBIAN_HASH
FROM debian@sha256:${DEBIAN_HASH} as build-base

ARG CONFIG_DIR
ADD ${CONFIG_DIR} /config

ARG SCRIPTS_DIR
ADD ${SCRIPTS_DIR} /usr/local/bin

ARG FETCH_DIR
RUN --mount=type=bind,source=fetch,target=/fetch,rw \
    packages-install

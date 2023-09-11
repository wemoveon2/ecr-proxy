FROM --platform=${BUILDPLATFORM:-linux/amd64} golang:1.21-bullseye@sha256:436969571fa091f02d34bf2b9bc8850af7de0527e5bc53c39eeda88bc01c38d3 AS builder

ARG SOURCE_DATE_EPOCH
ARG TARGETOS
ARG TARGETARCH

ENV GOPATH=/usr/home/build
ENV GOOS=${TARGETOS}
ENV GOARCH=${TARGETARCH}

RUN mkdir -p /newroot/etc/ssl/certs \
  && cp -ra --parents /etc/ssl/certs /newroot/

WORKDIR /usr/home/build/src

COPY ./src/go.mod ./src/go.sum ./
RUN go mod download

COPY ./src ./
RUN GOPROXY=off \
  CGO_ENABLED=0 \
  go build \
    -o /newroot/usr/local/bin/ecr-proxy \
    ./cmd/ecr-proxy

# Hack to reset timestamps on directories in a multi-platform build
RUN find /newroot -newermt "@${SOURCE_DATE_EPOCH}" -writable \
  | xargs touch --date="@${SOURCE_DATE_EPOCH}" --no-dereference


FROM scratch

LABEL org.opencontainers.image.source https://github.com/tkhq/ecr-proxy

COPY --from=builder /newroot /

USER 65532:65532

ENTRYPOINT ["/usr/local/bin/ecr-proxy"]

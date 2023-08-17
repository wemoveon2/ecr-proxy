FROM --platform=${BUILDPLATFORM:-linux/amd64} golang:1.21-bullseye@sha256:02f350d8452d3f9693a450586659ecdc6e40e9be8f8dfc6d402300d87223fdfa AS builder

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

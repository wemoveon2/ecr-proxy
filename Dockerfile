FROM --platform=${BUILDPLATFORM:-linux/amd64} golang:1.20-bullseye AS builder

ARG TARGETPLATFORM
ARG BUILDPLATFORM
ARG TARGETOS
ARG TARGETARCH

ENV CGO_ENABLED=0
ENV GOPATH=/usr/home/build

WORKDIR /usr/home/build

COPY ./src ./src

WORKDIR /usr/home/build/src/cmd/ecr-proxy

RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -installsuffix 'static' -o /usr/local/bin/ecr-proxy

FROM --platform=${TARGETPLATFORM:-linux/amd64} scratch

LABEL org.opencontainers.image.source https://github.com/tkhq/ecr-proxy

COPY --from=builder /etc/ssl/certs /etc/ssl/certs

COPY --from=builder /usr/local/bin/ecr-proxy /usr/local/bin/ecr-proxy

WORKDIR /

ENTRYPOINT ["/usr/local/bin/ecr-proxy"]

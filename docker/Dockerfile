FROM alpine:3.22

ARG ZIG_VERSION=0.15.2

RUN apk add --no-cache ca-certificates xz git \
 && wget -qO- https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz \
    | tar -xJ -C /opt \
 && ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig

WORKDIR /work

CMD ["zig"]

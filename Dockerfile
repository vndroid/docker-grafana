# syntax=docker/dockerfile:1.19.0
ARG AL_VER=3.21
ARG PD_VER=12.2.0
ARG PD_NME=grafana

FROM --platform=$TARGETPLATFORM golang:1.25-alpine3.21 AS go-builder

ARG TARGETOS
ARG TARGETARCH
ARG GO_BUILD_TAGS="oss"
ARG WIRE_TAGS="oss"

ENV VERSION=12.2.0

RUN set -eux \
    && apk add --no-cache binutils-gold bash gcc g++ make git binutils

WORKDIR /tmp/grafana

RUN set -eux \
    && git clone -b v${VERSION} --single-branch --depth=1 https://github.com/grafana/grafana.git . \
    && go mod download \
    && COMMIT_SHA=$(git rev-parse HEAD) \
    && BUILD_BRANCH=$(git rev-parse --abbrev-ref HEAD) \
    && GOOS=$TARGETOS GOARCH=$TARGETARCH make build-go GO_BUILD_TAGS=${GO_BUILD_TAGS} WIRE_TAGS=${WIRE_TAGS} \
    && strip /tmp/grafana/bin/linux-${TARGETARCH}/grafana /tmp/grafana/bin/linux-${TARGETARCH}/grafana-cli /tmp/grafana/bin/linux-${TARGETARCH}/grafana-server \
    && find /root -maxdepth 1 -type d -name ".*" ! -name "." ! -name ".." -exec rm -rf {} + \
    && rm -rf /go/pkg

FROM --platform=$TARGETPLATFORM node:22-alpine3.21 AS js-builder

ARG JS_YARN_BUILD_FLAG=build

ENV NODE_ENV=production
ENV NODE_OPTIONS=--max_old_space_size=8000

WORKDIR /tmp/grafana

RUN set -eux \
    && apk add --no-cache make build-base git \
    && apk add --no-cache python3 py3-pip py3-setuptools py3-wheel

COPY --from=go-builder /tmp/grafana/package.json ./
COPY --from=go-builder /tmp/grafana/project.json ./
COPY --from=go-builder /tmp/grafana/nx.json ./
COPY --from=go-builder /tmp/grafana/yarn.lock ./
COPY --from=go-builder /tmp/grafana/.yarnrc.yml ./
COPY --from=go-builder /tmp/grafana/.yarn .yarn
COPY --from=go-builder /tmp/grafana/packages packages
COPY --from=go-builder /tmp/grafana/e2e-playwright e2e-playwright
COPY --from=go-builder /tmp/grafana/public public
COPY --from=go-builder /tmp/grafana/LICENSE ./
COPY --from=go-builder /tmp/grafana/conf/defaults.ini ./conf/defaults.ini
COPY --from=go-builder /tmp/grafana/e2e e2e

RUN set -eux \
    && yarn install --immutable

COPY --from=go-builder /tmp/grafana/tsconfig.json ./
COPY --from=go-builder /tmp/grafana/eslint.config.js ./
COPY --from=go-builder /tmp/grafana/.editorconfig ./
COPY --from=go-builder /tmp/grafana/.browserslistrc ./
COPY --from=go-builder /tmp/grafana/.prettierrc.js ./
COPY --from=go-builder /tmp/grafana/scripts scripts
COPY --from=go-builder /tmp/grafana/emails emails

RUN set -eux \
    && yarn ${JS_YARN_BUILD_FLAG} \
    && find /root -maxdepth 1 -type d -name ".*" ! -name "." ! -name ".." -exec rm -rf {} +

FROM --platform=$TARGETPLATFORM alpine:3.21

LABEL maintainer="Grafana Labs <hello@grafana.com>"
LABEL org.opencontainers.image.source="https://github.com/grafana/grafana"

ARG GF_UID="472"
ARG GF_GID="0"
ARG TARGETARCH

ENV PATH="/usr/share/grafana/bin:$PATH" \
    GF_PATHS_CONFIG="/etc/grafana/grafana.ini" \
    GF_PATHS_DATA="/var/lib/grafana" \
    GF_PATHS_HOME="/usr/share/grafana" \
    GF_PATHS_LOGS="/var/log/grafana" \
    GF_PATHS_PLUGINS="/var/lib/grafana/plugins" \
    GF_PATHS_PROVISIONING="/etc/grafana/provisioning"

WORKDIR $GF_PATHS_HOME

RUN set -eux \
    && apk add --no-cache ca-certificates bash curl tzdata musl-utils \
    && apk info -vv | sort;

# glibc support for alpine x86_64 only
# docker run --rm --env STDOUT=1 sgerrand/glibc-builder 2.40 /usr/glibc-compat > glibc-bin-2.40.tar.gz
ARG GLIBC_VERSION=2.40

RUN if grep -i -q alpine /etc/issue && [ `arch` = "x86_64" ]; then \
    wget -qO- "https://dl.grafana.com/glibc/glibc-bin-$GLIBC_VERSION.tar.gz" | tar zxf - -C / \
    usr/glibc-compat/lib/ld-linux-x86-64.so.2 \
    usr/glibc-compat/lib/libc.so.6 \
    usr/glibc-compat/lib/libdl.so.2 \
    usr/glibc-compat/lib/libm.so.6 \
    usr/glibc-compat/lib/libpthread.so.0 \
    usr/glibc-compat/lib/librt.so.1 \
    usr/glibc-compat/lib/libresolv.so.2 && \
    mkdir /lib64 && \
    ln -s /usr/glibc-compat/lib/ld-linux-x86-64.so.2 /lib64; \
    fi

COPY --from=go-builder /tmp/grafana/conf ./conf

RUN if [ ! $(getent group "$GF_GID") ]; then \
    if grep -i -q alpine /etc/issue; then \
    addgroup -S -g $GF_GID grafana; \
    else \
    addgroup --system --gid $GF_GID grafana; \
    fi; \
    fi && \
    GF_GID_NAME=$(getent group $GF_GID | cut -d':' -f1) && \
    mkdir -p "$GF_PATHS_HOME/.aws" && \
    if grep -i -q alpine /etc/issue; then \
    adduser -S -u $GF_UID -G "$GF_GID_NAME" grafana; \
    else \
    adduser --system --uid $GF_UID --ingroup "$GF_GID_NAME" grafana; \
    fi && \
    mkdir -p "$GF_PATHS_PROVISIONING/datasources" \
    "$GF_PATHS_PROVISIONING/dashboards" \
    "$GF_PATHS_PROVISIONING/notifiers" \
    "$GF_PATHS_PROVISIONING/plugins" \
    "$GF_PATHS_PROVISIONING/access-control" \
    "$GF_PATHS_PROVISIONING/alerting" \
    "$GF_PATHS_LOGS" \
    "$GF_PATHS_PLUGINS" \
    "$GF_PATHS_DATA" && \
    cp conf/sample.ini "$GF_PATHS_CONFIG" && \
    cp conf/ldap.toml /etc/grafana/ldap.toml && \
    chown -R "grafana:$GF_GID_NAME" "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING" && \
    chmod -R 777 "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING"

COPY --from=go-builder /tmp/grafana/bin/*/grafana /tmp/grafana/bin/*/grafana-cli /tmp/grafana/bin/*/grafana-server ./bin/
COPY --from=go-builder /tmp/grafana/packaging/docker/run.sh /usr/local/bin/
COPY --from=js-builder /tmp/grafana/public ./public
COPY --chown=root:root --chmod=755 docker-entrypoint.sh /usr/local/bin/

EXPOSE 3000

USER "$GF_UID"
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["run.sh"]
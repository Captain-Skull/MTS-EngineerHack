ARG FLUENTD_IMAGE=fluent/fluentd:v1.19.3-debian-2.4@sha256:57d670d33bb9fd420dce95cc8930eae9ab027b34097860fe295d33edb5ecae33

FROM ${FLUENTD_IMAGE} AS build
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*
COPY Gemfile /tmp/Gemfile
RUN gem install --no-document --file /tmp/Gemfile \
 && gem sources --clear-all \
 && rm -rf /usr/local/bundle/cache/*.gem /tmp/*

FROM ${FLUENTD_IMAGE}
LABEL org.opencontainers.image.title="fluentd-k8s-loki" \
      org.opencontainers.image.description="Fluentd DaemonSet image: CRI parser, Kubernetes metadata, Loki output, Prometheus metrics" \
      org.opencontainers.image.licenses="Apache-2.0"
COPY --from=build /usr/local/bundle /usr/local/bundle
USER fluent

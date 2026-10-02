# In-cluster helm runner. Ships the helm binary and a baked copy of the
# sycophant-tenant chart at /charts/sycophant-tenant, so a Job can run
# `helm upgrade --install <tenant> /charts/sycophant-tenant` with no chart
# registry and no network fetch of the chart. Build context is the repo root
# (the chart lives under charts/), e.g.
#   docker build -f images/provisioner/Dockerfile -t sycophant-provisioner:local .
FROM alpine:3.21
ARG TARGETARCH
ARG HELM_VERSION=v3.17.3
ARG KUBECTL_VERSION=v1.31.0
RUN apk add --no-cache curl ca-certificates && \
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
      | tar -xzO "linux-${TARGETARCH}/helm" > /usr/local/bin/helm && \
    chmod +x /usr/local/bin/helm && \
    curl -fsSL -o /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" && \
    chmod +x /usr/local/bin/kubectl && \
    apk del curl
COPY charts/sycophant-tenant /charts/sycophant-tenant
USER 65532:65532

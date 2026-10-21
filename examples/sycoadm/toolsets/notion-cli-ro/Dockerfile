ARG BASE_IMAGE=toolset-base:local
FROM ${BASE_IMAGE}
RUN apk add --no-cache curl bash ca-certificates jq make \
    && curl -fsSL https://ntn.dev | bash \
    && (test -x /root/.local/bin/ntn && mv /root/.local/bin/ntn /usr/local/bin/ntn \
        || test -x /usr/local/bin/ntn)
# Pin the Notion API version so `ntn` doesn't try to fetch the OpenAPI
# spec at runtime to auto-detect it. The egress allowlist permits
# api.notion.com only; the spec host isn't reachable, so without this
# every call fails with "Failed to fetch OpenAPI spec".
ENV NOTION_API_VERSION=2022-06-28
COPY Makefile /etc/toolset/Makefile
COPY dispatch /etc/toolset/dispatch
RUN chmod +x /etc/toolset/dispatch

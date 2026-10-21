ARG BASE_IMAGE=toolset-base:local
FROM ${BASE_IMAGE}
RUN apk add --no-cache git openssh-client
COPY dispatch /etc/toolset/dispatch
RUN chmod +x /etc/toolset/dispatch

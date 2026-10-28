FROM toolset:local
# curl, not busybox wget: wget cannot tell an HTTP error status from a
# connection failure.
RUN apk add --no-cache curl jq
COPY dispatch /etc/toolset/dispatch
RUN chmod +x /etc/toolset/dispatch

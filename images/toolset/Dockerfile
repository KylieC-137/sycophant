ARG BASE_IMAGE=toolset-base:local
FROM ${BASE_IMAGE}
RUN apk add --no-cache ripgrep git \
 && git config --system --add safe.directory '*' \
 && git config --system user.name 'sycophant' \
 && git config --system user.email 'noreply@invalid'

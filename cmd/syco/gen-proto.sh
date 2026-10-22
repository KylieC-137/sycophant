#!/usr/bin/env bash
# Regenerate Go protobuf stubs from the shared .proto files.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
source "$REPO_ROOT/lib/shell.sh"
cd "$REPO_ROOT"

protoc \
  -I crates/relay-proto/proto \
  -I crates/proto-common/proto \
  --go_out=cmd/syco/internal/proto --go_opt=paths=source_relative \
  --go-grpc_out=cmd/syco/internal/proto --go-grpc_opt=paths=source_relative \
  crates/relay-proto/proto/relay/v1/relay.proto \
  crates/proto-common/proto/sycophant/common/v1/common.proto

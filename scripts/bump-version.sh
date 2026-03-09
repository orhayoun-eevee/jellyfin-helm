#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHART_YAML="$PROJECT_ROOT/Chart.yaml"
CHART_LOCK="$PROJECT_ROOT/Chart.lock"
SCENARIOS_DIR="$PROJECT_ROOT/tests/scenarios"
SNAPSHOTS_DIR="$PROJECT_ROOT/tests/snapshots"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.30.0}"

if [ $# -ne 1 ]; then
  error "Usage: $0 <new-version>"
  exit 1
fi

NEW_VERSION="$1"
if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.+-]+)?$ ]]; then
  error "Invalid semantic version: $NEW_VERSION"
  exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
  error "helm is required"
  exit 1
fi

CURRENT_VERSION=$(grep '^version:' "$CHART_YAML" | awk '{print $2}')
if [ "$CURRENT_VERSION" = "$NEW_VERSION" ]; then
  error "Version is already $NEW_VERSION"
  exit 1
fi

info "Bumping chart version: $CURRENT_VERSION -> $NEW_VERSION"
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s/^version: .*/version: $NEW_VERSION/" "$CHART_YAML"
else
  sed -i "s/^version: .*/version: $NEW_VERSION/" "$CHART_YAML"
fi

info "Refreshing Chart.lock"
helm dependency update "$PROJECT_ROOT" --skip-refresh >/dev/null

if [ ! -d "$SCENARIOS_DIR" ]; then
  error "Scenarios directory not found: $SCENARIOS_DIR"
  exit 1
fi

mkdir -p "$SNAPSHOTS_DIR"
info "Regenerating snapshots (kube-version=$KUBERNETES_VERSION)"
shopt -s nullglob
scenarios=("$SCENARIOS_DIR"/*.yaml "$SCENARIOS_DIR"/*.yml)
if [ ${#scenarios[@]} -eq 0 ]; then
  error "No scenario files found in $SCENARIOS_DIR"
  exit 1
fi

for scenario in "${scenarios[@]}"; do
  name=$(basename "$scenario")
  name=${name%.yaml}
  name=${name%.yml}
  info "Updating snapshot: $name"
  helm template test-release "$PROJECT_ROOT" \
    --values "$scenario" \
    --kube-version "$KUBERNETES_VERSION" \
    > "$SNAPSHOTS_DIR/$name.yaml"
done

info "Done. Updated files: Chart.yaml, Chart.lock, tests/snapshots/*.yaml"

#!/usr/bin/env bash

set -euo pipefail

# =========================
# CPU / THREAD HELPERS
# =========================

get_cpu_count() {
    local cpu_count=1

    if command -v nproc >/dev/null 2>&1; then
        cpu_count="$(nproc)"
    elif command -v sysctl >/dev/null 2>&1; then
        cpu_count="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
    fi

    [[ "$cpu_count" =~ ^[0-9]+$ ]] || cpu_count=1
    (( cpu_count < 1 )) && cpu_count=1

    echo "$cpu_count"
}

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

IMAGE="${RUNNER_IMAGE:-3dgi/3dbag-pipeline-tools:2026.04.01}"
DEFAULT_BUFFER="10"
DEFAULT_OUTPUT="output"

# -----------------------------------------------------------------------------
# Help and utility functions
# -----------------------------------------------------------------------------


die() {
  echo "Error: $*" >&2
  exit 1
}

is_number() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

validate_bbox() {
  local xmin="$1"
  local ymin="$2"
  local xmax="$3"
  local ymax="$4"

  awk \
    -v xmin="$xmin" \
    -v ymin="$ymin" \
    -v xmax="$xmax" \
    -v ymax="$ymax" \
    'BEGIN { exit !(xmin < xmax && ymin < ymax) }' \
    || die "--bbox must satisfy xmin < xmax and ymin < ymax"
}

detect_default_jobs() {
    local cpu_count
    cpu_count="$(get_cpu_count)"
    echo $((cpu_count - 1))
}


usage() {
  cat <<EOF
Usage:
  ./run.sh --bbox xmin ymin xmax ymax [--buffer meters] [--out path] [--jobs n]

Options:
  --bbox    Required input bounding box in EPSG:2154
  --buffer  Optional buffer in meters, default: 10
  --out     Optional output directory, default: ./output (cleared on each run)
  --jobs    Optional roofer thread count, default: $(detect_default_jobs)
  --help    Show this help message
EOF
}

# -----------------------------------------------------------------------------
# Paths and default arguments
# -----------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_JOBS="$(detect_default_jobs)"

BBOX=()
BUFFER="$DEFAULT_BUFFER"
OUT_ARG="$DEFAULT_OUTPUT"
JOBS="$DEFAULT_JOBS"

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bbox)
      shift
      [[ $# -ge 4 ]] || die "--bbox requires four numeric values"
      BBOX=("$1" "$2" "$3" "$4")
      shift 4
      ;;
    --buffer)
      shift
      [[ $# -ge 1 ]] || die "--buffer requires a numeric value"
      BUFFER="$1"
      shift
      ;;
    --out)
      shift
      [[ $# -ge 1 ]] || die "--out requires a path"
      OUT_ARG="$1"
      shift
      ;;
    --jobs)
      shift
      [[ $# -ge 1 ]] || die "--jobs requires an integer value"
      JOBS="$1"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Input validation
# -----------------------------------------------------------------------------

# BBOX

[[ ${#BBOX[@]} -eq 4 ]] || die "--bbox is required"

for value in "${BBOX[@]}" "$BUFFER"; do
  is_number "$value" || die "non-numeric value detected: $value"
done

validate_bbox "${BBOX[0]}" "${BBOX[1]}" "${BBOX[2]}" "${BBOX[3]}"

# JOBS

[[ "$JOBS" =~ ^[0-9]+$ ]] || die "--jobs must be an integer >= 0"

# OUTPUT DIR

if [[ "$OUT_ARG" = /* ]]; then
  HOST_OUTPUT="$OUT_ARG"
else
  HOST_OUTPUT="$REPO_ROOT/$OUT_ARG"
fi

# -----------------------------------------------------------------------------
# Environment preparation
# -----------------------------------------------------------------------------

mkdir -p "$HOST_OUTPUT"

command -v docker >/dev/null 2>&1 || die "docker is required"

DOCKER_ARGS=(
  run
  --rm
  --user "$(id -u):$(id -g)"
  -e HOME=/tmp
  -v "$REPO_ROOT:/workspace"
  -v "$HOST_OUTPUT:/work-output"
  -w /workspace
)

pass_env_if_set() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    DOCKER_ARGS+=(-e "$name")
  fi
}

for name in \
  HTTP_PROXY HTTPS_PROXY NO_PROXY \
  http_proxy https_proxy no_proxy; do
  pass_env_if_set "$name"
done

# -----------------------------------------------------------------------------
# Workflow execution
# -----------------------------------------------------------------------------

echo "Running Docker workflow in $HOST_OUTPUT"

exec docker "${DOCKER_ARGS[@]}" \
  --entrypoint bash \
  "$IMAGE" \
  /workspace/scripts/run_workflow.sh \
  --bbox "${BBOX[@]}" \
  --buffer "$BUFFER" \
  --out /work-output \
  --jobs "$JOBS"

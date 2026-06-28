#!/usr/bin/env bash

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

IMAGE="${RUNNER_IMAGE:-3dgi/3dbag-pipeline-tools:2026.06.24}"
DEFAULT_BUFFER="10"
MAX_BUFFER="500"
DEFAULT_OUTPUT="output"
DEFAULT_RUN_PREFIX="run"
RUN_MARKER=".roofer-run-output"

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

is_non_negative_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

validate_bbox() {
  local xmin="$1"
  local ymin="$2"
  local xmax="$3"
  local ymax="$4"

  awk \
    -v xmin="${xmin}" \
    -v ymin="${ymin}" \
    -v xmax="${xmax}" \
    -v ymax="${ymax}" \
    'BEGIN { exit !(xmin < xmax && ymin < ymax) }' \
    || die "--bbox must satisfy xmin < xmax and ymin < ymax"
}

ensure_safe_output_dir() {
  local resolved_output="$1"
  local resolved_home=""

  [[ -n "${resolved_output}" ]] || die "--out must resolve to a non-empty path"

  case "${resolved_output}" in
    /|/tmp|/var/tmp)
      die "--out must point to a dedicated output directory, not ${resolved_output}"
      ;;
  esac

  if [[ -n "${HOME:-}" && -d "${HOME}" ]]; then
    resolved_home="$(cd "${HOME}" && pwd -P)"
    [[ "${resolved_output}" != "${resolved_home}" ]] || die "--out must not be your home directory"
  fi

  [[ "${resolved_output}" != "${REPO_ROOT}" ]] || die "--out must not be the repository root"
  [[ "${REPO_ROOT}" != "${resolved_output}"/* ]] || die "--out must not contain the repository"
}

output_marker_path() {
  echo "$1/${RUN_MARKER}"
}

output_dir_is_marked() {
  [[ -f "$(output_marker_path "$1")" ]]
}

mark_output_dir() {
  : >"$(output_marker_path "$1")"
}

collect_output_entries() {
  local dir="$1"
  local dotglob_enabled=0
  local nullglob_enabled=0

  OUTPUT_ENTRIES=()

  shopt -q dotglob && dotglob_enabled=1
  shopt -q nullglob && nullglob_enabled=1
  shopt -s dotglob nullglob
  OUTPUT_ENTRIES=("${dir}"/*)
  (( dotglob_enabled )) || shopt -u dotglob
  (( nullglob_enabled )) || shopt -u nullglob
}

output_dir_has_payload_entries() {
  local dir="$1"
  local entry=""

  collect_output_entries "${dir}"

  for entry in "${OUTPUT_ENTRIES[@]}"; do
    [[ "${entry##*/}" == "${RUN_MARKER}" && -f "${entry}" ]] && continue
    return 0
  done

  return 1
}

clean_output_dir() {
  local dir="$1"

  ensure_safe_output_dir "${dir}"
  collect_output_entries "${dir}"

  if (( ${#OUTPUT_ENTRIES[@]} > 0 )); then
    rm -rf -- "${OUTPUT_ENTRIES[@]}"
  fi
}

clean_marked_run_dirs() {
  local root="$1"
  local entry=""

  ensure_safe_output_dir "${root}"

  if output_dir_is_marked "${root}"; then
    clean_output_dir "${root}"
    return
  fi

  collect_output_entries "${root}"

  for entry in "${OUTPUT_ENTRIES[@]}"; do
    if [[ -d "${entry}" ]] && output_dir_is_marked "${entry}"; then
      ensure_safe_output_dir "${entry}"
      rm -rf -- "${entry}"
    fi
  done
}

get_cpu_count() {
  local cpu_count=1

  if command -v nproc >/dev/null 2>&1; then
    cpu_count="$(nproc 2>/dev/null || echo 1)"
  elif command -v sysctl >/dev/null 2>&1; then
    cpu_count="$(sysctl -n hw.ncpu 2>/dev/null || echo 1)"
  fi

  [[ "${cpu_count}" =~ ^[0-9]+$ ]] || cpu_count=1
  (( cpu_count < 1 )) && cpu_count=1

  echo "${cpu_count}"
}

detect_default_jobs() {
  local cpu_count
  cpu_count="$(get_cpu_count)"
  if (( cpu_count > 1 )); then
    echo $((cpu_count - 1))
  else
    echo 1
  fi
}

generate_run_name() {
  date +"${DEFAULT_RUN_PREFIX}-%Y%m%d-%H%M%S"
}

usage() {
  cat <<EOF
Usage:
  ./run.sh --bbox xmin ymin xmax ymax [--buffer meters] [--out path] [--jobs n] [--clean]

Options:
  --bbox    Required input bounding box in EPSG:2154
  --buffer  Optional buffer in meters, 0 to ${MAX_BUFFER}, default: ${DEFAULT_BUFFER}
  --out     Optional output root directory, default: ./output
            Each run writes to a timestamped subdirectory (${DEFAULT_RUN_PREFIX}-YYYYMMDD-HHMMSS)
  --jobs    Optional roofer thread count, default: $(detect_default_jobs)
  --clean   Clear previous run directories under --out before running
  --help    Show this help message
EOF
}

# -----------------------------------------------------------------------------
# Workflow steps
# -----------------------------------------------------------------------------

init_defaults() {
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  DEFAULT_JOBS="$(detect_default_jobs)"

  BBOX=()
  BUFFER="${DEFAULT_BUFFER}"
  OUT_ARG="${DEFAULT_OUTPUT}"
  RUN_NAME="$(generate_run_name)"
  JOBS="${DEFAULT_JOBS}"
  CLEAN_OUTPUT=0
  NEEDS_OUTPUT_MARKER=0
  OUT_ROOT=""
  HOST_OUTPUT=""
  OUTPUT_ENTRIES=()
  DOCKER_ARGS=()
}

parse_args() {
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
      --clean)
        CLEAN_OUTPUT=1
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
}

validate_args() {
  local value=""

  [[ ${#BBOX[@]} -eq 4 ]] || die "--bbox is required"

  for value in "${BBOX[@]}" "${BUFFER}"; do
    is_number "${value}" || die "non-numeric value detected: ${value}"
  done

  is_non_negative_number "${BUFFER}" || die "--buffer must be greater than or equal to 0"
  awk -v b="${BUFFER}" -v m="${MAX_BUFFER}" 'BEGIN { exit !(b <= m) }' \
    || die "--buffer must not exceed ${MAX_BUFFER} meters"

  validate_bbox "${BBOX[0]}" "${BBOX[1]}" "${BBOX[2]}" "${BBOX[3]}"

  [[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be an integer > 0"
}

resolve_output_dir() {
  [[ -n "${OUT_ARG}" ]] || die "--out requires a non-empty path"
  [[ "${OUT_ARG}" = /* ]] || OUT_ARG="${PWD}/${OUT_ARG}"
}

prepare_output_dir() {
  mkdir -p "${OUT_ARG}"
  OUT_ROOT="$(cd "${OUT_ARG}" && pwd -P)"
  ensure_safe_output_dir "${OUT_ROOT}"

  if (( CLEAN_OUTPUT )); then
    clean_marked_run_dirs "${OUT_ROOT}"
  fi

  HOST_OUTPUT="${OUT_ROOT}/${RUN_NAME}"
  mkdir -p "${HOST_OUTPUT}"
  ensure_safe_output_dir "${HOST_OUTPUT}"

  if output_dir_has_payload_entries "${HOST_OUTPUT}"; then
    if ! output_dir_is_marked "${HOST_OUTPUT}"; then
      die "run directory is not marked with ${RUN_MARKER}; refusing to use a non-empty unmarked directory"
    fi
  elif ! output_dir_is_marked "${HOST_OUTPUT}"; then
    NEEDS_OUTPUT_MARKER=1
  fi

  if (( ! CLEAN_OUTPUT )) && output_dir_has_payload_entries "${HOST_OUTPUT}"; then
    die "run directory must be empty; pass --clean to clear it before running"
  fi
}

prepare_environment() {
  prepare_output_dir
  command -v docker >/dev/null 2>&1 || die "docker is required"

  if (( CLEAN_OUTPUT )); then
    clean_output_dir "${HOST_OUTPUT}"
    mark_output_dir "${HOST_OUTPUT}"
  elif (( NEEDS_OUTPUT_MARKER )); then
    mark_output_dir "${HOST_OUTPUT}"
  fi
}

pass_env_if_set() {
  local name="$1"
  if [[ -n "${!name:-}" ]]; then
    DOCKER_ARGS+=(-e "${name}")
  fi
}

build_docker_args() {
  local name=""

  # Commas below are part of Docker's --mount syntax, not array separators.
  # shellcheck disable=SC2054
  DOCKER_ARGS=(
    run
    --rm
    --user "$(id -u):$(id -g)"
    -e HOME=/tmp
    --mount type=bind,source="${REPO_ROOT}",target=/workspace,readonly
    --mount type=bind,source="${HOST_OUTPUT}",target=/output
    # Work from the writable output mount: /workspace is read-only and some
    # tools (e.g. roofer) write logs to the current directory.
    -w /output
  )

  for name in \
    HTTP_PROXY HTTPS_PROXY NO_PROXY \
    http_proxy https_proxy no_proxy; do
    pass_env_if_set "${name}"
  done
}

run_workflow() {
  echo "Running Docker workflow in ${HOST_OUTPUT}"

  exec docker "${DOCKER_ARGS[@]}" \
    --entrypoint bash \
    "${IMAGE}" \
    /workspace/scripts/run_workflow.sh \
    --bbox "${BBOX[@]}" \
    --buffer "${BUFFER}" \
    --out /output \
    --jobs "${JOBS}"
}

main() {
  init_defaults
  parse_args "$@"
  validate_args
  resolve_output_dir
  prepare_environment
  build_docker_args
  run_workflow
}

main "$@"

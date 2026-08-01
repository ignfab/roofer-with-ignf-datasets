#!/usr/bin/env bash

set -euo pipefail

# -----------------------------------------------------------------------------
# Runtime configuration
# -----------------------------------------------------------------------------

export PATH="/opt/3dbag-pipeline/tools/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MAX_LIDAR_EXTRACTION_BUFFER_METERS="500"
GEOPLATEFORME_WFS_DSN="WFS:https://data.geopf.fr/wfs?SERVICE=WFS&VERSION=2.0.0&SRSNAME=EPSG:2154"
BUILDINGS_WFS_LAYER="BDTOPO_V3:batiment"
BUILDINGS_LOCAL_LAYER="buildings"
LIDAR_TILE_INDEX_WFS_LAYER="IGNF_NUAGES-DE-POINTS-LIDAR-HD:dalle"
LIDAR_TILE_INDEX_LOCAL_LAYER="lidar_tiles"

# -----------------------------------------------------------------------------
# Help and utility functions
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  run_workflow.sh --bbox xmin ymin xmax ymax --out path [--buffer meters] [--jobs n]

Options:
  --bbox    Required input bounding box in EPSG:2154
  --buffer  Optional buffer in meters, 0 to 500, default: 10
  --out     Required output directory
  --jobs    Optional roofer job count, default: nproc
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

log() {
  echo "[workflow] $*"
}

run_timed_step() {
  local step_name="$1"
  local started_at="$SECONDS"
  shift

  "$@"
  STEP_TIMINGS+=("$step_name: $((SECONDS - started_at))s")
}

print_timing_summary() {
  local total_seconds="$1"
  local timing=""

  log "Step timings:"
  for timing in "${STEP_TIMINGS[@]}"; do
    log "  $timing"
  done
  log "  Total: ${total_seconds}s"
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
    -v xmin="$xmin" \
    -v ymin="$ymin" \
    -v xmax="$xmax" \
    -v ymax="$ymax" \
    'BEGIN { exit !(xmin < xmax && ymin < ymax) }' \
    || die "--bbox must satisfy xmin < xmax and ymin < ymax"
}

detect_default_roofer_jobs() {
  nproc
}

check_required_commands() {
  local required_commands=(ogr2ogr ogrinfo pdal roofer python3 awk sed)
  local command_name=""

  for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command not found in container PATH: $command_name"
  done
}

extract_feature_count() {
  local dataset="$1"
  local layer="$2"
  ogrinfo -ro -so "$dataset" "$layer" | awk -F': ' '/Feature Count/ {print $2; exit}'
}

extract_extent() {
  local dataset="$1"
  local layer="$2"
  local extent
  local geometry_column
  local sql_geometry_column
  local sql_layer

  geometry_column="$(ogrinfo -ro -so "$dataset" "$layer" | awk -F'= ' '/Geometry Column/ {print $2; exit}')"
  [[ -n "$geometry_column" ]] || die "could not determine geometry column for $dataset layer $layer"

  sql_geometry_column="${geometry_column//\"/\"\"}"
  sql_layer="${layer//\"/\"\"}"

  if ! extent="$(
    ogr2ogr \
      -f CSV \
      /vsistdout/ \
      "$dataset" \
      -dialect SQLITE \
      -sql "SELECT MIN(MbrMinX(\"$sql_geometry_column\")) AS xmin, MIN(MbrMinY(\"$sql_geometry_column\")) AS ymin, MAX(MbrMaxX(\"$sql_geometry_column\")) AS xmax, MAX(MbrMaxY(\"$sql_geometry_column\")) AS ymax FROM \"$sql_layer\"" \
      | awk -F, 'NR == 2 {print $1, $2, $3, $4; exit}'
  )"; then
    die "could not extract extent from $dataset layer $layer"
  fi

  [[ -n "$extent" ]] || die "could not extract extent from $dataset layer $layer"
  printf '%s\n' "$extent"
}

write_bbox_json() {
  local output_path="$1"
  local xmin="$2"
  local ymin="$3"
  local xmax="$4"
  local ymax="$5"
  cat >"$output_path" <<EOF
{
  "crs": "EPSG:2154",
  "xmin": $xmin,
  "ymin": $ymin,
  "xmax": $xmax,
  "ymax": $ymax
}
EOF
}

configure_proxy_env() {
  if [[ -n "${HTTP_PROXY:-}" && -z "${http_proxy:-}" ]]; then
    export http_proxy="$HTTP_PROXY"
  elif [[ -n "${http_proxy:-}" && -z "${HTTP_PROXY:-}" ]]; then
    export HTTP_PROXY="$http_proxy"
  fi

  if [[ -n "${HTTPS_PROXY:-}" && -z "${https_proxy:-}" ]]; then
    export https_proxy="$HTTPS_PROXY"
  elif [[ -n "${https_proxy:-}" && -z "${HTTPS_PROXY:-}" ]]; then
    export HTTPS_PROXY="$https_proxy"
  fi

  if [[ -n "${NO_PROXY:-}" && -z "${no_proxy:-}" ]]; then
    export no_proxy="$NO_PROXY"
  elif [[ -n "${no_proxy:-}" && -z "${NO_PROXY:-}" ]]; then
    export NO_PROXY="$no_proxy"
  fi

  if [[ -n "${HTTP_PROXY:-}${http_proxy:-}${HTTPS_PROXY:-}${https_proxy:-}" ]]; then
    log "Using proxy settings for GDAL/PDAL"
  fi
}

# -----------------------------------------------------------------------------
# Workflow steps
# -----------------------------------------------------------------------------

init_defaults() {
  BUILDINGS_QUERY_BBOX=()
  BUILDINGS_EXTENT=()
  LIDAR_EXTRACTION_BBOX=()
  STEP_TIMINGS=()
  LIDAR_EXTRACTION_BUFFER_METERS="10"
  OUTPUT_DIR=""
  ROOFER_JOBS="$(detect_default_roofer_jobs)"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bbox)
        shift
        [[ $# -ge 4 ]] || die "--bbox requires four values"
        BUILDINGS_QUERY_BBOX=("$1" "$2" "$3" "$4")
        shift 4
        ;;
      --buffer)
        shift
        [[ $# -ge 1 ]] || die "--buffer requires a value"
        LIDAR_EXTRACTION_BUFFER_METERS="$1"
        shift
        ;;
      --out)
        shift
        [[ $# -ge 1 ]] || die "--out requires a path"
        OUTPUT_DIR="$1"
        shift
        ;;
      --jobs)
        shift
        [[ $# -ge 1 ]] || die "--jobs requires a value"
        ROOFER_JOBS="$1"
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

  [[ ${#BUILDINGS_QUERY_BBOX[@]} -eq 4 ]] || die "--bbox is required"

  [[ -n "$OUTPUT_DIR" ]] || die "--out is required"

  for value in "${BUILDINGS_QUERY_BBOX[@]}" "$LIDAR_EXTRACTION_BUFFER_METERS"; do
    is_number "$value" || die "non-numeric value detected: $value"
  done

  is_non_negative_number "$LIDAR_EXTRACTION_BUFFER_METERS" \
    || die "--buffer must be greater than or equal to 0"

  awk \
    -v b="$LIDAR_EXTRACTION_BUFFER_METERS" \
    -v m="$MAX_LIDAR_EXTRACTION_BUFFER_METERS" \
    'BEGIN { exit !(b <= m) }' \
    || die "--buffer must not exceed $MAX_LIDAR_EXTRACTION_BUFFER_METERS meters"

  [[ "$ROOFER_JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be an integer > 0"

  validate_bbox "${BUILDINGS_QUERY_BBOX[@]}"
}

configure_runtime_environment() {
  configure_proxy_env
  check_required_commands

  export OGR_WFS_PAGING_ALLOWED=ON
  export OGR_WFS_PAGE_SIZE=5000
}

initialize_output_paths() {
  mkdir -p "$OUTPUT_DIR"

  BUILDINGS_GPKG="$OUTPUT_DIR/buildings.gpkg"
  BUILDINGS_EXTENT_JSON="$OUTPUT_DIR/buildings_extent.json"
  LIDAR_EXTRACTION_BBOX_JSON="$OUTPUT_DIR/lidar_extraction_bbox.json"
  LIDAR_TILE_INDEX_GPKG="$OUTPUT_DIR/lidar_tile_index.gpkg"
  PDAL_PIPELINE_JSON="$OUTPUT_DIR/pdal_pipeline.json"
  LIDAR_SUBSET_LAZ="$OUTPUT_DIR/lidar_subset.laz"
  ROOFER_OUTPUT_DIR="$OUTPUT_DIR/roofer_output"
  PREPARED_BUILDINGS_GPKG="$OUTPUT_DIR/buildings_prepared.gpkg"

  mkdir -p "$ROOFER_OUTPUT_DIR"
}

download_building_footprints() {
  log "Downloading building footprints from $BUILDINGS_WFS_LAYER"
  rm -f "$BUILDINGS_GPKG"
  ogr2ogr \
    -f GPKG \
    "$BUILDINGS_GPKG" \
    "$GEOPLATEFORME_WFS_DSN" \
    "$BUILDINGS_WFS_LAYER" \
    -spat "${BUILDINGS_QUERY_BBOX[@]}" \
    -spat_srs EPSG:2154 \
    -t_srs EPSG:2154 \
    -dim 2 \
    -nlt MULTIPOLYGON \
    -nln "$BUILDINGS_LOCAL_LAYER"

  BUILDING_FOOTPRINT_COUNT="$(extract_feature_count "$BUILDINGS_GPKG" "$BUILDINGS_LOCAL_LAYER")"
  [[ -n "$BUILDING_FOOTPRINT_COUNT" ]] || die "could not determine building feature count"
  [[ "$BUILDING_FOOTPRINT_COUNT" != "0" ]] || die "building query returned no features"
}

prepare_lidar_extraction_bbox() {

  read -r -a BUILDINGS_EXTENT \
    <<<"$(extract_extent "$BUILDINGS_GPKG" "$BUILDINGS_LOCAL_LAYER")"

  [[ ${#BUILDINGS_EXTENT[@]} -eq 4 ]] || die "could not determine building extent"

  write_bbox_json "$BUILDINGS_EXTENT_JSON" "${BUILDINGS_EXTENT[@]}"

  read -r -a LIDAR_EXTRACTION_BBOX <<<"$(
    awk \
      -v xmin="${BUILDINGS_EXTENT[0]}" \
      -v ymin="${BUILDINGS_EXTENT[1]}" \
      -v xmax="${BUILDINGS_EXTENT[2]}" \
      -v ymax="${BUILDINGS_EXTENT[3]}" \
      -v buffer="$LIDAR_EXTRACTION_BUFFER_METERS" \
      'BEGIN {
        printf "%.6f %.6f %.6f %.6f\n", xmin - buffer, ymin - buffer, xmax + buffer, ymax + buffer
      }'
  )"

  [[ ${#LIDAR_EXTRACTION_BBOX[@]} -eq 4 ]] || die "could not determine LiDAR extraction bbox"

  write_bbox_json "$LIDAR_EXTRACTION_BBOX_JSON" "${LIDAR_EXTRACTION_BBOX[@]}"
}

download_lidar_tile_index() {
  log "Downloading LiDAR tile index from $LIDAR_TILE_INDEX_WFS_LAYER"
  rm -f "$LIDAR_TILE_INDEX_GPKG"
  ogr2ogr \
    -f GPKG \
    "$LIDAR_TILE_INDEX_GPKG" \
    "$GEOPLATEFORME_WFS_DSN" \
    "$LIDAR_TILE_INDEX_WFS_LAYER" \
    -spat "${LIDAR_EXTRACTION_BBOX[@]}" \
    -spat_srs EPSG:2154 \
    -t_srs EPSG:2154 \
    -select url,id,name \
    -nln "$LIDAR_TILE_INDEX_LOCAL_LAYER"

  LIDAR_TILE_COUNT="$(extract_feature_count "$LIDAR_TILE_INDEX_GPKG" "$LIDAR_TILE_INDEX_LOCAL_LAYER")"
  [[ -n "$LIDAR_TILE_COUNT" ]] || die "could not determine LiDAR tile feature count"
  [[ "$LIDAR_TILE_COUNT" != "0" ]] || die "LiDAR tile query returned no feature"
}

generate_lidar_subset_pipeline() {
  log "Resolving COPC URLs and generating LiDAR subset pipeline"
  python3 "$SCRIPT_DIR/build_pdal_pipeline.py" \
    --tiles "$LIDAR_TILE_INDEX_GPKG" \
    --layer "$LIDAR_TILE_INDEX_LOCAL_LAYER" \
    --bbox "${LIDAR_EXTRACTION_BBOX[@]}" \
    --output-pipeline "$PDAL_PIPELINE_JSON" \
    --laz-output "$LIDAR_SUBSET_LAZ"
}

extract_lidar_subset() {
  log "Extracting LiDAR subset with PDAL"
  pdal pipeline "$PDAL_PIPELINE_JSON"
}

prepare_buildings_for_roofer() {
  log "Preparing building footprints for roofer"
  bash "$SCRIPT_DIR/set_building_attributes.sh" \
    --input "$BUILDINGS_GPKG" \
    --output "$PREPARED_BUILDINGS_GPKG" \
    --layer "$BUILDINGS_LOCAL_LAYER" \
    --ground-min-field altitude_minimale_sol \
    --ground-max-field altitude_maximale_sol \
    --roof-min-field altitude_minimale_toit \
    --roof-max-field altitude_maximale_toit \
    --height-field hauteur \
    --verbose 0
}

run_roofer() {
  log "Running roofer"
  roofer \
    -j "$ROOFER_JOBS" \
    --polygon-source-layer "$BUILDINGS_LOCAL_LAYER" \
    --srs EPSG:2154 \
    --h-terrain-strategy buffer_user \
    --h-terrain-attribute altitude_minimale_sol \
    --h-roof-attribute altitude_maximale_toit \
    --id-attribute cleabs \
    "$LIDAR_SUBSET_LAZ" \
    "$PREPARED_BUILDINGS_GPKG" \
    "$ROOFER_OUTPUT_DIR"
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

main() {
  local workflow_started_at=""

  init_defaults
  parse_args "$@"
  validate_args
  configure_runtime_environment
  initialize_output_paths

  workflow_started_at="$SECONDS"
  run_timed_step "Download building footprints" download_building_footprints
  run_timed_step "Prepare LiDAR extraction bbox" prepare_lidar_extraction_bbox
  run_timed_step "Download LiDAR tile index" download_lidar_tile_index
  run_timed_step "Generate LiDAR subset pipeline" generate_lidar_subset_pipeline
  run_timed_step "Extract LiDAR subset" extract_lidar_subset
  run_timed_step "Prepare buildings for roofer" prepare_buildings_for_roofer
  run_timed_step "Run roofer" run_roofer

  log "Workflow completed"
  print_timing_summary "$((SECONDS - workflow_started_at))"
}

main "$@"

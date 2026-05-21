#!/usr/bin/env bash

set -euo pipefail

# -----------------------------------------------------------------------------
# Runtime configuration
# -----------------------------------------------------------------------------

export PATH="/opt/3dbag-pipeline/tools/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WFS_URL="WFS:https://data.geopf.fr/wfs/ows?SERVICE=WFS&VERSION=2.0.0&SRSNAME=EPSG:2154"
BUILDINGS_SOURCE_LAYER="BDTOPO_V3:batiment"
BUILDINGS_LAYER_NAME="buildings"
LIDAR_SOURCE_LAYER="IGNF_NUAGES-DE-POINTS-LIDAR-HD:dalle"
LIDAR_LAYER_NAME="lidar_tiles"

# -----------------------------------------------------------------------------
# Help and utility functions
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  run_workflow.sh --bbox xmin ymin xmax ymax [--buffer meters] [--out path] [--jobs n]

Options:
  --bbox    Required input bounding box in EPSG:2154
  --buffer  Optional buffer in meters, default: 10
  --out     Required output directory, cleared on each run
  --jobs    Optional roofer thread count, default: nproc - 1 (min 0)
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

log() {
  echo "[workflow] $*"
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

  cpu_count="$(nproc)"
  if (( cpu_count > 0 )); then
    echo $((cpu_count - 1))
  else
    echo 0
  fi
}

clear_output_dir() {
  local current_dir resolved_out_dir
  local entries=()

  current_dir="$(pwd -P)"
  resolved_out_dir="$(cd "$OUT_DIR" && pwd -P)"

  if [[ "$resolved_out_dir" == "/" || "$resolved_out_dir" == "$current_dir" ]]; then
    die "--out must not resolve to $resolved_out_dir when cleaning output"
  fi

  shopt -s dotglob nullglob
  entries=("$OUT_DIR"/*)
  shopt -u dotglob nullglob

  if (( ${#entries[@]} > 0 )); then
    rm -rf -- "${entries[@]}"
  fi
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
# Default arguments
# -----------------------------------------------------------------------------

BBOX=()
BUFFER="10"
OUT_DIR=""
JOBS="$(detect_default_jobs)"

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bbox)
      shift
      [[ $# -ge 4 ]] || die "--bbox requires four values"
      BBOX=("$1" "$2" "$3" "$4")
      shift 4
      ;;
    --buffer)
      shift
      [[ $# -ge 1 ]] || die "--buffer requires a value"
      BUFFER="$1"
      shift
      ;;
    --out)
      shift
      [[ $# -ge 1 ]] || die "--out requires a path"
      OUT_DIR="$1"
      shift
      ;;
    --jobs)
      shift
      [[ $# -ge 1 ]] || die "--jobs requires a value"
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
# Validation and environment setup
# -----------------------------------------------------------------------------

[[ ${#BBOX[@]} -eq 4 ]] || die "--bbox is required"
[[ -n "$OUT_DIR" ]] || die "--out is required"

for value in "${BBOX[@]}" "$BUFFER"; do
  is_number "$value" || die "non-numeric value detected: $value"
done

[[ "$JOBS" =~ ^[0-9]+$ ]] || die "--jobs must be an integer >= 0"
validate_bbox "${BBOX[0]}" "${BBOX[1]}" "${BBOX[2]}" "${BBOX[3]}"

configure_proxy_env
check_required_commands

export OGR_WFS_PAGING_ALLOWED=ON
export OGR_WFS_PAGE_SIZE=4500

mkdir -p "$OUT_DIR"
log "Clearing output directory $OUT_DIR"
clear_output_dir

# -----------------------------------------------------------------------------
# Output paths and derived inputs
# -----------------------------------------------------------------------------

BUILDINGS_GPKG="$OUT_DIR/buildings.gpkg"
BUILDING_BBOX_JSON="$OUT_DIR/building_bbox.json"
BUFFERED_BBOX_JSON="$OUT_DIR/buffered_bbox.json"
LIDAR_TILES_GPKG="$OUT_DIR/lidar_tiles.gpkg"
PDAL_PIPELINE_JSON="$OUT_DIR/pdal_pipeline.json"
LIDAR_SUBSET_LAZ="$OUT_DIR/lidar_subset.laz"
ROOFER_OUTPUT_DIR="$OUT_DIR/roofer_output"

INPUT_XMIN="${BBOX[0]}"
INPUT_YMIN="${BBOX[1]}"
INPUT_XMAX="${BBOX[2]}"
INPUT_YMAX="${BBOX[3]}"

# -----------------------------------------------------------------------------
# Building download and extent preparation
# -----------------------------------------------------------------------------

log "Downloading buildings from $BUILDINGS_SOURCE_LAYER"
rm -f "$BUILDINGS_GPKG"
ogr2ogr \
  -f GPKG \
  "$BUILDINGS_GPKG" \
  "$WFS_URL" \
  "$BUILDINGS_SOURCE_LAYER" \
  -spat "$INPUT_XMIN" "$INPUT_YMIN" "$INPUT_XMAX" "$INPUT_YMAX" \
  -spat_srs EPSG:2154 \
  -t_srs EPSG:2154 \
  -dim 2 \
  -nlt MULTIPOLYGON \
  -nln "$BUILDINGS_LAYER_NAME"

BUILDING_COUNT="$(extract_feature_count "$BUILDINGS_GPKG" "$BUILDINGS_LAYER_NAME")"
[[ -n "$BUILDING_COUNT" ]] || die "could not determine building feature count"
[[ "$BUILDING_COUNT" != "0" ]] || die "building query returned no features"

read -r BUILDING_XMIN BUILDING_YMIN BUILDING_XMAX BUILDING_YMAX <<<"$(extract_extent "$BUILDINGS_GPKG" "$BUILDINGS_LAYER_NAME")"
write_bbox_json "$BUILDING_BBOX_JSON" "$BUILDING_XMIN" "$BUILDING_YMIN" "$BUILDING_XMAX" "$BUILDING_YMAX"

read -r BUFFERED_XMIN BUFFERED_YMIN BUFFERED_XMAX BUFFERED_YMAX <<<"$(
  awk \
    -v xmin="$BUILDING_XMIN" \
    -v ymin="$BUILDING_YMIN" \
    -v xmax="$BUILDING_XMAX" \
    -v ymax="$BUILDING_YMAX" \
    -v buffer="$BUFFER" \
    'BEGIN {
      printf "%.6f %.6f %.6f %.6f\n", xmin - buffer, ymin - buffer, xmax + buffer, ymax + buffer
    }'
)"
write_bbox_json "$BUFFERED_BBOX_JSON" "$BUFFERED_XMIN" "$BUFFERED_YMIN" "$BUFFERED_XMAX" "$BUFFERED_YMAX"

# -----------------------------------------------------------------------------
# LiDAR tile download
# -----------------------------------------------------------------------------

log "Downloading LiDAR tile footprints from $LIDAR_SOURCE_LAYER"
rm -f "$LIDAR_TILES_GPKG"
ogr2ogr \
  -f GPKG \
  "$LIDAR_TILES_GPKG" \
  "$WFS_URL" \
  "$LIDAR_SOURCE_LAYER" \
  -spat "$BUFFERED_XMIN" "$BUFFERED_YMIN" "$BUFFERED_XMAX" "$BUFFERED_YMAX" \
  -spat_srs EPSG:2154 \
  -t_srs EPSG:2154 \
  -nln "$LIDAR_LAYER_NAME"

LIDAR_COUNT="$(extract_feature_count "$LIDAR_TILES_GPKG" "$LIDAR_LAYER_NAME")"
[[ -n "$LIDAR_COUNT" ]] || die "could not determine LiDAR tile feature count"
[[ "$LIDAR_COUNT" != "0" ]] || die "LiDAR tile query returned no features"

# -----------------------------------------------------------------------------
# PDAL pipeline preparation
# -----------------------------------------------------------------------------

log "Resolving COPC URLs and writing PDAL pipeline"
python3 "$SCRIPT_DIR/build_pdal_pipeline.py" \
  --tiles "$LIDAR_TILES_GPKG" \
  --bbox "$BUFFERED_XMIN" "$BUFFERED_YMIN" "$BUFFERED_XMAX" "$BUFFERED_YMAX" \
  --output-pipeline "$PDAL_PIPELINE_JSON" \
  --laz-output "$LIDAR_SUBSET_LAZ"

mkdir -p "$ROOFER_OUTPUT_DIR"

# -----------------------------------------------------------------------------
# Workflow execution
# -----------------------------------------------------------------------------

log "Running PDAL pipeline"
pdal pipeline "$PDAL_PIPELINE_JSON"

log "Attribute completion"

POSTPROCESS_GPKG="$OUT_DIR/buildings_cleaned.gpkg"

bash "$SCRIPT_DIR/set_building_attributes.sh" \
  --input "$BUILDINGS_GPKG" \
  --output "$POSTPROCESS_GPKG" \
  --layer "$BUILDINGS_LAYER_NAME"\
  --ground-min-field altitude_minimale_sol \
  --ground-max-field altitude_maximale_sol \
  --roof-min-field altitude_minimale_toit \
  --roof-max-field altitude_maximale_toit \
  --height-field hauteur \
  --verbose 1

log "Running roofer"

roofer \
  -j "$JOBS" \
  --polygon-source-layer "$BUILDINGS_LAYER_NAME" \
  --srs EPSG:2154 \
  --h-terrain-strategy buffer_user \
  --h-terrain-attribute altitude_minimale_sol \
  --h-roof-attribute altitude_maximale_toit \
  --id-attribute cleabs \
  "$LIDAR_SUBSET_LAZ" \
  "$POSTPROCESS_GPKG" \
  "$ROOFER_OUTPUT_DIR"


log "Workflow completed"

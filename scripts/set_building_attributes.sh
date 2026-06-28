#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# set_building_attributes.sh
#
# Completes missing ground/roof altitudes and building height in a GPKG by
# deriving each value from the others, and drops features with NULL geometry.
# -----------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------

print_help() {
    cat << EOF
Usage:
  $SCRIPT_NAME --input INPUT.gpkg --output OUTPUT.gpkg [options]

Arguments:
  --input PATH               Input GPKG file (read-only)
  --output PATH              Output GPKG file (created/overwritten)
  --layer NAME               Layer name (default: buildings)
  --ground-min-field NAME    Ground minimum altitude field (default: altitude_minimale_sol)
  --ground-max-field NAME    Ground maximum altitude field (default: altitude_maximale_sol)
  --roof-min-field NAME      Roof minimum altitude field (default: altitude_minimale_toit)
  --roof-max-field NAME      Roof maximum altitude field (default: altitude_maximale_toit)
  --height-field NAME        Height field (default: hauteur)
  --verbose LEVEL            Verbosity level: 0, 1, 2 (default: 1)
  -h, --help                 Show this help

Verbosity:
  0   Quiet mode
  1   Main steps + clear summary
  2   Detailed diagnostics + SQL verification + full summary

Example:
  $SCRIPT_NAME \\
      --input buildings.gpkg \\
      --output buildings_postprocessed.gpkg \\
      --layer buildings \\
      --ground-min-field altitude_minimale_sol \\
      --ground-max-field altitude_maximale_sol \\
      --roof-min-field altitude_minimale_toit \\
      --roof-max-field altitude_maximale_toit \\
      --height-field hauteur \\
      --verbose 2
EOF
}

# -----------------------------------------------------------------------------
# Configuration (defaults, overridable via CLI options)
# -----------------------------------------------------------------------------

INPUT_GPKG=""
OUTPUT_GPKG=""
OUTPUT_LAYER_NAME="buildings"
GROUND_MIN_FIELD="altitude_minimale_sol"
GROUND_MAX_FIELD="altitude_maximale_sol"
ROOF_MIN_FIELD="altitude_minimale_toit"
ROOF_MAX_FIELD="altitude_maximale_toit"
HEIGHT_FIELD="hauteur"
VERBOSE=1

# -----------------------------------------------------------------------------
# Logging & formatting helpers
# -----------------------------------------------------------------------------

log() {
    local level="$1"
    shift
    if [[ "$VERBOSE" -ge "$level" ]]; then
        echo "$@" >&2
    fi
}

die() {
    echo "❌ $*" >&2
    exit 1
}

normalize_int() {
    local value="${1:-0}"
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    printf '%s\n' "$value"
}

# Prints an aligned "label : value" row for the summary.
summary_row() {
    printf '   %-42s : %s\n' "$1" "$2"
}

# -----------------------------------------------------------------------------
# GPKG inspection helpers
# -----------------------------------------------------------------------------

table_exists_in_file() {
    local file="$1" table="$2"
    [[ -n "$(sqlite3 "$file" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';" 2>/dev/null)" ]]
}

get_fields() {
    local file="$1" table="$2"
    sqlite3 "$file" "SELECT name FROM pragma_table_info('$table');" 2>/dev/null || true
}

has_field() {
    printf '%s\n' "$FIELDS" | grep -Fxq -- "$1"
}

# -----------------------------------------------------------------------------
# Diagnostics (verbose level 2)
# -----------------------------------------------------------------------------

# Prints <title> then the indented result of <sql> on stderr (verbose 2 only).
debug_query() {
    local file="$1" title="$2" sql="$3"
    log 2 "$title"
    sqlite3 -header -column "$file" "$sql" 2>&1 | sed 's/^/   /' >&2 || true
}

debug_table_schema() {
    local file="$1" table="$2"
    debug_query "$file" "→ SQLite schema for table '$table':" ".schema \"$table\""
    debug_query "$file" "→ PRAGMA table_info('$table'):" "PRAGMA table_info(\"$table\");"
}

debug_null_counts() {
    local file="$1" table="$2"
    debug_query "$file" "→ NULL diagnostics:" "
        SELECT
            COUNT(*) AS total,
            SUM(CASE WHEN \"$HEIGHT_FIELD\" IS NULL THEN 1 ELSE 0 END) AS null_height,
            SUM(CASE WHEN \"$GROUND_MIN_FIELD\" IS NULL THEN 1 ELSE 0 END) AS null_ground_min,
            SUM(CASE WHEN \"$GROUND_MAX_FIELD\" IS NULL THEN 1 ELSE 0 END) AS null_ground_max,
            SUM(CASE WHEN \"$ROOF_MIN_FIELD\" IS NULL THEN 1 ELSE 0 END) AS null_roof_min,
            SUM(CASE WHEN \"$ROOF_MAX_FIELD\" IS NULL THEN 1 ELSE 0 END) AS null_roof_max
        FROM \"$table\";"
}

debug_sample_rows() {
    local file="$1" table="$2"
    debug_query "$file" "→ Sample rows:" "
        SELECT
            \"fid\",
            \"$HEIGHT_FIELD\",
            \"$GROUND_MIN_FIELD\",
            \"$ROOF_MIN_FIELD\",
            \"$ROOF_MAX_FIELD\",
            \"$GROUND_MAX_FIELD\"
        FROM \"$table\"
        LIMIT 12;"
}

debug_remaining_missing() {
    local file="$1" table="$2"
    debug_query "$file" "→ Remaining incomplete rows:" "
        SELECT
            \"fid\",
            \"$HEIGHT_FIELD\",
            \"$GROUND_MIN_FIELD\",
            \"$GROUND_MAX_FIELD\",
            \"$ROOF_MIN_FIELD\",
            \"$ROOF_MAX_FIELD\"
        FROM \"$table\"
        WHERE \"$ROOF_MIN_FIELD\" IS NULL
           OR \"$ROOF_MAX_FIELD\" IS NULL
           OR \"$HEIGHT_FIELD\" IS NULL
           OR \"$GROUND_MIN_FIELD\" IS NULL
           OR \"$GROUND_MAX_FIELD\" IS NULL
        ORDER BY \"fid\";"
}

# -----------------------------------------------------------------------------
# Geometry detection & SQL update helpers
# -----------------------------------------------------------------------------

# Returns the geometry column name from the GPKG metadata, or empty if none.
detect_geometry_column() {
    local file="$1" table="$2"
    sqlite3 "$file" "SELECT column_name FROM gpkg_geometry_columns WHERE table_name='$table' LIMIT 1;" 2>/dev/null || true
}

# Runs <update_sql> via ogrinfo (GDAL's SQLite dialect, required so the GPKG
# RTree triggers can resolve ST_IsEmpty/ST_MinX & co.). The UPDATE touches
# exactly the rows matched by <count_sql> (same WHERE), so count_before is the
# number of rows it will change — no need to recount afterwards.
run_sql_update() {
    local file="$1" label="$2" count_sql="$3" update_sql="$4"

    local updated sql_output sql_exit
    updated="$(sqlite3 "$file" "$count_sql" 2>/dev/null || echo 0)"
    updated="$(normalize_int "$updated")"

    if [[ "$updated" -eq 0 ]]; then
        log 2 "   ℹ️ $label: 0 row to update"
        printf '%s\n' "0"
        return 0
    fi

    sql_exit=0
    sql_output="$(ogrinfo "$file" -dialect SQLite -sql "$update_sql" 2>&1)" || sql_exit=$?

    if [[ "$sql_exit" -ne 0 ]]; then
        log 0 "   ⚠️ $label skipped"
        if [[ "$VERBOSE" -ge 2 ]]; then
            log 2 "      ogrinfo error:"
            printf '%s\n' "$sql_output" | sed 's/^/      /' >&2
            log 2 "      SQL: $update_sql"
        fi
        printf '%s\n' "0"
        return 1
    fi

    log 2 "   ✔ $label: $updated row(s) updated"
    printf '%s\n' "$updated"
}

# fill_field_if_null <target> <expr> <operand>...
# Fills <target> with <expr> where <target> IS NULL and every <operand> IS NOT NULL.
# Builds the shared WHERE clause once for both the count and the update.
fill_field_if_null() {
    local target="$1" expr="$2"
    shift 2

    local where="\"$target\" IS NULL" op
    for op in "$@"; do
        where+=" AND \"$op\" IS NOT NULL"
    done

    run_sql_update "$OUTPUT_GPKG" "$target from $expr" \
        "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE $where;" \
        "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"$target\" = $expr WHERE $where;"
}

# -----------------------------------------------------------------------------
# Per-run state (populated by the steps, summed up by print_summary)
# -----------------------------------------------------------------------------

GEOM_COLUMN=""
FIELDS=""

# Set to 1 by any step whose SQL update/delete failed, so main can exit non-zero
# even though a single failure does not abort the rest of the run.
HAD_ERRORS=0

UPDATED_NULL_GEOM=0
UPDATED_GROUND_MAX=0
UPDATED_GROUND_MIN=0
UPDATED_ROOF_MAX=0
UPDATED_ROOF_MIN=0
UPDATED_HEIGHT=0
UPDATED_RECON_ROOF_MAX=0
UPDATED_RECON_ROOF_MIN=0
UPDATED_RECON_GROUND_MAX=0
UPDATED_RECON_GROUND_MIN=0

# -----------------------------------------------------------------------------
# Setup: argument parsing, validation, output preparation
# -----------------------------------------------------------------------------

parse_args() {
    local var
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)          print_help; exit 0 ;;
            --input)            var=INPUT_GPKG ;;
            --output)           var=OUTPUT_GPKG ;;
            --layer)            var=OUTPUT_LAYER_NAME ;;
            --ground-min-field) var=GROUND_MIN_FIELD ;;
            --ground-max-field) var=GROUND_MAX_FIELD ;;
            --roof-min-field)   var=ROOF_MIN_FIELD ;;
            --roof-max-field)   var=ROOF_MAX_FIELD ;;
            --height-field)     var=HEIGHT_FIELD ;;
            --verbose)          var=VERBOSE ;;
            *)
                echo "❌ Unknown argument: $1" >&2
                echo >&2
                print_help
                exit 1
                ;;
        esac
        [[ $# -ge 2 ]] || die "Missing value for $1"
        printf -v "$var" '%s' "$2"
        shift 2
    done
}

validate_args() {
    [[ "$VERBOSE" =~ ^[012]$ ]] || die "Invalid --verbose value: $VERBOSE (expected 0, 1, or 2)"
    [[ -n "$INPUT_GPKG" ]] || die "Missing required argument: --input"
    [[ -n "$OUTPUT_GPKG" ]] || die "Missing required argument: --output"
    [[ -f "$INPUT_GPKG" ]] || die "Missing input GPKG: $INPUT_GPKG"

    if [[ "$INPUT_GPKG" == "$OUTPUT_GPKG" ]] \
       || { [[ -e "$OUTPUT_GPKG" ]] && [[ "$INPUT_GPKG" -ef "$OUTPUT_GPKG" ]]; }; then
        die "--input and --output must be different files: $OUTPUT_GPKG"
    fi

    command -v ogrinfo >/dev/null 2>&1 || die "ogrinfo not found"
    command -v ogr2ogr >/dev/null 2>&1 || die "ogr2ogr not found"
    command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 not found"
}

prepare_output() {
    log 1 "📥 Reading source: $INPUT_GPKG"
    log 1 "📤 Writing output: $OUTPUT_GPKG"

    if ! table_exists_in_file "$INPUT_GPKG" "$OUTPUT_LAYER_NAME"; then
        die "Layer '$OUTPUT_LAYER_NAME' not found in $INPUT_GPKG"
    fi

    rm -f "$OUTPUT_GPKG"

    log 1 "→ Copying layer to output GPKG..."
    local copy_output
    if ! copy_output="$(ogr2ogr \
        -f GPKG \
        -nln "$OUTPUT_LAYER_NAME" \
        "$OUTPUT_GPKG" \
        "$INPUT_GPKG" \
        "$OUTPUT_LAYER_NAME" 2>&1)"; then
        printf '%s\n' "$copy_output" | sed 's/^/   /' >&2
        die "Failed to create output GPKG from input layer"
    fi

    FIELDS="$(get_fields "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME")"
    [[ -n "$FIELDS" ]] || die "could not read field list from layer '$OUTPUT_LAYER_NAME'"

    if [[ "$VERBOSE" -ge 2 ]]; then
        debug_table_schema "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME"
        debug_null_counts "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME"
        debug_sample_rows "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME"
    fi

    GEOM_COLUMN="$(detect_geometry_column "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME")"
    log 2 "→ Geometry column detected: ${GEOM_COLUMN:-<none>}"
}

# -----------------------------------------------------------------------------
# Cleaning steps
# -----------------------------------------------------------------------------

# Step 0 - Drop features with a NULL geometry.
# Should never happen in practice with a well-formed input; kept as a defensive
# guard so later steps can assume every remaining feature has a geometry.
step_remove_null_geometries() {
    log 1 "→ Removing NULL geometries (if any)..."

    if [[ -n "$GEOM_COLUMN" ]]; then
        UPDATED_NULL_GEOM="$(sqlite3 "$OUTPUT_GPKG" "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"$GEOM_COLUMN\" IS NULL;" 2>/dev/null || echo 0)"
        UPDATED_NULL_GEOM="$(normalize_int "$UPDATED_NULL_GEOM")"

        if [[ "$UPDATED_NULL_GEOM" -gt 0 ]]; then
            if ogrinfo "$OUTPUT_GPKG" -dialect SQLite -sql "DELETE FROM \"$OUTPUT_LAYER_NAME\" WHERE \"$GEOM_COLUMN\" IS NULL;" >/dev/null 2>&1; then
                log 2 "   ✔ Removed $UPDATED_NULL_GEOM feature(s) with NULL geometry"
            else
                log 0 "   ⚠️ Failed to remove NULL geometries"
                UPDATED_NULL_GEOM=0
                HAD_ERRORS=1
            fi
        else
            log 2 "   ℹ️ No NULL geometry found"
        fi
    else
        log 2 "   ℹ️ No geometry column detected, skipping NULL geometry cleanup"
    fi
}

# Step 1 - If only one ground altitude (min or max) is set, copy it into the
# other one (assume flat ground: min == max).
step_fill_ground_altitudes() {
    log 1 "→ Filling missing ground altitudes..."
    if has_field "$GROUND_MAX_FIELD" && has_field "$GROUND_MIN_FIELD"; then
        UPDATED_GROUND_MAX="$(fill_field_if_null "$GROUND_MAX_FIELD" "\"$GROUND_MIN_FIELD\"" "$GROUND_MIN_FIELD")" || HAD_ERRORS=1
        UPDATED_GROUND_MIN="$(fill_field_if_null "$GROUND_MIN_FIELD" "\"$GROUND_MAX_FIELD\"" "$GROUND_MAX_FIELD")" || HAD_ERRORS=1
    else
        log 1 "⚠️ Missing ground altitude fields → skip"
    fi
}

# Step 2 - If only one roof altitude (min or max) is set, copy it into the
# other one (assume flat roof: min == max).
step_fill_roof_altitudes() {
    log 1 "→ Filling missing roof altitudes..."
    if has_field "$ROOF_MAX_FIELD" && has_field "$ROOF_MIN_FIELD"; then
        UPDATED_ROOF_MAX="$(fill_field_if_null "$ROOF_MAX_FIELD" "\"$ROOF_MIN_FIELD\"" "$ROOF_MIN_FIELD")" || HAD_ERRORS=1
        UPDATED_ROOF_MIN="$(fill_field_if_null "$ROOF_MIN_FIELD" "\"$ROOF_MAX_FIELD\"" "$ROOF_MAX_FIELD")" || HAD_ERRORS=1
    else
        log 1 "⚠️ Missing roof altitude fields → skip"
    fi
}

# Step 3 - If height attribute is missing, compute it as the full vertical extent of
# the building: highest roof point (roof_max) minus lowest ground point
# (ground_min). Only runs, of course, when both of those altitudes are known.
step_compute_height() {
    log 1 "→ Calculating $HEIGHT_FIELD..."
    if has_field "$HEIGHT_FIELD" && has_field "$ROOF_MAX_FIELD" && has_field "$GROUND_MIN_FIELD"; then
        UPDATED_HEIGHT="$(fill_field_if_null "$HEIGHT_FIELD" \
            "ROUND(\"$ROOF_MAX_FIELD\" - \"$GROUND_MIN_FIELD\", 3)" \
            "$ROOF_MAX_FIELD" "$GROUND_MIN_FIELD")" || HAD_ERRORS=1
    else
        log 1 "⚠️ Missing fields for height computation → skip"
    fi
}

# Step 4 - If roof altitude attribute is missing, rebuild it by raising the matching
# ground altitude by the height: roof_max = ground_max + height, and likewise
# roof_min = ground_min + height. Only runs when the height and the matching
# ground altitude are known.
step_reconstruct_roof() {
    log 1 "→ Reconstructing roof altitudes..."
    if has_field "$HEIGHT_FIELD" && has_field "$GROUND_MAX_FIELD" && has_field "$GROUND_MIN_FIELD"; then
        if has_field "$ROOF_MAX_FIELD"; then
            UPDATED_RECON_ROOF_MAX="$(fill_field_if_null "$ROOF_MAX_FIELD" \
                "ROUND(\"$GROUND_MAX_FIELD\" + \"$HEIGHT_FIELD\", 3)" \
                "$GROUND_MAX_FIELD" "$HEIGHT_FIELD")" || HAD_ERRORS=1
        fi
        if has_field "$ROOF_MIN_FIELD"; then
            UPDATED_RECON_ROOF_MIN="$(fill_field_if_null "$ROOF_MIN_FIELD" \
                "ROUND(\"$GROUND_MIN_FIELD\" + \"$HEIGHT_FIELD\", 3)" \
                "$GROUND_MIN_FIELD" "$HEIGHT_FIELD")" || HAD_ERRORS=1
        fi
    else
        log 1 "⚠️ Missing fields for roof reconstruction → skip"
    fi
}

# Step 5 - If ground altitude attribute is missing, rebuild it by lowering the matching
# roof altitude by the height: ground_max = roof_max - height, and likewise
# ground_min = roof_min - height. Only runs when the height and the matching
# roof altitude are known.
step_backfill_ground() {
    log 1 "→ Backfilling ground altitudes..."
    if has_field "$HEIGHT_FIELD" && has_field "$ROOF_MAX_FIELD" && has_field "$ROOF_MIN_FIELD"; then
        if has_field "$GROUND_MAX_FIELD"; then
            UPDATED_RECON_GROUND_MAX="$(fill_field_if_null "$GROUND_MAX_FIELD" \
                "ROUND(\"$ROOF_MAX_FIELD\" - \"$HEIGHT_FIELD\", 3)" \
                "$ROOF_MAX_FIELD" "$HEIGHT_FIELD")" || HAD_ERRORS=1
        fi
        if has_field "$GROUND_MIN_FIELD"; then
            UPDATED_RECON_GROUND_MIN="$(fill_field_if_null "$GROUND_MIN_FIELD" \
                "ROUND(\"$ROOF_MIN_FIELD\" - \"$HEIGHT_FIELD\", 3)" \
                "$ROOF_MIN_FIELD" "$HEIGHT_FIELD")" || HAD_ERRORS=1
        fi
    else
        log 1 "⚠️ Missing fields for ground reconstruction → skip"
    fi
}

# -----------------------------------------------------------------------------
# Reporting
# -----------------------------------------------------------------------------

post_diagnostics() {
    if [[ "$VERBOSE" -ge 2 ]]; then
        log 2 "→ Post-update diagnostics:"
        debug_null_counts "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME"
        debug_sample_rows "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME"
        debug_remaining_missing "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME"
    fi
}

print_summary() {
    local total_values missing step0 step1 step2 step3 step4 step5

    step0=$UPDATED_NULL_GEOM
    step1=$((UPDATED_GROUND_MAX + UPDATED_GROUND_MIN))
    step2=$((UPDATED_ROOF_MAX + UPDATED_ROOF_MIN))
    step3=$UPDATED_HEIGHT
    step4=$((UPDATED_RECON_ROOF_MAX + UPDATED_RECON_ROOF_MIN))
    step5=$((UPDATED_RECON_GROUND_MAX + UPDATED_RECON_GROUND_MIN))

    total_values=$(( step0 + step1 + step2 + step3 + step4 + step5 ))

    missing="$(sqlite3 "$OUTPUT_GPKG" \
        "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\"
         WHERE \"$HEIGHT_FIELD\" IS NULL
            OR \"$GROUND_MIN_FIELD\" IS NULL
            OR \"$GROUND_MAX_FIELD\" IS NULL
            OR \"$ROOF_MIN_FIELD\" IS NULL
            OR \"$ROOF_MAX_FIELD\" IS NULL;" 2>/dev/null || echo 0)"
    missing="$(normalize_int "$missing")"

    if [[ "$VERBOSE" -ge 1 ]]; then
        echo
        echo "✅ Postprocessing done"
        summary_row "Input kept unchanged" "$INPUT_GPKG"
        summary_row "Output GPKG updated" "$OUTPUT_GPKG"
        echo
        echo "Attribute values updated by step:"
        summary_row "Step 0 - NULL geometries removed" "$step0"
        summary_row "Step 1 - Ground altitudes completed" "$step1"
        summary_row "Step 2 - Roof altitudes completed" "$step2"
        summary_row "Step 3 - Height computed" "$step3"
        summary_row "Step 4 - Roof reconstructed" "$step4"
        summary_row "Step 5 - Ground backfilled" "$step5"
        echo
        echo "Attribute values updated by field:"
        summary_row "geometry removed (NULL geometry rows)" "$UPDATED_NULL_GEOM"
        summary_row "$GROUND_MAX_FIELD" "$UPDATED_GROUND_MAX"
        summary_row "$GROUND_MIN_FIELD" "$UPDATED_GROUND_MIN"
        summary_row "$ROOF_MAX_FIELD" "$UPDATED_ROOF_MAX"
        summary_row "$ROOF_MIN_FIELD" "$UPDATED_ROOF_MIN"
        summary_row "$HEIGHT_FIELD" "$UPDATED_HEIGHT"
        summary_row "$ROOF_MAX_FIELD (reconstructed)" "$UPDATED_RECON_ROOF_MAX"
        summary_row "$ROOF_MIN_FIELD (reconstructed)" "$UPDATED_RECON_ROOF_MIN"
        summary_row "$GROUND_MAX_FIELD (backfilled)" "$UPDATED_RECON_GROUND_MAX"
        summary_row "$GROUND_MIN_FIELD (backfilled)" "$UPDATED_RECON_GROUND_MIN"
        echo
        echo "Totals:"
        summary_row "Total attribute values updated" "$total_values"
        summary_row "Buildings with >=1 NULL attribute" "$missing"
    fi
}

# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"
    validate_args
    prepare_output

    step_remove_null_geometries
    step_fill_ground_altitudes
    step_fill_roof_altitudes
    step_compute_height
    step_reconstruct_roof
    step_backfill_ground

    post_diagnostics
    print_summary

    # Make partial/silent failures visible to callers: the run does as much as it
    # can, but if any step's update failed, the output is incomplete -> exit 1.
    if [[ "$HAD_ERRORS" -ne 0 ]]; then
        log 0 "⚠️ Completed with errors: some updates failed, output may be incomplete."
        exit 1
    fi
}

main "$@"

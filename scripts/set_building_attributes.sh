#!/usr/bin/env bash
set -euo pipefail

# ===============================
# set_building_attributes.sh
# ===============================

SCRIPT_NAME="$(basename "$0")"

print_help() {
    cat << EOF
Usage:
  $SCRIPT_NAME --input INPUT.gpkg --output OUTPUT.gpkg [options]

Arguments:
  --input PATH               Input GPKG file (read-only)
  --output PATH              Output GPKG file (created/overwritten)
  --layer NAME               Layer name (default: BUILDINGS)
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

INPUT_GPKG=""
OUTPUT_GPKG=""
OUTPUT_LAYER_NAME="buildings"
GROUND_MIN_FIELD="altitude_minimale_sol"
GROUND_MAX_FIELD="altitude_maximale_sol"
ROOF_MIN_FIELD="altitude_minimale_toit"
ROOF_MAX_FIELD="altitude_maximale_toit"
HEIGHT_FIELD="hauteur"
VERBOSE=1

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

table_exists_in_file() {
    local file="$1"
    local table="$2"
    sqlite3 "$file" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';" 2>/dev/null | grep -qx "$table"
}

get_fields() {
    local file="$1"
    ogrinfo -al -so "$file" "$OUTPUT_LAYER_NAME" 2>/dev/null | \
        awk -F ':' '/^[ ]*[A-Za-z0-9_]+/ {
            gsub(/^ +| +$/, "", $1)
            print $1
        }'
}

FIELDS=""

has_field() {
    echo "$FIELDS" | grep -qw "$1"
}

count_distinct_objects() {
    local file="$1"
    local sql="$2"
    local result
    result="$(sqlite3 "$file" "$sql" 2>/dev/null || echo 0)"
    result="$(normalize_int "$result")"
    printf '%s\n' "$result"
}

debug_table_schema() {
    local file="$1"
    local table="$2"

    log 2 "→ SQLite schema for table '$table':"
    sqlite3 "$file" ".schema \"$table\"" 2>&1 | sed 's/^/   /' >&2 || true

    log 2 "→ PRAGMA table_info('$table'):"
    sqlite3 -header -column "$file" "PRAGMA table_info(\"$table\");" 2>&1 | sed 's/^/   /' >&2 || true
}

debug_null_counts() {
    local file="$1"
    local table="$2"

    log 2 "→ NULL diagnostics:"
    sqlite3 -header -column "$file" "
        SELECT
            COUNT(*) AS total,
            SUM(CASE WHEN \"$HEIGHT_FIELD\" IS NULL THEN 1 ELSE 0 END) AS null_height,
            SUM(CASE WHEN \"$GROUND_MIN_FIELD\" IS NULL THEN 1 ELSE 0 END) AS null_ground_min,
            SUM(CASE WHEN \"$GROUND_MAX_FIELD\" IS NULL THEN 1 ELSE 0 END) AS null_ground_max,
            SUM(CASE WHEN \"$ROOF_MIN_FIELD\" IS NULL THEN 1 ELSE 0 END) AS null_roof_min,
            SUM(CASE WHEN \"$ROOF_MAX_FIELD\" IS NULL THEN 1 ELSE 0 END) AS null_roof_max
        FROM \"$table\";
    " 2>&1 | sed 's/^/   /' >&2 || true
}

debug_sample_rows() {
    local file="$1"
    local table="$2"

    log 2 "→ Sample rows:"
    sqlite3 -header -column "$file" "
        SELECT
            \"fid\",
            \"$HEIGHT_FIELD\",
            \"$GROUND_MIN_FIELD\",
            \"$ROOF_MIN_FIELD\",
            \"$ROOF_MAX_FIELD\",
            \"$GROUND_MAX_FIELD\"
        FROM \"$table\"
        LIMIT 12;
    " 2>&1 | sed 's/^/   /' >&2 || true
}

debug_remaining_missing() {
    local file="$1"
    local table="$2"

    log 2 "→ Remaining incomplete rows:"
    sqlite3 -header -column "$file" "
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
        ORDER BY \"fid\";
    " 2>&1 | sed 's/^/   /' >&2 || true
}

detect_geometry_column() {
    local file="$1"
    local table="$2"

    local geom_col=""
    geom_col="$(sqlite3 "$file" "SELECT column_name FROM gpkg_geometry_columns WHERE table_name='$table' LIMIT 1;" 2>/dev/null || true)"
    if [[ -n "$geom_col" ]]; then
        printf '%s\n' "$geom_col"
        return 0
    fi

    for candidate in geom geometry the_geom GEOMETRY geometrie; do
        if sqlite3 "$file" "PRAGMA table_info(\"$table\");" 2>/dev/null | awk -F'|' '{print $2}' | grep -qx "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf '%s\n' ""
}

run_sql_update() {
    local file="$1"
    local label="$2"
    local count_sql="$3"
    local update_sql="$4"

    local count_before count_after updated sql_output sql_exit
    count_before="$(sqlite3 "$file" "$count_sql" 2>/dev/null || echo 0)"
    count_before="$(normalize_int "$count_before")"

    if [[ "$count_before" -eq 0 ]]; then
        log 2 "   ℹ️ $label: 0 row to update"
        printf '%s\n' "0"
        return 0
    fi

    sql_exit=0
    sql_output="$(
        ogrinfo "$file" \
            -dialect SQLite \
            -sql "$update_sql" 2>&1
    )" || sql_exit=$?

    if [[ "$sql_exit" -ne 0 ]]; then
        log 1 "   ⚠️ $label skipped"
        if [[ "$VERBOSE" -ge 2 ]]; then
            log 2 "      ogrinfo error:"
            printf '%s\n' "$sql_output" | sed 's/^/      /' >&2
            log 2 "      SQL: $update_sql"
        fi
        printf '%s\n' "0"
        return 0
    fi

    count_after="$(sqlite3 "$file" "$count_sql" 2>/dev/null || echo 0)"
    count_after="$(normalize_int "$count_after")"

    updated=$((count_before - count_after))
    if [[ "$updated" -lt 0 ]]; then
        updated=0
    fi

    log 2 "   ✔ $label: $updated row(s) updated (before=$count_before, after=$count_after)"
    printf '%s\n' "$updated"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input)
            [[ $# -ge 2 ]] || die "Missing value for --input"
            INPUT_GPKG="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || die "Missing value for --output"
            OUTPUT_GPKG="$2"
            shift 2
            ;;
        --layer)
            [[ $# -ge 2 ]] || die "Missing value for --layer"
            OUTPUT_LAYER_NAME="$2"
            shift 2
            ;;
        --ground-min-field)
            [[ $# -ge 2 ]] || die "Missing value for --ground-min-field"
            GROUND_MIN_FIELD="$2"
            shift 2
            ;;
        --ground-max-field)
            [[ $# -ge 2 ]] || die "Missing value for --ground-max-field"
            GROUND_MAX_FIELD="$2"
            shift 2
            ;;
        --roof-min-field)
            [[ $# -ge 2 ]] || die "Missing value for --roof-min-field"
            ROOF_MIN_FIELD="$2"
            shift 2
            ;;
        --roof-max-field)
            [[ $# -ge 2 ]] || die "Missing value for --roof-max-field"
            ROOF_MAX_FIELD="$2"
            shift 2
            ;;
        --height-field)
            [[ $# -ge 2 ]] || die "Missing value for --height-field"
            HEIGHT_FIELD="$2"
            shift 2
            ;;
        --verbose)
            [[ $# -ge 2 ]] || die "Missing value for --verbose"
            VERBOSE="$2"
            shift 2
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "❌ Unknown argument: $1" >&2
            echo >&2
            print_help
            exit 1
            ;;
    esac
done

[[ "$VERBOSE" =~ ^[012]$ ]] || die "Invalid --verbose value: $VERBOSE (expected 0, 1, or 2)"
[[ -n "$INPUT_GPKG" ]] || die "Missing required argument: --input"
[[ -n "$OUTPUT_GPKG" ]] || die "Missing required argument: --output"
[[ -f "$INPUT_GPKG" ]] || die "Missing input GPKG: $INPUT_GPKG"

command -v ogrinfo >/dev/null 2>&1 || die "ogrinfo not found"
command -v ogr2ogr >/dev/null 2>&1 || die "ogr2ogr not found"
command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 not found"

log 1 "📥 Reading source: $INPUT_GPKG"
log 1 "📤 Writing output: $OUTPUT_GPKG"

if ! table_exists_in_file "$INPUT_GPKG" "$OUTPUT_LAYER_NAME"; then
    die "Layer '$OUTPUT_LAYER_NAME' not found in $INPUT_GPKG"
fi

rm -f "$OUTPUT_GPKG"

log 1 "→ Copying layer to output GPKG..."

ogr2ogr \
    -f GPKG \
    -nln "$OUTPUT_LAYER_NAME" \
    "$OUTPUT_GPKG" \
    "$INPUT_GPKG" \
    "$OUTPUT_LAYER_NAME" \
    >/dev/null 2>&1 || die "Failed to create output GPKG from input layer"

if ! table_exists_in_file "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME"; then
    die "Layer '$OUTPUT_LAYER_NAME' not found in output GPKG after copy"
fi

FIELDS="$(get_fields "$OUTPUT_GPKG")"

if [[ "$VERBOSE" -ge 2 ]]; then
    debug_table_schema "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME"
    debug_null_counts "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME"
    debug_sample_rows "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME"
fi

GEOM_COLUMN="$(detect_geometry_column "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME")"
log 2 "→ Geometry column detected: ${GEOM_COLUMN:-<none>}"

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

STEP0_OBJECTS=0
STEP1_OBJECTS=0
STEP2_OBJECTS=0
STEP3_OBJECTS=0
STEP4_OBJECTS=0
STEP5_OBJECTS=0

# 0 - Nettoyage géométries NULL
log 1 "→ Removing NULL geometries (if any)..."

if [[ -n "$GEOM_COLUMN" ]]; then
    UPDATED_NULL_GEOM="$(sqlite3 "$OUTPUT_GPKG" "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"$GEOM_COLUMN\" IS NULL;" 2>/dev/null || echo 0)"
    UPDATED_NULL_GEOM="$(normalize_int "$UPDATED_NULL_GEOM")"

    if [[ "$UPDATED_NULL_GEOM" -gt 0 ]]; then
        if ogrinfo "$OUTPUT_GPKG" -dialect SQLite -sql "DELETE FROM \"$OUTPUT_LAYER_NAME\" WHERE \"$GEOM_COLUMN\" IS NULL;" >/dev/null 2>&1; then
            log 2 "   ✔ Removed $UPDATED_NULL_GEOM feature(s) with NULL geometry"
        else
            log 1 "   ⚠️ Failed to remove NULL geometries"
            UPDATED_NULL_GEOM=0
        fi
    else
        log 2 "   ℹ️ No NULL geometry found"
    fi
else
    log 2 "   ℹ️ No geometry column detected, skipping NULL geometry cleanup"
fi

STEP0_OBJECTS="$UPDATED_NULL_GEOM"

# 1 - Altitudes sol
log 1 "→ Filling missing ground altitudes..."
STEP1_OBJECTS="$(count_distinct_objects \
    "$OUTPUT_GPKG" \
    "SELECT COUNT(DISTINCT \"fid\") FROM \"$OUTPUT_LAYER_NAME\"
     WHERE (\"$GROUND_MAX_FIELD\" IS NULL AND \"$GROUND_MIN_FIELD\" IS NOT NULL)
        OR (\"$GROUND_MIN_FIELD\" IS NULL AND \"$GROUND_MAX_FIELD\" IS NOT NULL);"
)"

if has_field "$GROUND_MAX_FIELD" && has_field "$GROUND_MIN_FIELD"; then
    UPDATED_GROUND_MAX="$(run_sql_update \
        "$OUTPUT_GPKG" \
        "$GROUND_MAX_FIELD from $GROUND_MIN_FIELD" \
        "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"$GROUND_MAX_FIELD\" IS NULL AND \"$GROUND_MIN_FIELD\" IS NOT NULL;" \
        "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"$GROUND_MAX_FIELD\" = \"$GROUND_MIN_FIELD\" WHERE \"$GROUND_MAX_FIELD\" IS NULL AND \"$GROUND_MIN_FIELD\" IS NOT NULL;"
    )"

    UPDATED_GROUND_MIN="$(run_sql_update \
        "$OUTPUT_GPKG" \
        "$GROUND_MIN_FIELD from $GROUND_MAX_FIELD" \
        "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"$GROUND_MIN_FIELD\" IS NULL AND \"$GROUND_MAX_FIELD\" IS NOT NULL;" \
        "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"$GROUND_MIN_FIELD\" = \"$GROUND_MAX_FIELD\" WHERE \"$GROUND_MIN_FIELD\" IS NULL AND \"$GROUND_MAX_FIELD\" IS NOT NULL;"
    )"
else
    log 1 "⚠️ Missing ground altitude fields → skip"
    STEP1_OBJECTS=0
fi

log 1 "   → Objects corrected in step 1: $STEP1_OBJECTS"

# 2 - Altitudes toit directes
log 1 "→ Filling missing roof altitudes..."
STEP2_OBJECTS="$(count_distinct_objects \
    "$OUTPUT_GPKG" \
    "SELECT COUNT(DISTINCT \"fid\") FROM \"$OUTPUT_LAYER_NAME\"
     WHERE (\"$ROOF_MAX_FIELD\" IS NULL AND \"$ROOF_MIN_FIELD\" IS NOT NULL)
        OR (\"$ROOF_MIN_FIELD\" IS NULL AND \"$ROOF_MAX_FIELD\" IS NOT NULL);"
)"

if has_field "$ROOF_MAX_FIELD" && has_field "$ROOF_MIN_FIELD"; then
    UPDATED_ROOF_MAX="$(run_sql_update \
        "$OUTPUT_GPKG" \
        "$ROOF_MAX_FIELD from $ROOF_MIN_FIELD" \
        "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"$ROOF_MAX_FIELD\" IS NULL AND \"$ROOF_MIN_FIELD\" IS NOT NULL;" \
        "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"$ROOF_MAX_FIELD\" = \"$ROOF_MIN_FIELD\" WHERE \"$ROOF_MAX_FIELD\" IS NULL AND \"$ROOF_MIN_FIELD\" IS NOT NULL;"
    )"

    UPDATED_ROOF_MIN="$(run_sql_update \
        "$OUTPUT_GPKG" \
        "$ROOF_MIN_FIELD from $ROOF_MAX_FIELD" \
        "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"$ROOF_MIN_FIELD\" IS NULL AND \"$ROOF_MAX_FIELD\" IS NOT NULL;" \
        "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"$ROOF_MIN_FIELD\" = \"$ROOF_MAX_FIELD\" WHERE \"$ROOF_MIN_FIELD\" IS NULL AND \"$ROOF_MAX_FIELD\" IS NOT NULL;"
    )"
else
    log 1 "⚠️ Missing roof altitude fields → skip"
    STEP2_OBJECTS=0
fi

log 1 "   → Objects corrected in step 2: $STEP2_OBJECTS"

# 3 - Calcul hauteur
log 1 "→ Calculating $HEIGHT_FIELD..."
STEP3_OBJECTS="$(count_distinct_objects \
    "$OUTPUT_GPKG" \
    "SELECT COUNT(DISTINCT \"fid\") FROM \"$OUTPUT_LAYER_NAME\"
     WHERE \"$HEIGHT_FIELD\" IS NULL
       AND \"$ROOF_MAX_FIELD\" IS NOT NULL
       AND \"$GROUND_MIN_FIELD\" IS NOT NULL;"
)"

if has_field "$HEIGHT_FIELD" && has_field "$ROOF_MAX_FIELD" && has_field "$GROUND_MIN_FIELD"; then
    UPDATED_HEIGHT="$(run_sql_update \
        "$OUTPUT_GPKG" \
        "$HEIGHT_FIELD from $ROOF_MAX_FIELD - $GROUND_MIN_FIELD" \
        "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"$HEIGHT_FIELD\" IS NULL AND \"$ROOF_MAX_FIELD\" IS NOT NULL AND \"$GROUND_MIN_FIELD\" IS NOT NULL;" \
        "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"$HEIGHT_FIELD\" = ROUND(\"$ROOF_MAX_FIELD\" - \"$GROUND_MIN_FIELD\", 3) WHERE \"$HEIGHT_FIELD\" IS NULL AND \"$ROOF_MAX_FIELD\" IS NOT NULL AND \"$GROUND_MIN_FIELD\" IS NOT NULL;"
    )"
else
    log 1 "⚠️ Missing fields for height computation → skip"
    STEP3_OBJECTS=0
fi

log 1 "   → Objects corrected in step 3: $STEP3_OBJECTS"

# 4 - Reconstruction toit
log 1 "→ Reconstructing roof altitudes..."
STEP4_OBJECTS="$(count_distinct_objects \
    "$OUTPUT_GPKG" \
    "SELECT COUNT(DISTINCT \"fid\") FROM \"$OUTPUT_LAYER_NAME\"
     WHERE \"$HEIGHT_FIELD\" IS NOT NULL
       AND (
            (\"$ROOF_MAX_FIELD\" IS NULL AND \"$GROUND_MAX_FIELD\" IS NOT NULL)
         OR (\"$ROOF_MIN_FIELD\" IS NULL AND \"$GROUND_MIN_FIELD\" IS NOT NULL)
       );"
)"

if has_field "$HEIGHT_FIELD" && has_field "$GROUND_MAX_FIELD" && has_field "$GROUND_MIN_FIELD"; then
    if has_field "$ROOF_MAX_FIELD"; then
        UPDATED_RECON_ROOF_MAX="$(run_sql_update \
            "$OUTPUT_GPKG" \
            "$ROOF_MAX_FIELD from $GROUND_MAX_FIELD + $HEIGHT_FIELD" \
            "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"$ROOF_MAX_FIELD\" IS NULL AND \"$GROUND_MAX_FIELD\" IS NOT NULL AND \"$HEIGHT_FIELD\" IS NOT NULL;" \
            "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"$ROOF_MAX_FIELD\" = ROUND(\"$GROUND_MAX_FIELD\" + \"$HEIGHT_FIELD\", 3) WHERE \"$ROOF_MAX_FIELD\" IS NULL AND \"$GROUND_MAX_FIELD\" IS NOT NULL AND \"$HEIGHT_FIELD\" IS NOT NULL;"
        )"
    fi

    if has_field "$ROOF_MIN_FIELD"; then
        UPDATED_RECON_ROOF_MIN="$(run_sql_update \
            "$OUTPUT_GPKG" \
            "$ROOF_MIN_FIELD from $GROUND_MIN_FIELD + $HEIGHT_FIELD" \
            "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"$ROOF_MIN_FIELD\" IS NULL AND \"$GROUND_MIN_FIELD\" IS NOT NULL AND \"$HEIGHT_FIELD\" IS NOT NULL;" \
            "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"$ROOF_MIN_FIELD\" = ROUND(\"$GROUND_MIN_FIELD\" + \"$HEIGHT_FIELD\", 3) WHERE \"$ROOF_MIN_FIELD\" IS NULL AND \"$GROUND_MIN_FIELD\" IS NOT NULL AND \"$HEIGHT_FIELD\" IS NOT NULL;"
        )"
    fi
else
    log 1 "⚠️ Missing fields for roof reconstruction → skip"
    STEP4_OBJECTS=0
fi

log 1 "   → Objects corrected in step 4: $STEP4_OBJECTS"

# 5 - Reconstruction sol
log 1 "→ Backfilling ground altitudes..."
STEP5_OBJECTS="$(count_distinct_objects \
    "$OUTPUT_GPKG" \
    "SELECT COUNT(DISTINCT \"fid\") FROM \"$OUTPUT_LAYER_NAME\"
     WHERE \"$HEIGHT_FIELD\" IS NOT NULL
       AND (
            (\"$GROUND_MAX_FIELD\" IS NULL AND \"$ROOF_MAX_FIELD\" IS NOT NULL)
         OR (\"$GROUND_MIN_FIELD\" IS NULL AND \"$ROOF_MIN_FIELD\" IS NOT NULL)
       );"
)"

if has_field "$HEIGHT_FIELD" && has_field "$ROOF_MAX_FIELD" && has_field "$ROOF_MIN_FIELD"; then
    if has_field "$GROUND_MAX_FIELD"; then
        UPDATED_RECON_GROUND_MAX="$(run_sql_update \
            "$OUTPUT_GPKG" \
            "$GROUND_MAX_FIELD from $ROOF_MAX_FIELD - $HEIGHT_FIELD" \
            "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"$GROUND_MAX_FIELD\" IS NULL AND \"$ROOF_MAX_FIELD\" IS NOT NULL AND \"$HEIGHT_FIELD\" IS NOT NULL;" \
            "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"$GROUND_MAX_FIELD\" = ROUND(\"$ROOF_MAX_FIELD\" - \"$HEIGHT_FIELD\", 3) WHERE \"$GROUND_MAX_FIELD\" IS NULL AND \"$ROOF_MAX_FIELD\" IS NOT NULL AND \"$HEIGHT_FIELD\" IS NOT NULL;"
        )"
    fi

    if has_field "$GROUND_MIN_FIELD"; then
        UPDATED_RECON_GROUND_MIN="$(run_sql_update \
            "$OUTPUT_GPKG" \
            "$GROUND_MIN_FIELD from $ROOF_MIN_FIELD - $HEIGHT_FIELD" \
            "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"$GROUND_MIN_FIELD\" IS NULL AND \"$ROOF_MIN_FIELD\" IS NOT NULL AND \"$HEIGHT_FIELD\" IS NOT NULL;" \
            "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"$GROUND_MIN_FIELD\" = ROUND(\"$ROOF_MIN_FIELD\" - \"$HEIGHT_FIELD\", 3) WHERE \"$GROUND_MIN_FIELD\" IS NULL AND \"$ROOF_MIN_FIELD\" IS NOT NULL AND \"$HEIGHT_FIELD\" IS NOT NULL;"
        )"
    fi
else
    log 1 "⚠️ Missing fields for ground reconstruction → skip"
    STEP5_OBJECTS=0
fi

log 1 "   → Objects corrected in step 5: $STEP5_OBJECTS"

if [[ "$VERBOSE" -ge 2 ]]; then
    log 2 "→ Post-update diagnostics:"
    debug_null_counts "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME"
    debug_sample_rows "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME"
    debug_remaining_missing "$OUTPUT_GPKG" "$OUTPUT_LAYER_NAME"
fi

for var_name in \
    UPDATED_NULL_GEOM \
    UPDATED_GROUND_MAX UPDATED_GROUND_MIN \
    UPDATED_ROOF_MAX UPDATED_ROOF_MIN \
    UPDATED_HEIGHT \
    UPDATED_RECON_ROOF_MAX UPDATED_RECON_ROOF_MIN \
    UPDATED_RECON_GROUND_MAX UPDATED_RECON_GROUND_MIN \
    STEP0_OBJECTS STEP1_OBJECTS STEP2_OBJECTS STEP3_OBJECTS STEP4_OBJECTS STEP5_OBJECTS
do
    value="${!var_name:-0}"
    value="$(normalize_int "$value")"
    printf -v "$var_name" '%s' "$value"
done

TOTAL_OBJECTS_CORRECTED=$(( \
    STEP0_OBJECTS + STEP1_OBJECTS + STEP2_OBJECTS + STEP3_OBJECTS + STEP4_OBJECTS + STEP5_OBJECTS \
))

TOTAL_ATTRIBUTE_VALUES_UPDATED=$(( \
    UPDATED_NULL_GEOM + \
    UPDATED_GROUND_MAX + UPDATED_GROUND_MIN + \
    UPDATED_ROOF_MAX + UPDATED_ROOF_MIN + \
    UPDATED_HEIGHT + \
    UPDATED_RECON_ROOF_MAX + UPDATED_RECON_ROOF_MIN + \
    UPDATED_RECON_GROUND_MAX + UPDATED_RECON_GROUND_MIN \
))

BUILDINGS_WITH_MISSING_ATTRIBUTES="$(count_distinct_objects \
    "$OUTPUT_GPKG" \
    "SELECT COUNT(DISTINCT \"fid\") FROM \"$OUTPUT_LAYER_NAME\"
     WHERE \"$HEIGHT_FIELD\" IS NULL
        OR \"$GROUND_MIN_FIELD\" IS NULL
        OR \"$GROUND_MAX_FIELD\" IS NULL
        OR \"$ROOF_MIN_FIELD\" IS NULL
        OR \"$ROOF_MAX_FIELD\" IS NULL;"
)"

if [[ "$VERBOSE" -ge 1 ]]; then
    echo
    echo "✅ Postprocessing done"
    echo "   Input kept unchanged : $INPUT_GPKG"
    echo "   Output GPKG updated  : $OUTPUT_GPKG"
    echo
    echo "Objects corrected by step:"
    echo "   Step 0 - NULL geometries removed         : $STEP0_OBJECTS"
    echo "   Step 1 - Ground altitudes completed      : $STEP1_OBJECTS"
    echo "   Step 2 - Roof altitudes completed        : $STEP2_OBJECTS"
    echo "   Step 3 - Height computed                 : $STEP3_OBJECTS"
    echo "   Step 4 - Roof reconstructed              : $STEP4_OBJECTS"
    echo "   Step 5 - Ground backfilled               : $STEP5_OBJECTS"
    echo
    echo "Attribute values updated by field:"
    echo "   geometrie removed (NULL geometry rows)   : $UPDATED_NULL_GEOM"
    echo "   $GROUND_MAX_FIELD                        : $UPDATED_GROUND_MAX"
    echo "   $GROUND_MIN_FIELD                        : $UPDATED_GROUND_MIN"
    echo "   $ROOF_MAX_FIELD                          : $UPDATED_ROOF_MAX"
    echo "   $ROOF_MIN_FIELD                          : $UPDATED_ROOF_MIN"
    echo "   $HEIGHT_FIELD                            : $UPDATED_HEIGHT"
    echo "   $ROOF_MAX_FIELD (reconstructed)          : $UPDATED_RECON_ROOF_MAX"
    echo "   $ROOF_MIN_FIELD (reconstructed)          : $UPDATED_RECON_ROOF_MIN"
    echo "   $GROUND_MAX_FIELD (backfilled)           : $UPDATED_RECON_GROUND_MAX"
    echo "   $GROUND_MIN_FIELD (backfilled)           : $UPDATED_RECON_GROUND_MIN"
    echo
    echo "Totals:"
    echo "   Total corrected objects (step sum)       : $TOTAL_OBJECTS_CORRECTED"
    echo "   Total attribute values updated           : $TOTAL_ATTRIBUTE_VALUES_UPDATED"
    echo "   Buildings with >=1 NULL attribute        : $BUILDINGS_WITH_MISSING_ATTRIBUTES"
fi

if [[ "$VERBOSE" -ge 2 ]]; then
    echo
    echo "Detailed field update summary:"
    echo "   NULL geometries removed                    : $UPDATED_NULL_GEOM"
    echo "   $GROUND_MAX_FIELD filled                  : $UPDATED_GROUND_MAX"
    echo "   $GROUND_MIN_FIELD filled                  : $UPDATED_GROUND_MIN"
    echo "   $ROOF_MAX_FIELD filled                    : $UPDATED_ROOF_MAX"
    echo "   $ROOF_MIN_FIELD filled                    : $UPDATED_ROOF_MIN"
    echo "   $HEIGHT_FIELD computed                    : $UPDATED_HEIGHT"
    echo "   $ROOF_MAX_FIELD reconstructed             : $UPDATED_RECON_ROOF_MAX"
    echo "   $ROOF_MIN_FIELD reconstructed             : $UPDATED_RECON_ROOF_MIN"
    echo "   $GROUND_MAX_FIELD backfilled              : $UPDATED_RECON_GROUND_MAX"
    echo "   $GROUND_MIN_FIELD backfilled              : $UPDATED_RECON_GROUND_MIN"
fi

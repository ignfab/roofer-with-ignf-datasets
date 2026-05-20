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
  --input PATH        Input GPKG file (read-only)
  --output PATH       Output GPKG file (created/overwritten)
  --layer NAME        Layer name (default: BUILDINGS)
  --verbose LEVEL     Verbosity level: 0, 1, 2 (default: 1)
  -h, --help          Show this help

Verbosity:
  0   Quiet mode
  1   Main steps + clear summary
  2   Detailed diagnostics + SQL verification + full summary

Example:
  $SCRIPT_NAME \\
      --input buildings.gpkg \\
      --output buildings_postprocessed.gpkg \\
      --layer buildings \\
      --verbose 2
EOF
}

INPUT_GPKG=""
OUTPUT_GPKG=""
OUTPUT_LAYER_NAME="BUILDINGS"
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
            SUM(CASE WHEN \"hauteur\" IS NULL THEN 1 ELSE 0 END) AS null_hauteur,
            SUM(CASE WHEN \"altitude_minimale_sol\" IS NULL THEN 1 ELSE 0 END) AS null_altitude_minimale_sol,
            SUM(CASE WHEN \"altitude_maximale_sol\" IS NULL THEN 1 ELSE 0 END) AS null_altitude_maximale_sol,
            SUM(CASE WHEN \"altitude_minimale_toit\" IS NULL THEN 1 ELSE 0 END) AS null_altitude_minimale_toit,
            SUM(CASE WHEN \"altitude_maximale_toit\" IS NULL THEN 1 ELSE 0 END) AS null_altitude_maximale_toit
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
            \"hauteur\",
            \"altitude_minimale_sol\",
            \"altitude_minimale_toit\",
            \"altitude_maximale_toit\",
            \"altitude_maximale_sol\"
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
            \"hauteur\",
            \"altitude_minimale_sol\",
            \"altitude_maximale_sol\",
            \"altitude_minimale_toit\",
            \"altitude_maximale_toit\"
        FROM \"$table\"
        WHERE \"altitude_minimale_toit\" IS NULL
           OR \"altitude_maximale_toit\" IS NULL
           OR \"hauteur\" IS NULL
           OR \"altitude_minimale_sol\" IS NULL
           OR \"altitude_maximale_sol\" IS NULL
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
UPDATED_ALT_MAX_SOL=0
UPDATED_ALT_MIN_SOL=0
UPDATED_ALT_MAX_TOIT=0
UPDATED_ALT_MIN_TOIT=0
UPDATED_HAUTEUR=0
UPDATED_RECON_TOIT_MAX=0
UPDATED_RECON_TOIT_MIN=0
UPDATED_RECON_SOL_MAX=0
UPDATED_RECON_SOL_MIN=0

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
     WHERE (\"altitude_maximale_sol\" IS NULL AND \"altitude_minimale_sol\" IS NOT NULL)
        OR (\"altitude_minimale_sol\" IS NULL AND \"altitude_maximale_sol\" IS NOT NULL);"
)"

if has_field altitude_maximale_sol && has_field altitude_minimale_sol; then
    UPDATED_ALT_MAX_SOL="$(run_sql_update \
        "$OUTPUT_GPKG" \
        "altitude_maximale_sol from altitude_minimale_sol" \
        "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"altitude_maximale_sol\" IS NULL AND \"altitude_minimale_sol\" IS NOT NULL;" \
        "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"altitude_maximale_sol\" = \"altitude_minimale_sol\" WHERE \"altitude_maximale_sol\" IS NULL AND \"altitude_minimale_sol\" IS NOT NULL;"
    )"

    UPDATED_ALT_MIN_SOL="$(run_sql_update \
        "$OUTPUT_GPKG" \
        "altitude_minimale_sol from altitude_maximale_sol" \
        "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"altitude_minimale_sol\" IS NULL AND \"altitude_maximale_sol\" IS NOT NULL;" \
        "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"altitude_minimale_sol\" = \"altitude_maximale_sol\" WHERE \"altitude_minimale_sol\" IS NULL AND \"altitude_maximale_sol\" IS NOT NULL;"
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
     WHERE (\"altitude_maximale_toit\" IS NULL AND \"altitude_minimale_toit\" IS NOT NULL)
        OR (\"altitude_minimale_toit\" IS NULL AND \"altitude_maximale_toit\" IS NOT NULL);"
)"

if has_field altitude_maximale_toit && has_field altitude_minimale_toit; then
    UPDATED_ALT_MAX_TOIT="$(run_sql_update \
        "$OUTPUT_GPKG" \
        "altitude_maximale_toit from altitude_minimale_toit" \
        "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"altitude_maximale_toit\" IS NULL AND \"altitude_minimale_toit\" IS NOT NULL;" \
        "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"altitude_maximale_toit\" = \"altitude_minimale_toit\" WHERE \"altitude_maximale_toit\" IS NULL AND \"altitude_minimale_toit\" IS NOT NULL;"
    )"

    UPDATED_ALT_MIN_TOIT="$(run_sql_update \
        "$OUTPUT_GPKG" \
        "altitude_minimale_toit from altitude_maximale_toit" \
        "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"altitude_minimale_toit\" IS NULL AND \"altitude_maximale_toit\" IS NOT NULL;" \
        "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"altitude_minimale_toit\" = \"altitude_maximale_toit\" WHERE \"altitude_minimale_toit\" IS NULL AND \"altitude_maximale_toit\" IS NOT NULL;"
    )"
else
    log 1 "⚠️ Missing roof altitude fields → skip"
    STEP2_OBJECTS=0
fi

log 1 "   → Objects corrected in step 2: $STEP2_OBJECTS"

# 3 - Calcul hauteur
log 1 "→ Calculating hauteur..."
STEP3_OBJECTS="$(count_distinct_objects \
    "$OUTPUT_GPKG" \
    "SELECT COUNT(DISTINCT \"fid\") FROM \"$OUTPUT_LAYER_NAME\"
     WHERE \"hauteur\" IS NULL
       AND \"altitude_maximale_toit\" IS NOT NULL
       AND \"altitude_minimale_sol\" IS NOT NULL;"
)"

if has_field hauteur && has_field altitude_maximale_toit && has_field altitude_minimale_sol; then
    UPDATED_HAUTEUR="$(run_sql_update \
        "$OUTPUT_GPKG" \
        "hauteur from altitude_maximale_toit - altitude_minimale_sol" \
        "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"hauteur\" IS NULL AND \"altitude_maximale_toit\" IS NOT NULL AND \"altitude_minimale_sol\" IS NOT NULL;" \
        "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"hauteur\" = ROUND(\"altitude_maximale_toit\" - \"altitude_minimale_sol\", 3) WHERE \"hauteur\" IS NULL AND \"altitude_maximale_toit\" IS NOT NULL AND \"altitude_minimale_sol\" IS NOT NULL;"
    )"
else
    log 1 "⚠️ Missing fields for hauteur computation → skip"
    STEP3_OBJECTS=0
fi

log 1 "   → Objects corrected in step 3: $STEP3_OBJECTS"

# 4 - Reconstruction toit
log 1 "→ Reconstructing roof altitudes..."
STEP4_OBJECTS="$(count_distinct_objects \
    "$OUTPUT_GPKG" \
    "SELECT COUNT(DISTINCT \"fid\") FROM \"$OUTPUT_LAYER_NAME\"
     WHERE \"hauteur\" IS NOT NULL
       AND (
            (\"altitude_maximale_toit\" IS NULL AND \"altitude_maximale_sol\" IS NOT NULL)
         OR (\"altitude_minimale_toit\" IS NULL AND \"altitude_minimale_sol\" IS NOT NULL)
       );"
)"

if has_field hauteur && has_field altitude_maximale_sol && has_field altitude_minimale_sol; then
    if has_field altitude_maximale_toit; then
        UPDATED_RECON_TOIT_MAX="$(run_sql_update \
            "$OUTPUT_GPKG" \
            "altitude_maximale_toit from altitude_maximale_sol + hauteur" \
            "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"altitude_maximale_toit\" IS NULL AND \"altitude_maximale_sol\" IS NOT NULL AND \"hauteur\" IS NOT NULL;" \
            "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"altitude_maximale_toit\" = ROUND(\"altitude_maximale_sol\" + \"hauteur\", 3) WHERE \"altitude_maximale_toit\" IS NULL AND \"altitude_maximale_sol\" IS NOT NULL AND \"hauteur\" IS NOT NULL;"
        )"
    fi

    if has_field altitude_minimale_toit; then
        UPDATED_RECON_TOIT_MIN="$(run_sql_update \
            "$OUTPUT_GPKG" \
            "altitude_minimale_toit from altitude_minimale_sol + hauteur" \
            "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"altitude_minimale_toit\" IS NULL AND \"altitude_minimale_sol\" IS NOT NULL AND \"hauteur\" IS NOT NULL;" \
            "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"altitude_minimale_toit\" = ROUND(\"altitude_minimale_sol\" + \"hauteur\", 3) WHERE \"altitude_minimale_toit\" IS NULL AND \"altitude_minimale_sol\" IS NOT NULL AND \"hauteur\" IS NOT NULL;"
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
     WHERE \"hauteur\" IS NOT NULL
       AND (
            (\"altitude_maximale_sol\" IS NULL AND \"altitude_maximale_toit\" IS NOT NULL)
         OR (\"altitude_minimale_sol\" IS NULL AND \"altitude_minimale_toit\" IS NOT NULL)
       );"
)"

if has_field hauteur && has_field altitude_maximale_toit && has_field altitude_minimale_toit; then
    if has_field altitude_maximale_sol; then
        UPDATED_RECON_SOL_MAX="$(run_sql_update \
            "$OUTPUT_GPKG" \
            "altitude_maximale_sol from altitude_maximale_toit - hauteur" \
            "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"altitude_maximale_sol\" IS NULL AND \"altitude_maximale_toit\" IS NOT NULL AND \"hauteur\" IS NOT NULL;" \
            "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"altitude_maximale_sol\" = ROUND(\"altitude_maximale_toit\" - \"hauteur\", 3) WHERE \"altitude_maximale_sol\" IS NULL AND \"altitude_maximale_toit\" IS NOT NULL AND \"hauteur\" IS NOT NULL;"
        )"
    fi

    if has_field altitude_minimale_sol; then
        UPDATED_RECON_SOL_MIN="$(run_sql_update \
            "$OUTPUT_GPKG" \
            "altitude_minimale_sol from altitude_minimale_toit - hauteur" \
            "SELECT COUNT(*) FROM \"$OUTPUT_LAYER_NAME\" WHERE \"altitude_minimale_sol\" IS NULL AND \"altitude_minimale_toit\" IS NOT NULL AND \"hauteur\" IS NOT NULL;" \
            "UPDATE \"$OUTPUT_LAYER_NAME\" SET \"altitude_minimale_sol\" = ROUND(\"altitude_minimale_toit\" - \"hauteur\", 3) WHERE \"altitude_minimale_sol\" IS NULL AND \"altitude_minimale_toit\" IS NOT NULL AND \"hauteur\" IS NOT NULL;"
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
    UPDATED_ALT_MAX_SOL UPDATED_ALT_MIN_SOL \
    UPDATED_ALT_MAX_TOIT UPDATED_ALT_MIN_TOIT \
    UPDATED_HAUTEUR \
    UPDATED_RECON_TOIT_MAX UPDATED_RECON_TOIT_MIN \
    UPDATED_RECON_SOL_MAX UPDATED_RECON_SOL_MIN \
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
    UPDATED_ALT_MAX_SOL + UPDATED_ALT_MIN_SOL + \
    UPDATED_ALT_MAX_TOIT + UPDATED_ALT_MIN_TOIT + \
    UPDATED_HAUTEUR + \
    UPDATED_RECON_TOIT_MAX + UPDATED_RECON_TOIT_MIN + \
    UPDATED_RECON_SOL_MAX + UPDATED_RECON_SOL_MIN \
))

BUILDINGS_WITH_MISSING_ATTRIBUTES="$(count_distinct_objects \
    "$OUTPUT_GPKG" \
    "SELECT COUNT(DISTINCT \"fid\") FROM \"$OUTPUT_LAYER_NAME\"
     WHERE \"hauteur\" IS NULL
        OR \"altitude_minimale_sol\" IS NULL
        OR \"altitude_maximale_sol\" IS NULL
        OR \"altitude_minimale_toit\" IS NULL
        OR \"altitude_maximale_toit\" IS NULL;"
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
    echo "   altitude_maximale_sol                    : $UPDATED_ALT_MAX_SOL"
    echo "   altitude_minimale_sol                    : $UPDATED_ALT_MIN_SOL"
    echo "   altitude_maximale_toit                   : $UPDATED_ALT_MAX_TOIT"
    echo "   altitude_minimale_toit                   : $UPDATED_ALT_MIN_TOIT"
    echo "   hauteur                                  : $UPDATED_HAUTEUR"
    echo "   altitude_maximale_toit (reconstructed)   : $UPDATED_RECON_TOIT_MAX"
    echo "   altitude_minimale_toit (reconstructed)   : $UPDATED_RECON_TOIT_MIN"
    echo "   altitude_maximale_sol (backfilled)       : $UPDATED_RECON_SOL_MAX"
    echo "   altitude_minimale_sol (backfilled)       : $UPDATED_RECON_SOL_MIN"
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
    echo "   altitude_maximale_sol filled              : $UPDATED_ALT_MAX_SOL"
    echo "   altitude_minimale_sol filled              : $UPDATED_ALT_MIN_SOL"
    echo "   altitude_maximale_toit filled             : $UPDATED_ALT_MAX_TOIT"
    echo "   altitude_minimale_toit filled             : $UPDATED_ALT_MIN_TOIT"
    echo "   hauteur computed                          : $UPDATED_HAUTEUR"
    echo "   altitude_maximale_toit reconstructed      : $UPDATED_RECON_TOIT_MAX"
    echo "   altitude_minimale_toit reconstructed      : $UPDATED_RECON_TOIT_MIN"
    echo "   altitude_maximale_sol backfilled          : $UPDATED_RECON_SOL_MAX"
    echo "   altitude_minimale_sol backfilled          : $UPDATED_RECON_SOL_MIN"
fi

#!/usr/bin/env bash
# Detects net-new columns in a source dataset compared to the last approved baseline snapshot.
# If new columns are found the workflow halts — a human must re-review before proceeding.
set -euo pipefail

PROJECT=""
DATASET=""
BASELINE_DIR=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --project)      PROJECT="$2";      shift 2 ;;
    --dataset)      DATASET="$2";      shift 2 ;;
    --baseline-dir) BASELINE_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

BASELINE_FILE="${BASELINE_DIR}/${DATASET}.json"

CURRENT=$(bq query --nouse_legacy_sql --format=json \
  "SELECT table_name, column_name, data_type
   FROM \`${PROJECT}.${DATASET}.INFORMATION_SCHEMA.COLUMNS\`
   ORDER BY table_name, column_name")

if [[ ! -f "$BASELINE_FILE" ]]; then
  echo "No baseline found for $DATASET — saving current schema as baseline."
  mkdir -p "$BASELINE_DIR"
  echo "$CURRENT" > "$BASELINE_FILE"
  exit 0
fi

BASELINE=$(cat "$BASELINE_FILE")

NEW_COLUMNS=$(diff \
  <(echo "$BASELINE" | jq -r '.[] | "\(.table_name).\(.column_name)"' | sort) \
  <(echo "$CURRENT"  | jq -r '.[] | "\(.table_name).\(.column_name)"' | sort) \
  | grep '^>' | sed 's/^> //')

if [[ -n "$NEW_COLUMNS" ]]; then
  echo "ERROR: net-new columns detected in $DATASET since last approved baseline:" >&2
  echo "$NEW_COLUMNS" >&2
  echo "" >&2
  echo "Update config/approved_tables/${DATASET}.json and re-run with a reviewed PR to proceed." >&2
  exit 1
fi

echo "Schema drift check passed — no new columns in $DATASET."

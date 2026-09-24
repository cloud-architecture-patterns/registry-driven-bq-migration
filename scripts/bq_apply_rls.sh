#!/usr/bin/env bash
# Reapplies row-level security policies from config/rls/<dataset>.json after every copy.
# BigQuery row access policies are NOT transferred by DTS or bq cp — they must be re-created.
set -euo pipefail

PROJECT=""
DATASET=""
RLS_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --project)  PROJECT="$2";  shift 2 ;;
    --dataset)  DATASET="$2";  shift 2 ;;
    --rls-file) RLS_FILE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$RLS_FILE" ]]; then
  echo "No RLS config at $RLS_FILE — skipping."
  exit 0
fi

POLICY_COUNT=$(jq '.policies | length' "$RLS_FILE")
if [[ "$POLICY_COUNT" -eq 0 ]]; then
  echo "No policies defined in $RLS_FILE — skipping."
  exit 0
fi

echo "Applying $POLICY_COUNT row-level security policy/policies to $PROJECT:$DATASET..."

jq -c '.policies[]' "$RLS_FILE" | while read -r POLICY; do
  TABLE=$(echo "$POLICY" | jq -r '.table')
  POLICY_NAME=$(echo "$POLICY" | jq -r '.policy_name')
  FILTER=$(echo "$POLICY" | jq -r '.filter_expression')
  GRANTEES=$(echo "$POLICY" | jq -r '.grantees[]' | sed "s/^/'/;s/$/'/" | paste -sd ',' -)

  echo "  Applying policy '$POLICY_NAME' on $TABLE..."

  bq query --nouse_legacy_sql \
    "CREATE OR REPLACE ROW ACCESS POLICY \`${POLICY_NAME}\`
     ON \`${PROJECT}.${DATASET}.${TABLE}\`
     GRANT TO (${GRANTEES})
     FILTER USING (${FILTER})"
done

echo "Verifying policies were applied..."
jq -r '.policies[].policy_name' "$RLS_FILE" | while read -r POLICY_NAME; do
  COUNT=$(bq query --nouse_legacy_sql --format=csv \
    "SELECT COUNT(*) FROM \`${PROJECT}.${DATASET}.INFORMATION_SCHEMA.ROW_ACCESS_POLICIES\`
     WHERE policy_name = '${POLICY_NAME}'" | tail -n 1)
  if [[ "$COUNT" -ne 1 ]]; then
    echo "ERROR: policy '$POLICY_NAME' not found after reapplication" >&2
    exit 1
  fi
done

echo "RLS reapplication verified successfully."

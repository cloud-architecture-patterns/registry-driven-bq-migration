#!/usr/bin/env bash
# Gate 1 & 3: allow-list manifest check and deny-list destination scan.
# Also handles project allowlist pre-flight check.
set -euo pipefail

MODE="allowlist"
SOURCE_PROJECT=""
SOURCE_DATASET=""
DEST_PROJECT=""
DEST_DATASET=""
ALLOWED_SOURCE=""
ALLOWED_DEST=""
MANIFEST=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --mode)           MODE="$2";            shift 2 ;;
    --source-project) SOURCE_PROJECT="$2";  shift 2 ;;
    --source-dataset) SOURCE_DATASET="$2";  shift 2 ;;
    --dest-project)   DEST_PROJECT="$2";    shift 2 ;;
    --dest-dataset)   DEST_DATASET="$2";    shift 2 ;;
    --allowed-source) ALLOWED_SOURCE="$2";  shift 2 ;;
    --allowed-dest)   ALLOWED_DEST="$2";    shift 2 ;;
    --manifest)       MANIFEST="$2";        shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

project_in_list() {
  local project="$1"
  local list="$2"
  IFS=',' read -ra PROJECTS <<< "$list"
  for p in "${PROJECTS[@]}"; do
    [[ "$p" == "$project" ]] && return 0
  done
  return 1
}

case "$MODE" in
  project-allowlist)
    echo "Checking project allowlist..."
    if ! project_in_list "$SOURCE_PROJECT" "$ALLOWED_SOURCE"; then
      echo "ERROR: source project '$SOURCE_PROJECT' is not in APPCODE allowed_source_projects" >&2
      exit 1
    fi
    if ! project_in_list "$DEST_PROJECT" "$ALLOWED_DEST"; then
      echo "ERROR: destination project '$DEST_PROJECT' is not in APPCODE allowed_destination_projects" >&2
      exit 1
    fi
    echo "Project allowlist check passed."
    ;;

  allow-list)
    echo "Checking allow-list manifest against source schema..."
    APPROVED=$(jq -r '.approved_tables[]' "$MANIFEST" | sort)
    DENY=$(jq -r '.deny_tables // [] | .[]' "$MANIFEST" | sort)

    ACTUAL=$(bq query --nouse_legacy_sql --format=csv \
      "SELECT table_name FROM \`${SOURCE_PROJECT}.${SOURCE_DATASET}.INFORMATION_SCHEMA.TABLES\`" \
      | tail -n +2 | sort)

    UNAPPROVED=$(comm -23 <(echo "$ACTUAL") <(echo "$APPROVED"))
    if [[ -n "$UNAPPROVED" ]]; then
      echo "ERROR: the following tables are present in source but NOT in the approved manifest:" >&2
      echo "$UNAPPROVED" >&2
      exit 1
    fi

    DENIED_PRESENT=$(comm -12 <(echo "$ACTUAL") <(echo "$DENY"))
    if [[ -n "$DENIED_PRESENT" ]]; then
      echo "ERROR: the following denied tables are present in source dataset:" >&2
      echo "$DENIED_PRESENT" >&2
      exit 1
    fi

    echo "Allow-list check passed. Tables approved for migration:"
    echo "$APPROVED"
    ;;

  deny-check)
    echo "Post-copy destination deny-list scan..."
    DENY=$(jq -r '.deny_tables // [] | .[]' "$MANIFEST" | sort)
    if [[ -z "$DENY" ]]; then
      echo "No deny_tables configured — skipping."
      exit 0
    fi

    ACTUAL=$(bq query --nouse_legacy_sql --format=csv \
      "SELECT table_name FROM \`${DEST_PROJECT}.${DEST_DATASET}.INFORMATION_SCHEMA.TABLES\`" \
      | tail -n +2 | sort)

    DENIED_PRESENT=$(comm -12 <(echo "$ACTUAL") <(echo "$DENY"))
    if [[ -n "$DENIED_PRESENT" ]]; then
      echo "ERROR: denied tables found in destination dataset after copy:" >&2
      echo "$DENIED_PRESENT" >&2
      exit 1
    fi

    echo "Deny-list scan passed — no denied tables in destination."
    ;;

  *)
    echo "Unknown mode: $MODE" >&2
    exit 1
    ;;
esac

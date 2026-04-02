#!/usr/bin/env bash
# Show NotificationRequest CRDs for demo scenarios
# Usage: show-notification.sh <namespace> [name-pattern]
set -euo pipefail

NAMESPACE="${1:?Usage: show-notification.sh <namespace> [name-pattern]}"
NAME_PATTERN="${2:-}"

# Fetch NotificationRequest CRDs
JSON=$(kubectl get notificationrequest -n "$NAMESPACE" -o json 2>/dev/null || echo '{"items":[]}')

# Count items
COUNT=0
if command -v jq &>/dev/null; then
  COUNT=$(echo "$JSON" | jq '.items | length // 0')
else
  COUNT=$(kubectl get notificationrequest -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
fi

# No NotificationRequest found
if [ "${COUNT:-0}" -eq 0 ]; then
  printf '\n  \e[38;5;245mNo notification generated — pipeline completed without action\e[0m\n\n'
  exit 0
fi

# Display one NotificationRequest (reads JSON from stdin or uses name for kubectl)
display_one() {
  local subj body prio type phase meta name
  local use_jq=false
  if command -v jq &>/dev/null; then
    use_jq=true
  fi

  if $use_jq; then
    local json
    json=$(cat)
    subj=$(echo "$json" | jq -r '.spec.subject // ""')
    body=$(echo "$json" | jq -r '.spec.body // ""')
    prio=$(echo "$json" | jq -r '.spec.priority // ""')
    type=$(echo "$json" | jq -r '.spec.type // ""')
    phase=$(echo "$json" | jq -r '.status.phase // "Pending"')
    meta=$(echo "$json" | jq -r '(.spec.extensions // {}) | to_entries | map("\(.key)=\(.value)") | join(", ")')

    # v1.2.0 structured context: flatten .spec.context sub-structs into
    # display-friendly lines (lineage, workflow, analysis, verification).
    local ctx_lines=""
    ctx_lines=$(echo "$json" | jq -r '
      def kv(prefix; obj): obj // {} | to_entries[] | "\(prefix).\(.key) = \(.value)";
      [
        (if .spec.context.lineage    then kv("lineage";    .spec.context.lineage)    else empty end),
        (if .spec.context.workflow    then kv("workflow";   .spec.context.workflow)   else empty end),
        (if .spec.context.analysis    then kv("analysis";   .spec.context.analysis)   else empty end),
        (if .spec.context.review      then kv("review";     .spec.context.review)     else empty end),
        (if .spec.context.execution   then kv("execution";  .spec.context.execution)  else empty end),
        (if .spec.context.target      then kv("target";     .spec.context.target)     else empty end),
        (if .spec.context.dedup       then kv("dedup";      .spec.context.dedup)      else empty end),
        (if .spec.context.verification then kv("verification"; .spec.context.verification) else empty end)
      ] | join("\n")
    ' 2>/dev/null || true)

    # Supplement empty Outcome from the RR status (notification is created
    # during the Verifying phase before the outcome is known).
    if echo "$body" | grep -q '^\*\*Outcome\*\*: *$'; then
      local rr_name rr_ns outcome
      rr_name=$(echo "$json" | jq -r '.spec.remediationRequestRef.name // ""')
      rr_ns=$(echo "$json" | jq -r '.spec.remediationRequestRef.namespace // ""')
      if [ -n "$rr_name" ] && [ -n "$rr_ns" ]; then
        outcome=$(kubectl get remediationrequest "$rr_name" -n "$rr_ns" \
          -o jsonpath='{.status.outcome}' 2>/dev/null || true)
        if [ -n "$outcome" ]; then
          body=$(echo "$body" | sed "s/^\*\*Outcome\*\*: *$/\*\*Outcome\*\*: $outcome/")
        fi
      fi
    fi
  else
    name="$1"
    [ -z "$name" ] && return
    subj=$(kubectl get notificationrequest "$name" -n "$NAMESPACE" -o jsonpath='{.spec.subject}' 2>/dev/null || true)
    body=$(kubectl get notificationrequest "$name" -n "$NAMESPACE" -o jsonpath='{.spec.body}' 2>/dev/null || true)
    prio=$(kubectl get notificationrequest "$name" -n "$NAMESPACE" -o jsonpath='{.spec.priority}' 2>/dev/null || true)
    type=$(kubectl get notificationrequest "$name" -n "$NAMESPACE" -o jsonpath='{.spec.type}' 2>/dev/null || true)
    phase=$(kubectl get notificationrequest "$name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    meta=$(kubectl get notificationrequest "$name" -n "$NAMESPACE" -o jsonpath='{.spec.extensions}' 2>/dev/null | sed 's/map\[//;s/\]//' || true)
  fi

  # Title from subject or type
  local title="${subj:-$type}"
  [ -z "$title" ] && title="Notification"

  local line_w=100

  printf '\n'
  printf '  \e[1;33mSubject:\e[0m  %s\n' "${subj:0:$line_w}"
  printf '  \e[1;33mPriority:\e[0m %s   \e[1;33mType:\e[0m %s   \e[1;33mPhase:\e[0m %s\n' \
    "${prio:-N/A}" "${type:-N/A}" "${phase:-Pending}"
  printf '  \e[38;5;245m%s\e[0m\n' "────────────────────────────────────────────────────────────────────────"
  echo "$body" | fold -s -w "$line_w" | while IFS= read -r line; do
    printf '  %s\n' "$line"
  done

  # v1.2.0: display structured context when present (jq path only)
  if [ -n "${ctx_lines:-}" ]; then
    printf '\n  \e[1;36mContext\e[0m\n'
    printf '  \e[38;5;245m%s\e[0m\n' "────────────────────────────────────────────────────────────────────────"
    echo "$ctx_lines" | while IFS= read -r cline; do
      [ -n "$cline" ] && printf '  \e[38;5;245m%s\e[0m\n' "$cline"
    done
  fi

  if [ -n "${meta:-}" ]; then
    printf '\n  \e[1;36mExtensions\e[0m  %s\n' "$meta"
  fi
  printf '\n'
}

if command -v jq &>/dev/null; then
  # Filter by name pattern if provided
  if [ -n "$NAME_PATTERN" ]; then
    ITEMS=$(echo "$JSON" | jq -c --arg pat "$NAME_PATTERN" '.items[] | select(.metadata.name | contains($pat))')
  else
    ITEMS=$(echo "$JSON" | jq -c '.items[]')
  fi
  echo "$ITEMS" | while IFS= read -r item; do
    [ -n "$item" ] && echo "$item" | display_one
  done
else
  # jsonpath fallback: get names and fetch each
  for name in $(kubectl get notificationrequest -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    [ -z "$name" ] && continue
    if [ -n "$NAME_PATTERN" ] && [[ "$name" != *"$NAME_PATTERN"* ]]; then
      continue
    fi
    display_one "$name"
  done
fi

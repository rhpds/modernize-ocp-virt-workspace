#!/bin/bash

# Cluster-wide checks for workshop lab environments.
# Auto-discovers tenants from ClusterResourceQuotas (tenant-user-*).
#
# Usage:
#   ./check-cluster.sh              # run all checks
#   ./check-cluster.sh quota        # run only quota
#   ./check-cluster.sh travel       # run only travel-portal check

set -euo pipefail

# --- Tenant discovery ---

discover_tenants() {
  oc get clusterresourcequotas -o name \
    | sed 's|clusterresourcequota.quota.openshift.io/tenant-||' \
    | sort
}

TENANTS=$(discover_tenants)
TENANT_COUNT=$(echo "$TENANTS" | wc -l | tr -d ' ')

if [[ -z "$TENANTS" ]]; then
  echo "No tenants found."
  exit 1
fi

echo "=============================="
echo " Workshop Cluster Checks"
echo " Tenants: $TENANT_COUNT"
echo "=============================="
echo ""

CHECKS=("${@:-all}")
should_run() { [[ "${CHECKS[0]}" == "all" ]] || [[ " ${CHECKS[*]} " == *" $1 "* ]]; }

# --- Helpers ---

to_millicpu() {
  local val=$1
  if [[ "$val" =~ ^([0-9]+)m$ ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$val" =~ ^([0-9]+)$ ]]; then echo $(( val * 1000 ))
  else echo 0; fi
}

to_bytes() {
  local val=$1
  if [[ "$val" =~ ^([0-9]+)$ ]]; then echo "$val"
  elif [[ "$val" =~ ^([0-9]+)k$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1000 ))
  elif [[ "$val" =~ ^([0-9]+)Ki$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1024 ))
  elif [[ "$val" =~ ^([0-9]+)M$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1000000 ))
  elif [[ "$val" =~ ^([0-9]+)Mi$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1048576 ))
  elif [[ "$val" =~ ^([0-9]+)G$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1000000000 ))
  elif [[ "$val" =~ ^([0-9]+)Gi$ ]]; then echo $(( ${BASH_REMATCH[1]} * 1073741824 ))
  else echo 0; fi
}

pct() {
  local used=$1 hard=$2
  if [[ "$hard" -eq 0 ]]; then echo "  -"; return; fi
  awk "BEGIN { printf \"%3d%%\", ($used / $hard) * 100 }"
}

# --- Check: Quota ---

check_quota() {
  echo "--- Quota Usage ---"
  echo "  \$ oc get clusterresourcequota tenant-user-GUID -o yaml"
  echo ""
  printf "  %-14s  %6s  %6s  %6s  %6s  %6s\n" "TENANT" "R.CPU" "R.MEM" "L.CPU" "L.MEM" "STOR"

  while IFS= read -r tenant; do
    local yaml
    yaml=$(oc get clusterresourcequota "tenant-${tenant}" -o yaml 2>/dev/null)
    if [[ -z "$yaml" ]]; then
      printf "  %-14s  quota not found\n" "$tenant"
      continue
    fi

    local total hard used
    total=$(echo "$yaml" | sed -n '/^  total:/,/^  [^ ]/p')
    hard=$(echo "$total" | sed -n '/^    hard:/,/^    used:/p')
    used=$(echo "$total" | sed -n '/^    used:/,$p')

    get_h() { echo "$hard" | grep "^\s*$1:" | head -1 | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/'; }
    get_u() { echo "$used" | grep "^\s*$1:" | head -1 | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/'; }

    local rc_p rm_p lc_p lm_p st_p
    rc_p=$(pct "$(to_millicpu "$(get_u requests.cpu)")" "$(to_millicpu "$(get_h requests.cpu)")")
    rm_p=$(pct "$(to_bytes "$(get_u requests.memory)")" "$(to_bytes "$(get_h requests.memory)")")
    lc_p=$(pct "$(to_millicpu "$(get_u limits.cpu)")" "$(to_millicpu "$(get_h limits.cpu)")")
    lm_p=$(pct "$(to_bytes "$(get_u limits.memory)")" "$(to_bytes "$(get_h limits.memory)")")
    st_p=$(pct "$(to_bytes "$(get_u requests.storage)")" "$(to_bytes "$(get_h requests.storage)")")

    printf "  %-14s  %6s  %6s  %6s  %6s  %6s\n" "$tenant" "$rc_p" "$rm_p" "$lc_p" "$lm_p" "$st_p"
  done <<< "$TENANTS"
  echo ""
}

# --- Check: Travel Portal ---

check_travel() {
  echo "--- Travel Portal -> Travels VM ---"
  echo "  \$ oc -n user-GUID-travel-portal exec <travels-pod> -- curl -s travels-vm.user-GUID-travel-agency.svc.cluster.local:8000/travels/London"
  echo ""

  while IFS= read -r tenant; do
    local ns="${tenant}-travel-portal"
    local target="travels-vm.${tenant}-travel-agency.svc.cluster.local:8000/travels/London"

    local pod
    pod=$(oc -n "$ns" get po -l app=travels -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "$pod" ]]; then
      printf "  %-14s  SKIP  no travels pod in %s\n" "$tenant" "$ns"
      continue
    fi

    local response
    response=$(oc -n "$ns" exec "$pod" -- curl -s "$target" 2>/dev/null)

    if [[ $? -ne 0 ]] || [[ -z "$response" ]]; then
      printf "  %-14s  FAIL  curl error or empty response\n" "$tenant"
      continue
    fi

    local oneline
    oneline=$(echo "$response" | tr -s '[:space:]' ' ' | cut -c1-120)
    printf "  %-14s  OK    %s\n" "$tenant" "$oneline"
  done <<< "$TENANTS"
  echo ""
}

# --- Run selected checks ---

if should_run quota; then check_quota; fi
if should_run travel; then check_travel; fi

echo "=============================="
echo " Done."
echo "=============================="

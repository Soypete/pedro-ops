#!/usr/bin/env bash
set -euo pipefail

PROM_PROXY='/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy'

# Jobs where EVERY target must be up.
EXPECTED=(openbao kei-abac kei-oidc kei-web postgres-exporter-kei postgres-exporter-chatbot redis-exporter)

# Jobs where AT LEAST ONE target must be up.
#
# llama-cpp: pedrogpt runs a llama.cpp router with --models-max 1, so only one model
# is resident at a time and scrapes pass autoload=false (so Prometheus cannot force-load
# ~18 GB just to collect metrics). The idle model's target returns HTTP 400 and reads
# down as NORMAL steady state. Requiring all-up here would fail by design after every
# model switch; requiring at-least-one-up still catches a dead router.
EXPECTED_ANY=(llama-cpp)

TARGETS="$(kubectl get --raw "$PROM_PROXY/api/v1/targets")"
failed=0

for job in "${EXPECTED[@]}"; do
  health="$(jq -r --arg job "$job" '[.data.activeTargets[] | select(.labels.job == $job) | .health] | if length == 0 then "missing" elif all(. == "up") then "up" else join(",") end' <<<"$TARGETS")"
  printf '%-28s %s\n' "$job" "$health"
  [ "$health" = up ] || failed=1
done

for job in "${EXPECTED_ANY[@]}"; do
  summary="$(jq -r --arg job "$job" '
    [.data.activeTargets[] | select(.labels.job == $job)] as $t
    | if ($t | length) == 0 then "missing"
      else ([$t[] | select(.health == "up")] | length | tostring) + "/" + ($t | length | tostring) + " up"
      end' <<<"$TARGETS")"
  printf '%-28s %s\n' "$job" "$summary"
  case "$summary" in
    missing|0/*) failed=1 ;;
  esac
done

for resource in \
  configmap/pedro-observability-dashboards \
  prometheusrule.monitoring.coreos.com/pedro-observability \
  alertmanagerconfig.monitoring.coreos.com/discord; do
  kubectl -n monitoring get "$resource" >/dev/null || failed=1
done

exit "$failed"

#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-longhorn-system}"
DOMAIN="${1:-${DOMAIN:-longhorn.io}}"
CSI_DRIVER="${CSI_DRIVER:-driver.longhorn.io}"
KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:-10s}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

exists() {
  kubectl get "$@" >/dev/null 2>&1
}

delete_if_exists() {
  kubectl delete "$@" --ignore-not-found
}

delete_if_exists_nowait() {
  kubectl delete "$@" --ignore-not-found --wait=false
}

delete_named_resources() {
  local resource name

  resource="$1"
  shift

  for name in "$@"; do
    kubectl delete "$resource" "$name" --request-timeout="$KUBECTL_TIMEOUT" \
      --ignore-not-found >/dev/null 2>&1 || true
  done
}

remove_json_finalizers() {
  kubectl patch "$@" --request-timeout="$KUBECTL_TIMEOUT" --type=merge \
    -p='{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
}

patch_namespaced_resource_finalizers() {
  local api line ns name

  api="$1"
  while read -r ns name; do
    [[ -n "$ns" && -n "$name" && "$ns" != "<none>" ]] || continue
    remove_json_finalizers "$api" "$name" -n "$ns"
  done < <(
    kubectl get "$api" -A --request-timeout="$KUBECTL_TIMEOUT" --no-headers \
      -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name 2>/dev/null || true
  )
}

patch_cluster_resource_finalizers() {
  local api name

  api="$1"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    remove_json_finalizers "$api" "$name"
  done < <(
    kubectl get "$api" --request-timeout="$KUBECTL_TIMEOUT" --no-headers \
      -o custom-columns=NAME:.metadata.name 2>/dev/null || true
  )
}

delete_all_namespaced_resources_in_namespace() {
  local apis api

  apis=(
    deployments.apps
    daemonsets.apps
    statefulsets.apps
    replicasets.apps
    jobs.batch
    cronjobs.batch
    pods
    services
    endpoints
    persistentvolumeclaims
    configmaps
    secrets
    serviceaccounts
    roles.rbac.authorization.k8s.io
    rolebindings.rbac.authorization.k8s.io
    ingresses.networking.k8s.io
    networkpolicies.networking.k8s.io
    poddisruptionbudgets.policy
    leases.coordination.k8s.io
  )

  for api in "${apis[@]}"; do
    log "Deleting $api in namespace $NS"
    kubectl delete "$api" --all -n "$NS" --request-timeout="$KUBECTL_TIMEOUT" \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
}

delete_longhorn_api_resources() {
  local crds crd scope

  mapfile -t crds < <(
    kubectl get crd --request-timeout="$KUBECTL_TIMEOUT" --no-headers \
      -o custom-columns=NAME:.metadata.name,SCOPE:.spec.scope 2>/dev/null \
      | awk -v domain="$DOMAIN" '$1 ~ "\\." domain "$" {print $1, $2}' || true
  )

  for line in "${crds[@]}"; do
    read -r crd scope <<< "$line"
    [[ -n "$crd" ]] || continue

    if [[ "$scope" == "Namespaced" ]]; then
      log "Removing finalizers from $crd resources"
      patch_namespaced_resource_finalizers "$crd"
      log "Deleting $crd resources"
      kubectl delete "$crd" --all -A --request-timeout="$KUBECTL_TIMEOUT" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
    else
      log "Removing finalizers from $crd resources"
      patch_cluster_resource_finalizers "$crd"
      log "Deleting $crd resources"
      kubectl delete "$crd" --all --request-timeout="$KUBECTL_TIMEOUT" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true
    fi
  done
}

finalize_namespace_if_stuck() {
  local phase

  if ! exists namespace "$NS"; then
    return 0
  fi

  phase="$(kubectl get namespace "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" != "Terminating" ]]; then
    return 0
  fi

  log "Namespace $NS is stuck in Terminating; removing namespace finalizers"
  kubectl patch namespace "$NS" --type=merge -p '{"spec":{"finalizers":[]}}' >/dev/null 2>&1 || true

  if exists namespace "$NS"; then
    log "Namespace still exists after patch; using /finalize API"
    tmp="$(mktemp)"
    kubectl get namespace "$NS" -o json \
      | sed 's/"finalizers": *\[[^]]*\]/"finalizers": []/' > "$tmp"
    kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f "$tmp" >/dev/null || true
    rm -f "$tmp"
  fi
}

log "Deleting broken Longhorn webhooks"
delete_named_resources validatingwebhookconfiguration \
  longhorn-webhook-validator \
  longhorn-webhook-admission \
  longhorn-admission-webhook
delete_named_resources mutatingwebhookconfiguration \
  longhorn-webhook-mutator \
  longhorn-webhook-admission \
  longhorn-admission-webhook

log "Removing finalizers and deleting all $DOMAIN custom resources"
delete_longhorn_api_resources

log "Deleting Longhorn namespaced workloads"
delete_all_namespaced_resources_in_namespace

log "Deleting Longhorn cluster-scoped resources"
delete_if_exists storageclass.storage.k8s.io disk-default longhorn longhorn-static longhorn-retain
delete_if_exists csidriver.storage.k8s.io "$CSI_DRIVER"
delete_if_exists clusterrole.rbac.authorization.k8s.io longhorn-uninstall-role
delete_if_exists clusterrolebinding.rbac.authorization.k8s.io longhorn-uninstall-bind
kubectl get storageclass.storage.k8s.io -o name 2>/dev/null \
  | grep -E '(^|/)longhorn|longhorn$' \
  | xargs -r kubectl delete --ignore-not-found >/dev/null 2>&1 || true
kubectl get storageclass.storage.k8s.io --no-headers \
  -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner 2>/dev/null \
  | awk -v driver="$CSI_DRIVER" '$2 == driver {print $1}' \
  | xargs -r kubectl delete storageclass.storage.k8s.io --ignore-not-found >/dev/null 2>&1 || true
kubectl get clusterrole.rbac.authorization.k8s.io,clusterrolebinding.rbac.authorization.k8s.io \
  -l app=longhorn-manager -o name 2>/dev/null \
  | xargs -r kubectl delete --ignore-not-found >/dev/null 2>&1 || true
kubectl get clusterrole.rbac.authorization.k8s.io,clusterrolebinding.rbac.authorization.k8s.io \
  -o name 2>/dev/null \
  | grep 'longhorn' \
  | xargs -r kubectl delete --ignore-not-found >/dev/null 2>&1 || true

log "Deleting remaining $DOMAIN CRDs"
mapfile -t longhorn_crds < <(kubectl get crd -o name 2>/dev/null | grep "$DOMAIN" || true)
if ((${#longhorn_crds[@]} > 0)); then
  delete_if_exists_nowait "${longhorn_crds[@]}"
fi

log "Deleting namespace $NS"
delete_if_exists_nowait namespace "$NS"

log "Waiting briefly for namespace deletion"
kubectl wait --for=delete "namespace/$NS" --timeout=30s >/dev/null 2>&1 || true
finalize_namespace_if_stuck

log "Final check"
kubectl get namespace "$NS" 2>/dev/null || true
kubectl get storageclass,csidriver,validatingwebhookconfiguration,mutatingwebhookconfiguration,clusterrole,clusterrolebinding,crd \
  2>/dev/null | grep -E "longhorn|$CSI_DRIVER|$DOMAIN" || true

log "Cleaning up w7panel resources"
kubectl delete appgroups.w7panel.w7.com/w7panel-longhorn --wait=false --ignore-not-found
kubectl delete helmcharts/longhorn -n kube-system --wait=false --ignore-not-found
log "Done"

#!/usr/bin/env bash
set -euo pipefail

NS="${NS:-longhorn-system}"

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

patch_remove_finalizers() {
  local resource

  for resource in "$@"; do
    if kubectl get "$resource" -n "$NS" >/dev/null 2>&1; then
      kubectl patch "$resource" -n "$NS" --type=json \
        -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
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
delete_if_exists validatingwebhookconfiguration longhorn-webhook-validator
delete_if_exists mutatingwebhookconfiguration longhorn-webhook-mutator

log "Removing finalizers from remaining Longhorn custom resources"
mapfile -t longhorn_resources < <(
  kubectl get \
    volumes.longhorn.io,nodes.longhorn.io,engineimages.longhorn.io,volumeattachments.longhorn.io \
    -n "$NS" -o name 2>/dev/null || true
)
if ((${#longhorn_resources[@]} > 0)); then
  patch_remove_finalizers "${longhorn_resources[@]}"
fi

log "Deleting remaining Longhorn custom resources"
kubectl delete \
  volumes.longhorn.io,nodes.longhorn.io,engineimages.longhorn.io,volumeattachments.longhorn.io \
  --all -n "$NS" --ignore-not-found --wait=false 2>/dev/null || true

log "Deleting Longhorn namespaced workloads"
delete_if_exists_nowait daemonset.apps/engine-image-ei-75a03ec3 -n "$NS"
delete_if_exists_nowait daemonset.apps/longhorn-csi-plugin -n "$NS"
delete_if_exists_nowait deployment.apps/csi-attacher -n "$NS"
delete_if_exists_nowait deployment.apps/csi-provisioner -n "$NS"
delete_if_exists_nowait deployment.apps/csi-resizer -n "$NS"
delete_if_exists_nowait deployment.apps/csi-snapshotter -n "$NS"
delete_if_exists_nowait job.batch/longhorn-uninstall -n "$NS"

log "Deleting Longhorn cluster-scoped resources"
delete_if_exists storageclass.storage.k8s.io disk-default longhorn longhorn-static
delete_if_exists csidriver.storage.k8s.io driver.longhorn.io
delete_if_exists clusterrole.rbac.authorization.k8s.io longhorn-uninstall-role
delete_if_exists clusterrolebinding.rbac.authorization.k8s.io longhorn-uninstall-bind

log "Deleting remaining Longhorn CRDs"
mapfile -t longhorn_crds < <(kubectl get crd -o name | grep 'longhorn.io' || true)
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
  2>/dev/null | grep -E 'longhorn|driver.longhorn.io' || true

log "Done"

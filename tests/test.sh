#!/bin/bash
# 从历史版本中重建appgroup 

./forceclear.sh # 清理longhorn

kubectl apply -f ./longhorn-1.10.1.yaml # 重新部署longhorn 模拟历史版本中已经安装longhorn 

VERSION=1.10.1

for resource in \
  daemonset/longhorn-iscsi-installation \
  daemonset/longhorn-nfs-installation \
  helmchart/longhorn
do
  if ! kubectl -n kube-system get "$resource" >/dev/null 2>&1; then
    echo "skip missing resource: $resource"
    continue
  fi

  kubectl -n kube-system label "$resource" \
    app.kubernetes.io/managed-by=Helm \
    --overwrite

  kubectl -n kube-system annotate "$resource" \
    meta.helm.sh/release-name=w7panel-longhorn \
    meta.helm.sh/release-namespace=default \
    --overwrite
done

helm upgrade w7panel-longhorn "https://cdn.w7.cc/w7panel/charts/longhorn/w7panel-longhorn-${VERSION}.tgz" --install
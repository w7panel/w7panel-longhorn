## Adopt existing resources into this Helm release

If `helm upgrade w7panel-longhorn ./w7panel-longhorn` fails because one of
these resources already exists without Helm ownership metadata, patch the live
resource before rerunning the upgrade:

```
for resource in \
  daemonset/longhorn-iscsi-installation \
  daemonset/longhorn-nfs-installation \
  helmchart/longhorn
do
  kubectl -n kube-system label "$resource" \
    app.kubernetes.io/managed-by=Helm \
    --overwrite

  kubectl -n kube-system annotate "$resource" \
    meta.helm.sh/release-name=w7panel-longhorn \
    meta.helm.sh/release-namespace=default \
    --overwrite
done
```

Then rerun:

```
helm upgrade w7panel-longhorn ./w7panel-longhorn
```

## Longhorn uninstall confirmation

```
kubectl -n longhorn-system patch -p '{"value": "true"}' --type=merge lhs deleting-confirmation-flag

```
# Longhorn
复查后发现 live 对象还是 1.10.1。原因更具体了：Helm release 记录已经是 1.11.1，后续普通 helm upgrade 做三方 diff 时认为 desired 没变，无法修复这个 live drift。现在需要
  强制替换或直接 patch live HelmChart。

# 地址 
https://charts.longhorn.io/index.yaml
https://github.com/longhorn/charts/releases/download/longhorn-1.11.1/longhorn-1.11.1.tgz

# helmPack
helm package ./charts/w7panel-longhorn --app-version 1.11.1 --version 1.11.1
helm package ./charts/w7panel-longhorn --app-version 1.11.2 --version 1.11.2
helm package ./charts/w7panel-longhorn --app-version 1.12.0 --version 1.12.0


# 卸载
kubectl create -f https://raw.githubusercontent.com/longhorn/longhorn/v1.11.1/uninstall/uninstall.yaml

# 卸载pod Error问题

 kubectl logs pod/longhorn-uninstall-nwj5k -n longhorn-system
  └ W0617 07:49:48.601739       1 client_config.go:682] Neither --kubeconfig nor --master was specified.  Using the inClusterConfig.  This might not work.
    I0617 07:49:49.808066       1 shared_informer.go:349] "Waiting for caches to sync" controller="longhorn uninstall"
    … +20 lines (ctrl + t to view transcript)
    time="2026-06-17T07:49:50.50871698Z" level=fatal msg="cannot uninstall Longhorn because deleting-confirmation-flag is set to `false`. Please set it to `true` using Longhorn UI or kubectl
    -n longhorn-system edit settings.longhorn.io deleting-confirmation-flag " func=main.main.UninstallCmd.func7 file="uninstall.go:48"

日志里已经出现明确 fatal：deleting-confirmation-flag 还是 false，Longhorn 卸载器会主动退出。前面那些 could not find the requested resource 多半是 CRD 已经部分删除后的噪声，真正让 Pod 变
  Error 的是确认开关没打开
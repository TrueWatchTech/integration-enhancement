# DataKit Environment Cleanup Guide

> Scope: complete removal of DataKit from an environment after testing or a POC.
> Three installation methods are covered: **host install**, **K8s YAML install**, and **Helm install**.
> If a single machine was provisioned by more than one method (for example, a host install added by script on a K8s node), each must be cleaned up independently.

---

## 1. Host Install Cleanup

DataKit provides the `datakit service -U` command for uninstallation. To preserve configuration for a possible future reinstall, this command retains the installation directory, log directory, symlinks, and—if APM auto-instrumentation was enabled at install time—certain system-level modifications. If you do not intend to use DataKit in this environment again, use the cleanup script `datakit-uninstall-clean.sh` for complete removal.

### Using the Script

```bash
# 1) Dry run first to review what will be cleaned up
sudo bash datakit-uninstall-clean.sh --dry-run

# 2) Execute
sudo bash datakit-uninstall-clean.sh
```

The script first invokes `datakit service -U` for the official uninstall, then **inspects and removes the remaining directories, configuration entries, and injection changes item by item** (anything already removed by `-U` is skipped, with no redundant operations), and finally verifies that no residue remains.

Cleanup coverage:

- Services: `datakit`, `dk_upgrader` (the upgrade manager bundled by default)
- Installation directories: `/usr/local/datakit`, `/usr/local/dk_upgrader`
- Log directories: `/var/log/datakit`, `/var/log/dk_upgrader`
- Binary symlinks under `/usr/local/bin`, `/usr/local/sbin`, `/sbin`, `/usr/sbin`, `/usr/bin`
- Residual processes: host processes are terminated; containerized processes (K8s Pods) are reported only and never killed
- APM host-injection residue (only if `DK_APM_INSTRUMENTATION_ENABLED` was set at install time): the injection line in `/etc/ld.so.preload` is removed precisely (the file itself is preserved); `/etc/docker/daemon.json` and PHP `conf.d/*.ini` are detected and flagged for manual restoration

> Supported platforms: Linux (Ubuntu / RHEL / CentOS family), x86_64 or arm64, with systemd / SysV auto-detected. Not applicable to macOS or Windows.

For a fully manual process, or if you prefer not to run the script, follow the steps below.

### Manual Cleanup

```bash
# 1) Uninstall the service
datakit service -T   # stop
datakit service -U   # uninstall

# 2) Remove residual directories and symlinks
sudo rm -rf /usr/local/datakit /usr/local/dk_upgrader
sudo rm -rf /var/log/datakit  /var/log/dk_upgrader
sudo rm -f  /usr/local/bin/datakit /usr/local/sbin/datakit /sbin/datakit /usr/sbin/datakit /usr/bin/datakit

# 3) Confirm no residual process remains
ps -ef | grep -i '[d]atakit'
```

> Note: if a static IP + domain mapping was used during installation (dedicated line / offline install), the install script may have appended an entry to `/etc/hosts`. Verify manually:
> `grep -nEi 'openway|dataway|truewatch' /etc/hosts`

---

## 2. K8s YAML Install Cleanup

A `datakit.yaml` install creates the following seven objects:

| Type | Name | Namespace |
|---|---|---|
| Namespace | `datakit` | — |
| ClusterRole | `datakit` | cluster-scoped |
| ClusterRoleBinding | `datakit` | cluster-scoped |
| ServiceAccount | `datakit` | datakit |
| Service | `datakit-service` | datakit |
| DaemonSet | `datakit` | datakit |
| ConfigMap | `datakit-conf` | datakit |

### Case 1: Uninstall Using datakit.yaml

```bash
kubectl delete -f datakit.yaml
```

`kubectl delete -f` also accepts the same URL used at install time (deletion matches by object name, so minor version differences do not affect the result):

```bash
kubectl delete -f <the datakit.yaml URL used at install time>
```

For installs that strictly follow the official TrueWatch documentation, the `datakit.yaml` URL is typically:
https://static.truewatch.com/datakit-v2/datakit.yaml

### Case 2: datakit.yaml Is Unavailable

Delete by namespace plus the cluster-scoped objects—three commands:

```bash
kubectl delete namespace datakit
kubectl delete clusterrole datakit
kubectl delete clusterrolebinding datakit
```

> **Important**: The DaemonSet, Service, ServiceAccount, and ConfigMap all reside in the `datakit` namespace and are removed when the namespace is deleted. However, the **ClusterRole and ClusterRoleBinding are cluster-scoped objects**; deleting the namespace does not remove them, so they must be deleted explicitly.

Object names can be confirmed beforehand:

```bash
kubectl get all,cm,sa -n datakit
kubectl get clusterrole,clusterrolebinding | grep -i datakit
```

---

## 3. Helm Install Cleanup

```bash
helm uninstall datakit -n datakit
kubectl delete namespace datakit
```

`helm uninstall` removes the resources it installed by release, with no original YAML required. Deleting the namespace afterward ensures no residue remains. The release name can be confirmed first:

```bash
helm list -n datakit
```

---

## FAQ

- **Deleting the namespace is not a complete cleanup**: the cluster-scoped ClusterRole and ClusterRoleBinding are not part of the namespace and must be deleted separately (see Section 2).
- **Mixed installs on one machine**: when a host install was added by script on a K8s node, the host install and the DaemonSet must be cleaned up separately—the host script cannot remove a Pod, and kubectl cannot remove host files.

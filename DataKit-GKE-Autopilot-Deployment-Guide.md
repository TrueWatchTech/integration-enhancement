# Deploying TrueWatch DataKit on GKE Autopilot

This guide covers deploying TrueWatch DataKit on a Google Kubernetes Engine (GKE) Autopilot cluster: prerequisites, installation, verification, and troubleshooting. Official reference: https://docs.truewatch.com/datakit/gcp-gke-autopilot/

## 1. Scope and Version Requirements

- Applies to **GKE Autopilot** clusters.
- Requires **DataKit 2.3.0 or later**. Collecting container metrics, objects, and logs through the GCP Cloud API was introduced in 2.3.0; earlier versions do not support Autopilot mode.
- You need `kubectl` admin access to the target cluster and IAM permissions on the corresponding GCP project.

## 2. What DataKit Can and Cannot Collect

GKE Autopilot manages its own nodes and blocks privileged containers, hostPath mounts, host-log access, and host networking (hostNetwork/hostPID/hostIPC). DataKit therefore cannot run as a traditional per-node DaemonSet. Instead, it runs as a **single-replica Deployment** and collects data through the **GCP Cloud API**.

**Collected data:**

- Container metrics — from Cloud Monitoring, written to the `docker_containers` metric set.
- Container stdout/stderr logs — from Cloud Logging.
- Kubernetes resource metrics and objects — from the Kubernetes API. This includes nodes (metric `kube_node` / object `kubernetes_nodes`), Pods (object `kubelet_pod`), and Deployments, Services, StatefulSets, DaemonSets, and ReplicaSets. **Pod-level metrics (`kube_pod` CPU/memory) are not collected by default**; enable `ENV_INPUT_CONTAINER_ENABLE_POD_METRIC` (see "Key Configuration" → Pod-level metrics).

**Not collected in this mode:**

- **Host metric set.** The host collectors (`cpu`, `mem`, `disk`, `net`) require host access. Autopilot nodes are Google-managed and DataKit does not run host collectors on them, so this mode produces no host metrics. Do not confuse this with Kubernetes node metrics: the `kube_node` metric and the `kubernetes_nodes` object are collected normally and appear under Infrastructure → Resource Catalog → Kubernetes → Nodes. (In a standard K8s cluster, nodes usually appear as Hosts instead.)
- **Container-runtime-socket collection.** Autopilot blocks access to the container runtime socket, so this is unavailable.
- **In-container log files** (log files not written to stdout/stderr). Not collected by default — only stdout/stderr is collected, via Cloud Logging. To collect in-container log files, deploy a **logfwd sidecar** that reads the files and forwards them to the DataKit logfwdserver (default port 9533). This works on Autopilot using an emptyDir shared volume and a sidecar (no host access required); enable the logfwdserver input and expose port 9533 through a Service.
- **eBPF-based collection.** Requires kernel capabilities and privileges; not available in this version.

**Expected behavior (normal, not faults):**

- Cloud Monitoring metrics arrive with a delay of several minutes. Lagging data in the platform is expected.
- Log delivery is **at-least-once**. During Pod replacement or leader failover, logs in the overlapping time window may be re-read. The system deduplicates by `timestamp + insertId`, so normal polling produces no duplicates.
- Kubernetes object collection runs on a per-minute cycle, and platform views add refresh latency. After installation, allow a few minutes for the data to appear.

## 3. Shell Variables

All commands below use the following shell variables. Set them to your environment's values and run this block first, **in the same terminal session**. Later commands can then be copied and run as-is, with no placeholder substitution.

```bash
export PROJECT_ID="my-project"                 # GCP project ID
export REGION="asia-southeast1"                # cluster region (Autopilot is regional)
export CLUSTER_NAME="my-autopilot-cluster"     # GKE Autopilot cluster name

export NAMESPACE="datakit"                     # deployment namespace (customizable; default "datakit" recommended)
export RELEASE_NAME="datakit"                  # Helm release name (customizable)
export GSA_NAME="datakit-cloud-monitor"        # GCP service account name (GSA; customizable)

export KSA_NAME="datakit"                       # Kubernetes ServiceAccount name (set by the chart's fullnameOverride; default "datakit")

export DATAWAY_URL="https://<dataway-host>?token=<TOKEN>"   # token-bearing DataWay address (get the full domain from your workspace administrator)

# Derived from the variables above; do not edit
export GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
```

> `KSA_NAME` is the Kubernetes ServiceAccount name. It must match in three places: the annotation in Helm install (Step 3) and the Workload Identity binding (Step 4). It defaults to `datakit`.

## 4. Prerequisites

Confirm each item before deploying. When you run gcloud commands, you may see an auxiliary-call warning containing `404`; it does not affect the command result and can be ignored.

### Prerequisite 1: A GKE Autopilot cluster with Workload Identity enabled

DataKit authenticates to GCP APIs through Workload Identity, so the cluster must be Autopilot with Workload Identity enabled (Autopilot enables it by default).

Check that the cluster is Autopilot:

```bash
gcloud container clusters describe "$CLUSTER_NAME" --region "$REGION" \
  --format="value(autopilot.enabled)"
```

- **Expected:** the output is `True`.

Check that Workload Identity is enabled:

```bash
gcloud container clusters describe "$CLUSTER_NAME" --region "$REGION" \
  --format="value(workloadIdentityConfig.workloadPool)"
```

- **Expected:** the output is `${PROJECT_ID}.svc.id.goog` (any non-empty value means it is enabled).

**If not met:** Autopilot clusters enable Workload Identity by default, so this usually needs no action. If the output is empty, enable Workload Identity in the cluster configuration first, then complete the ServiceAccount-to-GSA binding during deployment (Step 4: Workload Identity binding).

### Prerequisite 2: A reachable TrueWatch DataWay address

Have the token-bearing DataWay address ready (form: `https://<dataway-host>?token=<TOKEN>`), i.e., the `DATAWAY_URL` variable. You use it during Helm install (Step 3).

### Prerequisite 3: Cloud Monitoring API and Cloud Logging API enabled

DataKit uses these two APIs to collect container metrics and logs. Enable them at the project level.

```bash
gcloud services list --enabled --project "$PROJECT_ID" \
  --filter="config.name:(monitoring.googleapis.com OR logging.googleapis.com)"
```

- **Expected:** the output lists both `monitoring.googleapis.com` and `logging.googleapis.com`. If either is missing, it is not enabled.

**If not met:** run Step 1 (Enable required GCP APIs) during deployment.

### Prerequisite 4: A GCP service account (GSA) with the required roles

DataKit needs a GSA with the least-privilege roles `roles/monitoring.viewer` and `roles/logging.viewer`. Missing either role prevents metric or log collection. Choose one of the two cases below.

#### Case A: Fresh install (recommended)

No check is needed here. Keep the `GSA_NAME` variable (for example, `datakit-cloud-monitor`), and create and authorize the account during Step 2 (Create and authorize the GCP service account). Skip the checks below and proceed to deployment.

#### Case B: Reuse an existing service account

Run the following checks only when reusing an existing service account, to confirm it exists and has both roles.

First, list the existing service accounts and identify the one to reuse:

```bash
gcloud iam service-accounts list --project "$PROJECT_ID"
```

In the `EMAIL` column (for example, `datakit-cloud-monitor@<PROJECT_ID>.iam.gserviceaccount.com`), take the part before `@` as the account name and set the variable:

```bash
export GSA_NAME="<account-name-to-reuse>"
# After changing GSA_NAME, re-derive GSA_EMAIL, otherwise later checks still point to the old account
export GSA_EMAIL="${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
```

Check that the GSA exists:

```bash
gcloud iam service-accounts describe "$GSA_EMAIL" --project "$PROJECT_ID"
```

- **Expected:** it returns the account's `email`, `displayName`, and so on. `NOT_FOUND` means the account does not exist.

Check the roles granted to the GSA:

```bash
gcloud projects get-iam-policy "$PROJECT_ID" \
  --flatten="bindings[].members" \
  --filter="bindings.members:serviceAccount:$GSA_EMAIL" \
  --format="table(bindings.role)"
```

- **Expected:** the role list includes both `roles/monitoring.viewer` and `roles/logging.viewer`.

**If not met:** if the account exists but lacks a role, add it using the grant commands in Step 2 (Create and authorize the GCP service account). If the account does not exist or is unsuitable for reuse, create a new one as in Case A.

### Prerequisite 5: Plan the namespace and ServiceAccount name

Confirm the `NAMESPACE` and `KSA_NAME` variables (both default to `datakit`). This name must match the annotation in Helm install (Step 3) and the Workload Identity binding (Step 4).

## 5. Deployment (Helm, recommended)

All commands use the variables defined in Section 3, Shell Variables. Before you start, make sure you have run every `export` from that section in the current terminal session.

### Step 1: Enable required GCP APIs

> **Whether to run this step:** if both the Cloud Monitoring and Cloud Logging APIs are already enabled (see the check in Prerequisite 3), skip this step and go straight to creating the service account (Step 2: Create and authorize the GCP service account). Otherwise, run the command below. It is idempotent, so re-running has no side effects.

```bash
gcloud services enable monitoring.googleapis.com logging.googleapis.com --project "$PROJECT_ID"
```

### Step 2: Create and authorize the GCP service account

> **Whether to run this step:**
> - **Fresh install:** run the whole step (create the account and grant both roles).
> - **Reusing a GSA that already has `roles/monitoring.viewer` and `roles/logging.viewer`** (see the reuse check in Prerequisite 4): skip this step and go to Helm install (Step 3).
> - **Reusing a GSA that is missing a role:** skip the "Create the GSA" command below and run only the two `add-iam-policy-binding` commands to add the missing role. Make sure `GSA_NAME` is set to the existing account name.

> **Required permissions:** this step, together with enabling APIs (Step 1) and the Workload Identity binding (Step 4), are **project-level GCP IAM operations**. They require higher privileges than ordinary GKE operations:
> - Create a service account and bind it for Workload Identity: `roles/iam.serviceAccountAdmin`
> - Grant project-level roles (`monitoring.viewer` / `logging.viewer`): `roles/resourcemanager.projectIamAdmin` (or project `roles/owner`)
> - Enable APIs (Step 1): `roles/serviceusage.serviceUsageAdmin`
>
> Users with only GKE permissions (such as `roles/container.developer` or `roles/container.admin`) usually cannot perform these operations, and the commands return `PERMISSION_DENIED`. In that case, ask a GCP project Owner or IAM administrator (Project IAM Admin) to perform these project-level operations (enable APIs, create and authorize the service account, and the Workload Identity binding), or to grant you the roles above temporarily. GKE cluster-admin (container.admin) does not include project-level IAM permissions; confirm the two separately.

```bash
# Create the GSA
gcloud iam service-accounts create "$GSA_NAME" \
  --project "$PROJECT_ID" \
  --display-name "TrueWatch DataKit GKE Autopilot"

# Grant read-only monitoring and logging roles
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:$GSA_EMAIL" \
  --role roles/monitoring.viewer

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:$GSA_EMAIL" \
  --role roles/logging.viewer
```

### Step 3: Install DataKit with Helm

Use the dedicated chart `datakit-gke-autopilot` (distinct from the standard `datakit` chart):

```bash
helm repo add datakit-gke https://pubrepo.truewatch.com/chartrepo/truewatch
helm repo update

helm install "$RELEASE_NAME" datakit-gke/datakit-gke-autopilot \
  --namespace "$NAMESPACE" --create-namespace \
  --set datakit.dataway_url="$DATAWAY_URL" \
  --set serviceAccountAnnotations."iam\.gke\.io/gcp-service-account"="$GSA_EMAIL"
```

> The `--set` above adds the Workload Identity annotation to the Kubernetes ServiceAccount. This completes only the Kubernetes-side annotation; **the GCP-side IAM binding must be done in the next step (Step 4: Workload Identity binding)**.

### Step 4: Complete the Workload Identity binding (required)

Establish trust between the Kubernetes ServiceAccount (`$NAMESPACE/$KSA_NAME`) and the GCP service account. Helm cannot create the GCP IAM binding, so run this manually:

```bash
gcloud iam service-accounts add-iam-policy-binding "$GSA_EMAIL" \
  --project "$PROJECT_ID" \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:$PROJECT_ID.svc.id.goog[$NAMESPACE/$KSA_NAME]"
```

> The member format is `<PROJECT_ID>.svc.id.goog[<namespace>/<ServiceAccount>]`. If you changed the release name or `fullnameOverride` at install time, the ServiceAccount name changes accordingly. Update `KSA_NAME` and make sure the annotation from Step 3 (Helm install) matches this binding; otherwise the binding is invalid and no data is reported.

### Step 5: Verify the deployment

```bash
# Confirm the Pod is Running
kubectl get pods -n "$NAMESPACE"

# Check the logs to confirm Cloud API connectivity and no auth errors
kubectl logs -n "$NAMESPACE" deploy/"$KSA_NAME" --tail 100
```

Then confirm in the TrueWatch console that container data (`docker_containers`), Kubernetes objects, and logs appear in Infrastructure over time (Cloud Monitoring has a delay of several minutes).

## 6. Optional: Deploy with YAML

If you prefer not to use Helm, download the dedicated YAML:

```bash
curl -o datakit-gke-autopilot.yaml https://static.truewatch.com/datakit/datakit-gke-autopilot.yaml
```

Edit the file: set `ENV_DATAWAY` to your DataWay address, and add the Workload Identity annotation (`iam.gke.io/gcp-service-account`) to the ServiceAccount. Then run `kubectl apply -f datakit-gke-autopilot.yaml`. The GCP-side IAM binding (Step 4) is still required.

## 7. Key Configuration

- **Default workload:** a single-replica Deployment with election enabled.
- **Keep election enabled.** If you scale to multiple replicas for high availability, keep `datakit.enabled_election=true`. Disabling election makes multiple replicas collect through the Cloud API at the same time, producing duplicate data.
- **Default enabled inputs:** `dk` and `container`; `ENV_INPUT_CONTAINER_GCP_CLOUD_API_ENABLED=true` and `ENV_INPUT_CONTAINER_ENABLE_K8S_NODE_LOCAL=false`.
- **Pod-level metrics (optional).** The `kube_pod` metric set (Pod CPU/memory time series) is not collected by default. Set `ENV_INPUT_CONTAINER_ENABLE_POD_METRIC=true` and restart to enable it. The Pod object (`kubelet_pod`) is collected by default and needs no switch. Set this through a values file (see the `extraEnvs` note below); do not use `--set extraEnvs[N]`.
- **`extraEnvs` replaces the entire list, and the chart's default `extraEnvs` carries critical entries.** The chart's default `extraEnvs` contains three entries: `ENV_NAMESPACE`, `ENV_INPUT_CONTAINER_GCP_CLOUD_API_ENABLED=true`, and `ENV_INPUT_CONTAINER_ENABLE_K8S_NODE_LOCAL=false`. Using `--set extraEnvs[N]` overwrites these defaults by index. For example, overwriting `ENV_NAMESPACE` makes the election namespace fall back to `default`; overwriting Cloud API or NodeLocal breaks Cloud API collection or Autopilot compatibility. Set any custom `extraEnvs` through a complete values file that includes all three defaults, followed by your own entries:

    ```yaml
    extraEnvs:
      - name: ENV_NAMESPACE
        value: "<cluster name or custom election namespace>"
      - name: ENV_INPUT_CONTAINER_GCP_CLOUD_API_ENABLED
        value: "true"
      - name: ENV_INPUT_CONTAINER_ENABLE_K8S_NODE_LOCAL
        value: "false"
      # Custom entries to add as needed, e.g., enable Pod metrics:
      - name: ENV_INPUT_CONTAINER_ENABLE_POD_METRIC
        value: "true"
    ```

    Apply with `helm upgrade "$RELEASE_NAME" datakit-gke/datakit-gke-autopilot -n "$NAMESPACE" --reuse-values -f <values file>`. `--reuse-values` keeps scalar values such as `dataway_url`, while the `extraEnvs` list is replaced entirely by the file.
- **Election namespace and cluster identifier (required when multiple clusters share one workspace).** `ENV_NAMESPACE` (the election namespace, which the chart defaults to `datakit`) determines the election group. When several clusters or deployments share one workspace, give each a distinct value to isolate elections; set it through the `extraEnvs` above. `cluster_name_k8s` is a native scalar key — set it with `--set datakit.cluster_name_k8s=<cluster name>` (not in `extraEnvs`). It adds a `cluster_name_k8s` tag to the data so you can tell which cluster it came from. Set both to the cluster name. To confirm: `datakit monitor` shows `Elected <namespace>::success` with the namespace you set.
- **Default resources:** CPU and memory requests are 500m and 500Mi.
- **host tag behavior.** The single leader collects the whole cluster, and the host tag is derived from each container's GKE node name in the Pod information. This mode does not support renaming the host tag via `ENV_K8S_CLUSTER_NODE_NAME`. To distinguish clusters, use `cluster_name_k8s`, `gcp_project_id`, `gcp_location`, or a custom global tag.
- **Cross-project / metadata override.** The project ID, cluster name, and location are auto-discovered from the GKE metadata server. For cross-project collection, or when discovery does not match, override them with `ENV_INPUT_CONTAINER_GCP_PROJECT_ID`, `ENV_INPUT_CONTAINER_GCP_CLUSTER_NAME`, and `ENV_INPUT_CONTAINER_GCP_CLUSTER_LOCATION`.
- **Run as non-root (optional).** DataKit runs as root by default. To run as non-root, add `--set gkeAutopilot.runAsNonRoot=true` at install (UID/GID 10001, fsGroup 10001). If you mount extra directories such as conf.d, data, or pipeline, make sure they are writable by UID/GID 10001.

## 8. Enabling Push-Based Inputs (DDTrace / OpenTelemetry)

The collection described above is Cloud API pull-based: DataKit pulls data from GCP. DDTrace and OpenTelemetry are push-based inputs instead: DataKit opens a port, and applications push trace data to it. This does not depend on host access or the Cloud API, and works normally on Autopilot.

By default, the Autopilot chart enables only `dk` and `container`, with no push-based input. However, the chart already ships a Service named `datakit-service` that exposes `9529` (HTTP), `8125` (StatsD), `4317` (OTLP gRPC), and `9533` (logfwd), so you do not need to create a Service to receive data. Enabling DDTrace/OpenTelemetry on the Autopilot single-replica Deployment therefore takes three steps: enable the inputs, confirm the Service, and configure the application's reporting address.

### Step 1: Enable the inputs

Add the inputs to `datakit.default_enabled_inputs`. The chart already sets DataKit's HTTP listener to `0.0.0.0:9529` (reachable within the cluster), so do not set `ENV_HTTP_LISTEN` again — a duplicate makes the upgrade fail with `duplicate entries for key [name="ENV_HTTP_LISTEN"]`. There are two scenarios, by deployment stage.

**Scenario A: at fresh install (configure during `helm install`)**

```bash
helm install "$RELEASE_NAME" datakit-gke/datakit-gke-autopilot \
  --namespace "$NAMESPACE" --create-namespace \
  --set datakit.dataway_url="$DATAWAY_URL" \
  --set serviceAccountAnnotations."iam\.gke\.io/gcp-service-account"="$GSA_EMAIL" \
  --set datakit.default_enabled_inputs="dk,container,ddtrace,opentelemetry"
```

**Scenario B: updating an existing DataKit (`helm upgrade`)**

```bash
helm upgrade "$RELEASE_NAME" datakit-gke/datakit-gke-autopilot -n "$NAMESPACE" --reuse-values \
  --set datakit.default_enabled_inputs="dk,container,ddtrace,opentelemetry"

# Apply the change
kubectl rollout restart deploy/"$KSA_NAME" -n "$NAMESPACE"
```

> **Verify:** run `kubectl exec -it -n "$NAMESPACE" deploy/"$KSA_NAME" -- datakit monitor`. The Enabled Inputs panel should list `ddtrace` and `opentelemetry`. In Basic Info, `From http://0.0.0.0:9529/metrics` confirms the listener is on `0.0.0.0`.
> **OTLP gRPC (optional):** gRPC is not needed for HTTP reporting. If you need OTLP gRPC (4317), inject `ENV_INPUT_OTEL_GRPC` (value `{"addr":"0.0.0.0:4317","trace_enable":true,"metric_enable":true}`) through `extraEnvs`. Manage it with a values file to avoid `--set extraEnvs[N]` index collisions with existing entries such as `ENV_INPUT_CONTAINER_ENABLE_POD_METRIC`.

### Step 2: Confirm the receiving Service (shipped by the chart)

The `datakit-gke-autopilot` chart creates the Service `datakit-service` automatically at install time, exposing all receiving ports. You do not need to create one. Confirm it:

```bash
kubectl get svc -n "$NAMESPACE"
# Expect datakit-service, with PORT(S) including 9529/TCP, 8125/UDP, 4317/TCP, 9533/TCP
```

The in-cluster reporting address is `datakit-service.<NAMESPACE>.svc.cluster.local`, with these ports:

- `9529`: DDTrace, OTLP-HTTP, and other HTTP inputs
- `4317`: OTLP gRPC (also set DataKit's OTLP gRPC listener to `0.0.0.0` — see the OTLP gRPC option in Step 1 of this chapter)
- `8125`: StatsD; `9533`: logfwd

> If `kubectl get svc` does not show `datakit-service` (some older chart versions may differ), create a ClusterIP Service pointing to the Deployment manually: `kubectl expose deployment "$KSA_NAME" -n "$NAMESPACE" --name datakit-service --port 9529 --target-port 9529 --type ClusterIP`.

### Step 3: Configure the application's reporting address (host_url)

Unlike DaemonSet mode, an Autopilot cluster has a single Deployment. Applications must therefore report through the Service's in-cluster DNS name rather than a node IP: `datakit-service.<namespace>.svc.cluster.local`.

| Reporting method | DaemonSet mode | Autopilot (single-Deployment) mode |
|---|---|---|
| DDTrace | `DD_AGENT_HOST=$(HOST_IP)`, `DD_TRACE_AGENT_PORT=9529` | `DD_AGENT_HOST=datakit-service.datakit.svc.cluster.local`, `DD_TRACE_AGENT_PORT=9529` |
| OTLP / HTTP | `http://$(HOST_IP):9529/otel/v1/traces` | `http://datakit-service.datakit.svc.cluster.local:9529/otel/v1/traces` |
| OTLP / gRPC | `http://$(HOST_IP):4317` | `http://datakit-service.datakit.svc.cluster.local:4317` |

**Java Agent examples:**

DDTrace Java Agent:

```bash
DD_AGENT_HOST=datakit-service.datakit.svc.cluster.local
DD_TRACE_AGENT_PORT=9529
DD_SERVICE=<your-service>   DD_ENV=<env>   DD_VERSION=<ver>
# Start: java -javaagent:/path/dd-java-agent.jar -jar app.jar
```

OpenTelemetry Java Agent (OTLP-HTTP uses port 9529 at `/otel/v1/traces`):

```bash
OTEL_SERVICE_NAME=<your-service>
OTEL_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://datakit-service.datakit.svc.cluster.local:9529/otel/v1/traces
# Start: java -javaagent:/path/opentelemetry-javaagent.jar -jar app.jar
```

### Step 4: Verify APM reporting

1. **Application side:** confirm the application is generating requests or calls (for example, request-handling entries in its logs).
2. **DataKit side:** run `kubectl exec -it -n "$NAMESPACE" deploy/"$KSA_NAME" -- datakit monitor`. In the Inputs Info panel, the `Feeds` count for `ddtrace` and `opentelemetry` should increase as requests arrive.
3. **Workspace:** go to APM → Traces and filter by `service` (the `DD_SERVICE` / `OTEL_SERVICE_NAME` you set). You should see the corresponding spans, with the resource set to the called endpoint and status `ok`. The data has a delay of a few minutes.

### Port and Path Reference

| Port | Protocol | Purpose | Notes |
|---|---|---|---|
| 9529 | HTTP | DDTrace (`/v0.3|v0.4|v0.5/traces`), OTLP-HTTP (`/otel/v1/traces|metrics|logs`), and other HTTP inputs | The chart already listens on `0.0.0.0:9529`. Do not set `ENV_HTTP_LISTEN` manually — a duplicate causes a `duplicate` error. |
| 4317 | gRPC | OpenTelemetry OTLP gRPC (optional) | The chart Service exposes 4317, but DataKit's OTLP gRPC listener defaults to `127.0.0.1:4317`. Change it to `0.0.0.0:4317` to take effect. |

> OTLP over HTTP reuses port 9529 at `/otel/v1/*`. It does not use the standard separate port 4318.

## Appendix 1: Troubleshooting (FAQ)

| Symptom | What to check |
|---|---|
| Pod rejected by Autopilot | Check whether hostPath, privileged containers, or hostNetwork/hostPID/hostIPC were enabled by mistake (Autopilot blocks these). The dedicated chart normally does not trigger this. |
| Pod is Running but reports no data | Check the GSA permissions and the Workload Identity binding (Step 4). Confirm the GSA in the annotation matches the K8s SA in the binding (default `datakit/datakit`). |
| Metrics but no logs (or vice versa) | Check that the GSA has both `roles/monitoring.viewer` and `roles/logging.viewer`, and that both APIs are enabled. |
| Duplicate data | Check whether there are multiple replicas with election disabled, and confirm all replicas are in the same namespace. |
| Data delay or occasional duplicate logs | Expected behavior: Cloud Monitoring has a delay of several minutes; logs are delivered at-least-once and deduplicated by `timestamp + insertId`. |
| Write failures in non-root mode | Check that any extra mounted directories are writable by UID/GID 10001. |
| K8s objects/resources missing after deployment (e.g., Pod or Node objects) | Expected latency: K8s objects are collected on a per-minute cycle, plus platform view refresh delay; allow a few minutes after deployment. Run `datakit dql` → `show_object_class()` inside the DataKit Pod to confirm they are reported (for example, `kubelet_pod`, `kubernetes_nodes`) before concluding they are not collected. |
| Pod CPU/memory metrics missing (`kube_pod`) | Pod-level metrics are off by default. Set `ENV_INPUT_CONTAINER_ENABLE_POD_METRIC=true` and restart (see "Key Configuration" → Pod-level metrics). The Pod object `kubelet_pod` and the Pod metric set `kube_pod` are different things. |
| helm/kubectl reports `release name is invalid` or an empty resource name | Usually the `export` variables were lost after a terminal session timed out or was reopened. Re-run the `export` block in Section 3 (Shell Variables) — you can `echo "$RELEASE_NAME $NAMESPACE"` to confirm they are non-empty — and retry. |
| `helm upgrade` reports `"<name>" has no deployed releases` | `RELEASE_NAME` does not match the installed release name (which may differ from the Deployment name `datakit`). Run `helm list -A` to find the actual NAME and NAMESPACE, then correct the variables. |
| `helm upgrade` reports `duplicate entries for key [name="ENV_HTTP_LISTEN"]` | The chart already sets `ENV_HTTP_LISTEN=0.0.0.0:9529` (native key `datakit.http_listen`). Do not inject it again through `extraEnvs`; remove `ENV_HTTP_LISTEN` from your values or `--set`. |
| Election namespace becomes `default`, or some collection stops, after an upgrade | Usually `--set extraEnvs[N]` overwrote a critical entry in the chart's default `extraEnvs` (`ENV_NAMESPACE`, `GCP_CLOUD_API_ENABLED`, or `ENABLE_K8S_NODE_LOCAL`). Re-list `extraEnvs` in a complete values file that includes all three plus your custom entries (see "Key Configuration" → `extraEnvs`). |

## Appendix 2: Upgrading from an Older Chart

The chart previously published on the `helm-gke-autopilot` branch created a **DaemonSet** and a ServiceAccount named `my-datakit-datakit-gke-autopilot`. The current chart creates a **Deployment** and a ServiceAccount named `datakit`. Before upgrading:

1. Back up the current configuration: `helm get values "$RELEASE_NAME" -n "$NAMESPACE" > values-current.yaml`.
2. Change the Workload Identity binding to the new `$NAMESPACE/$KSA_NAME`.
3. Make sure the target namespace has no leftover `datakit` resources with the same name, to avoid conflicts.

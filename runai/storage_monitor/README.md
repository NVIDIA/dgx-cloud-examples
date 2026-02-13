<!--
SPDX-FileCopyrightText: Copyright (c) 2024-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
SPDX-License-Identifier: Apache-2.0

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

# Run.ai Storage Monitor

![Version](https://img.shields.io/badge/version-1.0.1-blue) ![Python](https://img.shields.io/badge/python-3.8%2B-green) ![License](https://img.shields.io/badge/license-Apache%202.0-orange)

Kubernetes storage visibility tool for Run.ai environments -- web GUI for identifying unused PVCs, tracking storage quotas, and getting cleanup recommendations.

## Quick Start

```bash
# Authenticate and get credentials
runai login
runai kubeconfig set

# Install and launch
pip install -e .
runai-storage-server
# Open http://127.0.0.1:8081
```

To use a custom kubeconfig: `export KUBECONFIG=/path/to/config`

## Installation

**Prerequisites:** Python 3.8+, [Run.ai CLI](https://docs.nvidia.com/dgx-cloud/run-ai/latest/advanced.html#downloading-the-nvidia-run-ai-cli), kubectl, kubeconfig with read-only K8s access.

```bash
git clone <repository-url>
cd runai_storage_monitor
pip install -e .
```

Verify: `runai-storage-monitor --version`

## Persistent Deployments (ServiceAccount)

For long-running deployments, use a Kubernetes ServiceAccount instead of OIDC user tokens that expire every 24 hours.

### Step 1: Create ServiceAccount and RBAC

Save as `storage-monitor-rbac.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: storage-monitor
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: storage-monitor-reader
rules:
  - apiGroups: [""]
    resources: ["namespaces", "pods", "persistentvolumeclaims", "resourcequotas"]
    verbs: ["list", "get"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["list", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: storage-monitor-reader-binding
subjects:
  - kind: ServiceAccount
    name: storage-monitor
    namespace: default
roleRef:
  kind: ClusterRole
  name: storage-monitor-reader
  apiGroup: rbac.authorization.k8s.io
```

```bash
kubectl apply -f storage-monitor-rbac.yaml
```

### Step 2: Deploy as a Kubernetes Pod (Recommended)

Deploy as a Pod and Kubernetes handles token rotation automatically -- no static tokens or manual refresh.

```bash
# Build image
cd runai/storage_monitor
docker build -t storage-monitor:1.0.1 .

# Deploy (push image to your registry first)
kubectl apply -f deploy/deployment.yaml
kubectl apply -f deploy/service.yaml

# Access dashboard
kubectl port-forward svc/storage-monitor 8081:8081
# Open http://localhost:8081
```

### Alternative: External Kubeconfig (with Token)

Run outside the cluster using a ServiceAccount token in a kubeconfig.

> **Token duration cap:** Managed platforms (including DGX Cloud) may configure `--service-account-max-token-expiration` on the API server, which silently caps `kubectl create token --duration`. If your token expires in 24 hours despite requesting longer, use the **Pod deployment** above or a **Secret-based token** below.

```bash
# Create token (actual duration may be capped by API server)
kubectl create token storage-monitor -n default --duration=8760h > /tmp/sa-token

# Build kubeconfig
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

cat > ~/.kube/storage-monitor-config <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      server: ${CLUSTER_SERVER}
      certificate-authority-data: ${CLUSTER_CA}
contexts:
  - name: storage-monitor
    context:
      cluster: ${CLUSTER_NAME}
      user: storage-monitor
current-context: storage-monitor
users:
  - name: storage-monitor
    user:
      token: $(cat /tmp/sa-token)
EOF

rm /tmp/sa-token
```

```bash
export KUBECONFIG=~/.kube/storage-monitor-config
runai-storage-server
```

### Alternative: Secret-Based Token (Bypasses Duration Cap)

If the API server caps `kubectl create token` duration and you can't deploy as a Pod, create a Secret-based token. This uses the token controller (not the TokenRequest API) and is not subject to `--service-account-max-token-expiration`.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: storage-monitor-token
  namespace: default
  annotations:
    kubernetes.io/service-account.name: storage-monitor
type: kubernetes.io/service-account-token
```

```bash
kubectl apply -f storage-monitor-secret.yaml

# Extract token
TOKEN=$(kubectl get secret storage-monitor-token -n default -o jsonpath='{.data.token}' | base64 -d)
```

Use this token in the kubeconfig `users[].user.token` field instead of one from `kubectl create token`.

## Troubleshooting

- **Token expires in 24hr despite `--duration=8760h`:** Platform-level `--service-account-max-token-expiration` cap. Use Pod deployment or Secret-based token (see above).
- **401 Unauthorized after running for a while:** OIDC token expired. Run `runai login` then `runai kubeconfig set`, or switch to ServiceAccount auth.
- **No namespaces found:** Verify Run.ai namespaces exist (`kubectl get ns | grep runai`) and credentials are current (`runai kubeconfig set`).
- **Check permissions:** `runai-storage-monitor check-permissions` shows what the current credentials can access.

## CLI

```bash
runai-storage-monitor --help
runai-storage-monitor list-namespaces
runai-storage-monitor analyze <namespace>
runai-storage-monitor unused <namespace>
```

## Support

Community example tool. File issues at [dgx-cloud-examples](https://github.com/NVIDIA/dgx-cloud-examples/issues).

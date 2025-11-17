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

Kubernetes storage visibility tool for Run.ai environments - web GUI for identifying unused PVCs, tracking storage usage, and getting actionable cleanup recommendations.

A community example tool for DGX Cloud Run.ai deployments.

## Quick Start

```bash
# 1. Authenticate to Run.ai (first time or when token expires)
runai login

# 2. Update kubectl credentials
runai kubeconfig set

# 3. Install tool
pip install -e .

# 4. Launch GUI
runai-storage-server

# 5. Open browser
http://127.0.0.1:8081
```

## Features

- **Web GUI** for storage visibility across Run.ai namespaces
- List all Run.ai namespaces
- Analyze PVC usage and status
- Identify unused PVCs for cleanup
- Track storage quotas and limits
- Real-time WebSocket updates
- Export analysis to JSON/CSV
- Permission validation

## Installation

### Prerequisites

- Python 3.8+
- **Run.ai CLI** installed ([Download from Run.ai UI](https://docs.nvidia.com/dgx-cloud/run-ai/latest/advanced.html#downloading-the-nvidia-run-ai-cli))
- **kubectl** installed
- **Kubeconfig file** from your cluster administrator
- Read-only K8s permissions (list namespaces, PVCs, pods)

**First-Time Setup:**
1. Place kubeconfig in `~/.kube/config` (or set `KUBECONFIG` environment variable)
2. `runai login` - Opens browser for SSO authentication
3. `runai kubeconfig set` - Retrieves OIDC token for kubeconfig
4. `kubectl get nodes` - Verify cluster access works

See full setup guide: [DGX Cloud CLI/API Setup](https://docs.nvidia.com/dgx-cloud/run-ai/latest/advanced.html#setting-up-your-kubernetes-configuration-file)

### Install

```bash
git clone <repository-url>
cd runai_storage_monitor
pip install -e .
```

### Verify Installation

```bash
runai-storage-monitor --version
# Should output: runai-storage-monitor, version 1.0.0
```

### Launch GUI

```bash
runai-storage-server
```

Opens at `http://127.0.0.1:8081`

## Configuration

### Custom Kubeconfig

```bash
runai-storage-server
# Uses default ~/.kube/config
```

For custom kubeconfig path, set `KUBECONFIG` environment variable:
```bash
export KUBECONFIG=/path/to/config
runai-storage-server
```

### Kubernetes Context

```bash
kubectl config use-context <your-context>
runai-storage-server
```

## Troubleshooting

### Authentication Issues
- **Token expired:** Run `runai login` then `runai kubeconfig set`
- **Not authenticated:** Ensure you've completed `runai login` successfully
- **Wrong cluster context:** Verify with `kubectl config current-context`

### "No namespaces found"
- Check kubeconfig: `kubectl config current-context`
- Verify Run.ai installation: `kubectl get namespaces | grep runai`
- Refresh credentials: `runai kubeconfig set`

### "Unable to connect to the server"
- Ensure kubeconfig is valid: `kubectl cluster-info`
- Check permissions: `runai-storage-monitor check-permissions`
- Verify authentication: `runai whoami`

### "WebSocket connection failed"
- Use HTTP polling as fallback
- Check firewall/proxy settings

## CLI Usage

For advanced CLI usage and automation:

```bash
runai-storage-monitor --help

# Common commands:
runai-storage-monitor list-namespaces
runai-storage-monitor analyze <namespace>
runai-storage-monitor unused <namespace>
```

## Support

This is a community example tool. For issues or questions, please file an issue in the [dgx-cloud-examples repository](https://github.com/NVIDIA/dgx-cloud-examples/issues).

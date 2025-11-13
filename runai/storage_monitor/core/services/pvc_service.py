# SPDX-FileCopyrightText: Copyright (c) 2024-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""PVC operations service using K8s API."""

from typing import List, Dict
from datetime import datetime, timezone
from ..clients.k8s_client import K8sClient
from ..models.storage_models import PVC, Pod, PVCWithPods


class PVCService:
    """Service for PVC-related operations."""
    
    def __init__(self, k8s_client: K8sClient):
        """Initialize PVC service.
        
        Args:
            k8s_client: Kubernetes API client
        """
        self.k8s = k8s_client
    
    def list_pvcs(self, namespace: str) -> List[PVC]:
        """Get all PVCs in a namespace.
        
        Args:
            namespace: Kubernetes namespace
            
        Returns:
            List of PVC models
        """
        pvc_dicts = self.k8s.list_pvcs(namespace)
        
        pvcs = []
        for pvc_dict in pvc_dicts:
            # Calculate age
            age_days = None
            if pvc_dict.get("creation_timestamp"):
                created = pvc_dict["creation_timestamp"]
                if created.tzinfo is None:
                    created = created.replace(tzinfo=timezone.utc)
                age_days = (datetime.now(timezone.utc) - created).days
            
            pvcs.append(PVC(
                name=pvc_dict["name"],
                namespace=pvc_dict["namespace"],
                status=pvc_dict["status"],
                capacity=pvc_dict["capacity"] or "Unknown",
                storage_class=pvc_dict["storage_class"],
                access_modes=pvc_dict["access_modes"],
                volume_name=pvc_dict["volume_name"],
                creation_timestamp=pvc_dict["creation_timestamp"],
                age_days=age_days,
                labels=pvc_dict["labels"],
                annotations=pvc_dict["annotations"]
            ))
        
        return pvcs
    
    def get_pvc_pods(self, namespace: str, pvc_name: str) -> List[Pod]:
        """Find all pods using a specific PVC.
        
        Args:
            namespace: Kubernetes namespace
            pvc_name: PVC name to search for
            
        Returns:
            List of pods using the PVC
        """
        pod_dicts = self.k8s.list_pods(namespace)
        
        using_pods = []
        for pod_dict in pod_dicts:
            if pvc_name in pod_dict.get("pvc_claims", []):
                using_pods.append(Pod(
                    name=pod_dict["name"],
                    namespace=pod_dict["namespace"],
                    status=pod_dict["status"],
                    node_name=pod_dict["node_name"],
                    pvc_claims=pod_dict["pvc_claims"],
                    creation_timestamp=pod_dict["creation_timestamp"],
                    labels=pod_dict["labels"]
                ))
        
        return using_pods
    
    def get_pvcs_with_pods(self, namespace: str) -> List[PVCWithPods]:
        """Get all PVCs enriched with pod usage information.
        
        Args:
            namespace: Kubernetes namespace
            
        Returns:
            List of PVCs with their associated pods
        """
        pvcs = self.list_pvcs(namespace)
        pod_dicts = self.k8s.list_pods(namespace)
        
        # Build PVC -> Pods mapping
        pvc_to_pods: Dict[str, List[Pod]] = {}
        for pod_dict in pod_dicts:
            for pvc_name in pod_dict.get("pvc_claims", []):
                if pvc_name not in pvc_to_pods:
                    pvc_to_pods[pvc_name] = []
                
                pvc_to_pods[pvc_name].append(Pod(
                    name=pod_dict["name"],
                    namespace=pod_dict["namespace"],
                    status=pod_dict["status"],
                    node_name=pod_dict["node_name"],
                    pvc_claims=pod_dict["pvc_claims"],
                    creation_timestamp=pod_dict["creation_timestamp"],
                    labels=pod_dict["labels"]
                ))
        
        # Create PVCWithPods objects
        result = []
        for pvc in pvcs:
            pods = pvc_to_pods.get(pvc.name, [])
            result.append(PVCWithPods(
                pvc=pvc,
                pods=pods,
                is_unused=(len(pods) == 0)
            ))
        
        return result
    
    def parse_capacity_to_gi(self, capacity: str) -> float:
        """Parse capacity string to GiB float.
        
        Args:
            capacity: Capacity string like "100Gi", "1Ti", "500Mi"
            
        Returns:
            Capacity in GiB as float
        """
        if not capacity or capacity == "Unknown":
            return 0.0
        
        capacity = capacity.strip()
        
        if capacity.endswith("Ti"):
            return float(capacity[:-2]) * 1024
        elif capacity.endswith("Gi"):
            return float(capacity[:-2])
        elif capacity.endswith("Mi"):
            return float(capacity[:-2]) / 1024
        elif capacity.endswith("Ki"):
            return float(capacity[:-2]) / (1024 * 1024)
        else:
            # Assume bytes
            return float(capacity) / (1024 ** 3)


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

"""Storage analyzer - orchestrates analysis across services."""

from datetime import datetime
from typing import List
from ..services.pvc_service import PVCService
from ..services.namespace_service import NamespaceService
from ..services.quota_service import QuotaService
from ..clients.k8s_client import K8sClient
from ..models.storage_models import (
    StorageAnalysis,
    StorageSummary,
    StorageClass,
    Recommendation
)
from .recommendations import RecommendationEngine


class StorageAnalyzer:
    """High-level storage analyzer orchestrating all services."""
    
    def __init__(
        self,
        pvc_service: PVCService,
        namespace_service: NamespaceService,
        quota_service: QuotaService
    ):
        """Initialize storage analyzer.
        
        Args:
            pvc_service: PVC operations service
            namespace_service: Namespace operations service
            quota_service: Quota operations service
        """
        self.pvc_service = pvc_service
        self.namespace_service = namespace_service
        self.quota_service = quota_service
        self.recommendation_engine = RecommendationEngine(
            capacity_parser=self.pvc_service.parse_capacity_to_gi
        )
    
    @classmethod
    def from_k8s_client(cls, k8s_client: K8sClient) -> "StorageAnalyzer":
        """Create analyzer from K8s client (convenience factory).
        
        Args:
            k8s_client: Kubernetes API client
            
        Returns:
            Configured StorageAnalyzer instance
        """
        pvc_service = PVCService(k8s_client)
        namespace_service = NamespaceService(k8s_client)
        quota_service = QuotaService(k8s_client)
        
        return cls(
            pvc_service=pvc_service,
            namespace_service=namespace_service,
            quota_service=quota_service
        )
    
    def analyze_namespace(self, namespace: str) -> StorageAnalysis:
        """Perform complete storage analysis for a namespace.
        
        Args:
            namespace: Kubernetes namespace to analyze
            
        Returns:
            Complete storage analysis with recommendations
        """
        # Get PVCs with pod information
        pvcs_with_pods = self.pvc_service.get_pvcs_with_pods(namespace)
        
        # Get quota information
        quota = self.quota_service.get_storage_quota(namespace)
        
        # Calculate summary statistics
        summary = self._calculate_summary(namespace, pvcs_with_pods, quota)
        
        # Get storage classes
        storage_classes = self._get_storage_classes()
        
        # Generate recommendations
        recommendations = self.recommendation_engine.generate_recommendations(
            pvcs_with_pods, summary, quota
        )
        
        return StorageAnalysis(
            namespace=namespace,
            timestamp=datetime.now(),
            summary=summary,
            pvcs=pvcs_with_pods,
            storage_classes=storage_classes,
            recommendations=recommendations
        )
    
    def _calculate_summary(self, namespace: str, pvcs_with_pods, quota) -> StorageSummary:
        """Calculate storage summary statistics.
        
        Args:
            namespace: Kubernetes namespace
            pvcs_with_pods: List of PVCs with pod information
            quota: Resource quota (if exists)
            
        Returns:
            Storage summary
        """
        total_pvcs = len(pvcs_with_pods)
        bound_pvcs = sum(1 for pvc_wp in pvcs_with_pods if pvc_wp.pvc.status == "Bound")
        pending_pvcs = sum(1 for pvc_wp in pvcs_with_pods if pvc_wp.pvc.status == "Pending")
        unused_pvcs = sum(1 for pvc_wp in pvcs_with_pods if pvc_wp.is_unused)
        
        # Calculate total capacity
        total_capacity_gi = 0.0
        unused_capacity_gi = 0.0
        storage_class_counts = {}
        
        for pvc_wp in pvcs_with_pods:
            capacity_gi = self.pvc_service.parse_capacity_to_gi(pvc_wp.pvc.capacity)
            total_capacity_gi += capacity_gi
            
            if pvc_wp.is_unused:
                unused_capacity_gi += capacity_gi
            
            # Count by storage class
            sc = pvc_wp.pvc.storage_class or "default"
            storage_class_counts[sc] = storage_class_counts.get(sc, 0) + 1
        
        return StorageSummary(
            namespace=namespace,
            total_pvcs=total_pvcs,
            bound_pvcs=bound_pvcs,
            pending_pvcs=pending_pvcs,
            unused_pvcs=unused_pvcs,
            total_capacity_gi=total_capacity_gi,
            unused_capacity_gi=unused_capacity_gi,
            storage_classes=storage_class_counts,
            has_quota=(quota is not None),
            quota=quota
        )
    
    def _get_storage_classes(self) -> List[StorageClass]:
        """Get all storage classes in the cluster.
        
        Returns:
            List of storage classes
        """
        # This requires access to the K8s client through one of the services
        # For now, return empty list - can be enriched later
        try:
            sc_dicts = self.pvc_service.k8s.list_storage_classes()
            return [
                StorageClass(
                    name=sc["name"],
                    provisioner=sc["provisioner"],
                    reclaim_policy=sc.get("reclaim_policy"),
                    volume_binding_mode=sc.get("volume_binding_mode"),
                    allow_volume_expansion=sc.get("allow_volume_expansion", False),
                    parameters=sc.get("parameters", {})
                )
                for sc in sc_dicts
            ]
        except Exception:
            return []
    
    def list_runai_namespaces(self) -> List[str]:
        """List Run.ai namespaces (convenience method).
        
        Returns:
            List of Run.ai namespace names
        """
        return self.namespace_service.list_runai_namespaces()
    
    def get_unused_pvcs(self, namespace: str) -> List:
        """Get list of unused PVCs (convenience method).
        
        Args:
            namespace: Kubernetes namespace
            
        Returns:
            List of unused PVCs with pods
        """
        pvcs_with_pods = self.pvc_service.get_pvcs_with_pods(namespace)
        return [pvc_wp for pvc_wp in pvcs_with_pods if pvc_wp.is_unused]


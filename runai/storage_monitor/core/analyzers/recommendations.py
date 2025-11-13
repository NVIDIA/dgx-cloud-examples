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

"""Recommendation engine for storage optimization."""

from typing import Callable, List, Optional
from ..models.storage_models import PVCWithPods, ResourceQuota, Recommendation, StorageSummary


class RecommendationEngine:
    """Generate storage optimization recommendations."""
    
    def __init__(self, capacity_parser: Optional[Callable[[str], float]] = None):
        """Create engine with optional capacity parser.
        
        Args:
            capacity_parser: Callable that converts capacity strings to GiB.
        """
        self.capacity_parser = capacity_parser
    
    def _parse_capacity(self, capacity: Optional[str]) -> Optional[float]:
        """Safely parse capacity string to GiB using configured parser."""
        if not self.capacity_parser or not capacity:
            return None
        try:
            value = self.capacity_parser(capacity)
            # Ensure numeric and non-negative
            if value is not None and value >= 0:
                return float(value)
            return None
        except Exception:
            return None
    
    def generate_recommendations(
        self,
        pvcs_with_pods: List[PVCWithPods],
        summary: StorageSummary,
        quota: ResourceQuota = None
    ) -> List[Recommendation]:
        """Generate recommendations based on storage analysis.
        
        Args:
            pvcs_with_pods: List of PVCs with pod information
            summary: Storage summary statistics
            quota: Resource quota (if exists)
            
        Returns:
            List of recommendations
        """
        recommendations = []
        
        # Check for unused PVCs
        unused_pvcs = [pvc_wp for pvc_wp in pvcs_with_pods if pvc_wp.is_unused]
        if unused_pvcs:
            for pvc_wp in unused_pvcs:
                capacity_gi = self._parse_capacity(pvc_wp.pvc.capacity)
                recommendations.append(Recommendation(
                    type="unused_pvc",
                    severity="warning",
                    title=f"{pvc_wp.pvc.name}",
                    description=f"({pvc_wp.pvc.capacity}) not mounted to any pods. Consider cleanup to reclaim storage.",
                    pvc_name=pvc_wp.pvc.name,
                    capacity=pvc_wp.pvc.capacity,
                    capacity_gi=capacity_gi,
                    age_days=pvc_wp.pvc.age_days,
                    actionable=True
                ))
            
            # Summary recommendation for unused storage
            if summary.unused_capacity_gi > 0:
                recommendations.append(Recommendation(
                    type="unused_storage_summary",
                    severity="info",
                    title=f"{summary.unused_capacity_gi:.2f}Gi Available for Reclamation",
                    description=f"{len(unused_pvcs)} PVCs not in use. Consider cleanup to save costs and free quota.",
                    capacity=f"{summary.unused_capacity_gi:.2f}Gi",
                    capacity_gi=summary.unused_capacity_gi,
                    actionable=True
                ))
        
        # Check for pending PVCs
        if summary.pending_pvcs > 0:
            recommendations.append(Recommendation(
                type="pending_pvc",
                severity="error",
                title=f"{summary.pending_pvcs} PVCs Waiting for Provisioning",
                description=f"Volumes are not being created. This may indicate storage class issues, quota exhaustion, or insufficient cluster capacity.",
                actionable=True
            ))
        
        # Check for old unused PVCs (potential orphaned resources)
        old_unused = [
            pvc_wp for pvc_wp in unused_pvcs
            if pvc_wp.pvc.age_days and pvc_wp.pvc.age_days > 30
        ]
        if old_unused:
            recommendations.append(Recommendation(
                type="old_unused_pvc",
                severity="warning",
                title=f"{len(old_unused)} Orphaned Resources Detected",
                description=f"Unused for over 30 days. Likely safe to delete.",
                actionable=True
            ))
        
        return recommendations


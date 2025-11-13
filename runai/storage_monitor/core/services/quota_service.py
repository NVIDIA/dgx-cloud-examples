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

"""Resource quota operations service."""

from typing import Optional
from ..clients.k8s_client import K8sClient
from ..models.storage_models import ResourceQuota


class QuotaService:
    """Service for resource quota operations."""
    
    def __init__(self, k8s_client: K8sClient):
        """Initialize quota service.
        
        Args:
            k8s_client: Kubernetes API client
        """
        self.k8s = k8s_client
    
    def get_storage_quota(self, namespace: str) -> Optional[ResourceQuota]:
        """Get storage-related resource quotas for a namespace.
        
        Args:
            namespace: Kubernetes namespace
            
        Returns:
            ResourceQuota if quotas exist, None otherwise
        """
        quota_dicts = self.k8s.list_resource_quotas(namespace)
        
        if not quota_dicts:
            return None
        
        # Aggregate all quotas (there may be multiple)
        combined_hard = {}
        combined_used = {}
        
        for quota_dict in quota_dicts:
            combined_hard.update(quota_dict.get("hard_limits", {}))
            combined_used.update(quota_dict.get("used", {}))
        
        # Check for storage-related quotas
        has_storage_quota = any(
            key in combined_hard
            for key in ["requests.storage", "persistentvolumeclaims"]
        )
        
        if not has_storage_quota and not quota_dicts:
            return None
        
        # Use first quota name if multiple
        quota_name = quota_dicts[0]["name"] if quota_dicts else "combined"
        
        return ResourceQuota(
            name=quota_name,
            namespace=namespace,
            hard_limits=combined_hard,
            used=combined_used,
            has_storage_quota=has_storage_quota,
            storage_limit=combined_hard.get("requests.storage"),
            storage_used=combined_used.get("requests.storage"),
            pvc_count_limit=self._parse_int(combined_hard.get("persistentvolumeclaims")),
            pvc_count_used=self._parse_int(combined_used.get("persistentvolumeclaims"))
        )
    
    def _parse_int(self, value: any) -> Optional[int]:
        """Parse integer from string or int value.
        
        Args:
            value: Value to parse
            
        Returns:
            Integer value or None if cannot parse
        """
        if value is None:
            return None
        
        try:
            return int(value)
        except (ValueError, TypeError):
            return None


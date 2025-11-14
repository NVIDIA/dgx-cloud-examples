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

"""Data models for Kubernetes storage resources."""

from datetime import datetime
from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field


class PVC(BaseModel):
    """Persistent Volume Claim model."""
    
    name: str
    namespace: str
    status: str  # Bound, Pending, Released
    capacity: str  # e.g., "100Gi"
    storage_class: Optional[str] = None
    access_modes: List[str] = Field(default_factory=list)
    volume_name: Optional[str] = None
    creation_timestamp: Optional[datetime] = None
    age_days: Optional[int] = None
    labels: Dict[str, str] = Field(default_factory=dict)
    annotations: Dict[str, str] = Field(default_factory=dict)
    
    class Config:
        json_encoders = {
            datetime: lambda v: v.isoformat() if v else None
        }


class Pod(BaseModel):
    """Pod model with PVC usage information."""
    
    name: str
    namespace: str
    status: str  # Running, Pending, Failed, etc.
    node_name: Optional[str] = None
    pvc_claims: List[str] = Field(default_factory=list)
    creation_timestamp: Optional[datetime] = None
    labels: Dict[str, str] = Field(default_factory=dict)
    
    class Config:
        json_encoders = {
            datetime: lambda v: v.isoformat() if v else None
        }


class PVCWithPods(BaseModel):
    """PVC enriched with pod usage information."""
    
    pvc: PVC
    pods: List[Pod] = Field(default_factory=list)
    is_unused: bool = False
    usage_bytes: Optional[int] = None
    usage_percentage: Optional[float] = None


class StorageClass(BaseModel):
    """Storage Class model."""
    
    name: str
    provisioner: str
    reclaim_policy: Optional[str] = None
    volume_binding_mode: Optional[str] = None
    allow_volume_expansion: bool = False
    parameters: Dict[str, str] = Field(default_factory=dict)


class ResourceQuota(BaseModel):
    """Resource Quota model."""
    
    name: str
    namespace: str
    hard_limits: Dict[str, str] = Field(default_factory=dict)
    used: Dict[str, str] = Field(default_factory=dict)
    has_storage_quota: bool = False
    storage_limit: Optional[str] = None
    storage_used: Optional[str] = None
    pvc_count_limit: Optional[int] = None
    pvc_count_used: Optional[int] = None


class StorageSummary(BaseModel):
    """Overall storage summary for a namespace."""
    
    namespace: str
    total_pvcs: int = 0
    bound_pvcs: int = 0
    pending_pvcs: int = 0
    unused_pvcs: int = 0
    total_capacity_gi: float = 0.0
    unused_capacity_gi: float = 0.0
    storage_classes: Dict[str, int] = Field(default_factory=dict)
    has_quota: bool = False
    quota: Optional[ResourceQuota] = None


class Recommendation(BaseModel):
    """Storage cleanup or optimization recommendation."""
    
    type: str  # unused_pvc, no_quota, pending_pvc
    severity: str  # warning, info, error
    title: str
    description: str
    pvc_name: Optional[str] = None
    capacity: Optional[str] = None
    capacity_gi: Optional[float] = None
    age_days: Optional[int] = None
    actionable: bool = True


class StorageAnalysis(BaseModel):
    """Complete storage analysis for a namespace."""
    
    namespace: str
    timestamp: datetime = Field(default_factory=datetime.now)
    summary: StorageSummary
    pvcs: List[PVCWithPods] = Field(default_factory=list)
    storage_classes: List[StorageClass] = Field(default_factory=list)
    recommendations: List[Recommendation] = Field(default_factory=list)
    
    class Config:
        json_encoders = {
            datetime: lambda v: v.isoformat() if v else None
        }


class PermissionReport(BaseModel):
    """Report of user permissions for K8s operations."""
    
    can_list_namespaces: bool = False
    can_list_pvcs: bool = False
    can_list_pods: bool = False
    can_list_storage_classes: bool = False
    can_list_resource_quotas: bool = False
    can_exec_into_pods: bool = False
    error_message: Optional[str] = None


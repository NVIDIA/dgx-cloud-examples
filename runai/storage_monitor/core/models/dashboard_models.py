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

"""Data models for multi-namespace dashboard."""

from datetime import datetime
from typing import Optional, List, Dict, Any
from pydantic import BaseModel, Field


class NamespaceSummary(BaseModel):
    """Lightweight namespace summary for dashboard."""
    
    namespace: str
    total_pvcs: int = 0
    unused_pvcs: int = 0
    bound_pvcs: int = 0
    pending_pvcs: int = 0
    total_capacity_gi: float = 0.0
    unused_capacity_gi: float = 0.0
    has_quota: bool = False
    error: Optional[str] = None
    
    class Config:
        json_encoders = {
            datetime: lambda v: v.isoformat() if v else None
        }


class ClusterOverview(BaseModel):
    """Cluster-wide storage overview."""
    
    total_namespaces: int = 0
    total_pvcs: int = 0
    total_capacity_gi: float = 0.0
    unused_capacity_gi: float = 0.0
    total_unused_pvcs: int = 0
    namespaces_with_quota: int = 0
    timestamp: datetime = Field(default_factory=datetime.now)
    
    class Config:
        json_encoders = {
            datetime: lambda v: v.isoformat() if v else None
        }


class GraphConfig(BaseModel):
    """Graph configuration metadata."""
    
    id: str
    name: str
    description: str
    chart_type: str  # bar, line, doughnut, pie
    default_enabled: bool = False
    requires_quota: bool = False


class GraphData(BaseModel):
    """Graph data for Chart.js."""
    
    type: str  # bar, line, doughnut, etc.
    labels: List[str] = Field(default_factory=list)
    datasets: List[Dict[str, Any]] = Field(default_factory=list)
    options: Dict[str, Any] = Field(default_factory=dict)


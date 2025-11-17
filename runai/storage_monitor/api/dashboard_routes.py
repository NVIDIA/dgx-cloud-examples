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

"""FastAPI routes for multi-namespace dashboard."""

from typing import Optional, List
from datetime import datetime, timedelta
from fastapi import APIRouter, Query, HTTPException

from ..core.services.dashboard_aggregator import DashboardAggregator
from ..core.models.dashboard_models import (
    ClusterOverview,
    NamespaceSummary,
    GraphData,
    GraphConfig
)
from ..core.clients.k8s_client import K8sClient
from ..core.logging_manager import get_logger

logger = get_logger()

dashboard_router = APIRouter(prefix="/dashboard", tags=["dashboard"])

# Global aggregator instance
_aggregator: Optional[DashboardAggregator] = None

# Simple cache (TTL: 30 seconds)
_cache = {
    "overview": {"data": None, "timestamp": None},
    "summaries": {"data": None, "timestamp": None}
}
CACHE_TTL = 30


def get_aggregator() -> DashboardAggregator:
    """Get or create dashboard aggregator instance."""
    global _aggregator
    if _aggregator is None:
        k8s_client = K8sClient()
        _aggregator = DashboardAggregator.from_k8s_client(k8s_client)
    return _aggregator


def get_cached(cache_key: str):
    """Get cached data if not expired."""
    cached = _cache.get(cache_key)
    if cached and cached["data"] and cached["timestamp"]:
        age = (datetime.now() - cached["timestamp"]).total_seconds()
        if age < CACHE_TTL:
            return cached["data"]
    return None


def set_cache(cache_key: str, data):
    """Set cached data with current timestamp."""
    _cache[cache_key] = {
        "data": data,
        "timestamp": datetime.now()
    }


@dashboard_router.get("/overview")
async def get_cluster_overview() -> ClusterOverview:
    """Get cluster-wide storage overview.
    
    Returns cluster-level aggregate metrics including total namespaces,
    PVCs, capacity, and unused resources. Cached for 30 seconds.
    """
    try:
        # Check cache first
        cached = get_cached("overview")
        if cached:
            return cached
        
        aggregator = get_aggregator()
        overview = aggregator.get_cluster_overview()
        
        # Cache result
        set_cache("overview", overview)
        
        logger.log_api_call(
            'GET', '/dashboard/overview', 'GUI', None, 200,
            {'namespaces': overview.total_namespaces, 'pvcs': overview.total_pvcs}
        )
        
        return overview
    except Exception as e:
        logger.log_api_call('GET', '/dashboard/overview', 'GUI', None, 500, None, str(e))
        raise HTTPException(status_code=500, detail="Failed to fetch cluster overview")


@dashboard_router.get("/namespaces/summaries")
async def get_namespace_summaries(
    namespaces: Optional[List[str]] = Query(None)
) -> List[NamespaceSummary]:
    """Get lightweight summaries for all or filtered namespaces.
    
    Args:
        namespaces: Optional list of namespace names to filter to.
                   If not provided, returns all Run.ai namespaces.
    
    Returns:
        List of namespace summaries with storage metrics.
        Failed namespaces are included with error field set.
        Cached for 30 seconds when fetching all namespaces.
    """
    try:
        # Only cache when fetching all namespaces (no filter)
        if namespaces is None:
            cached = get_cached("summaries")
            if cached:
                return cached
        
        aggregator = get_aggregator()
        summaries = await aggregator.get_namespace_summaries_async(namespaces)
        
        # Cache if fetching all
        if namespaces is None:
            set_cache("summaries", summaries)
        
        logger.log_api_call(
            'GET', '/dashboard/namespaces/summaries', 'GUI',
            {'filter_count': len(namespaces) if namespaces else None},
            200,
            {'count': len(summaries)}
        )
        
        return summaries
    except Exception as e:
        logger.log_api_call(
            'GET', '/dashboard/namespaces/summaries', 'GUI',
            None, 500, None, str(e)
        )
        raise HTTPException(status_code=500, detail="Failed to fetch namespace summaries")


@dashboard_router.get("/graphs/{graph_type}")
async def get_graph_data(
    graph_type: str,
    namespaces: Optional[List[str]] = Query(None),
    limit: Optional[int] = Query(None, ge=1, le=100)
) -> GraphData:
    """Get data for specific graph type with optional filtering.
    
    Args:
        graph_type: Type of graph (storage_usage, top_unused,
                   storage_class_dist, age_distribution, unused_capacity,
                   pvc_count)
        namespaces: Optional list of namespaces to filter to
        limit: Optional limit for top-N graphs
    
    Returns:
        Graph data formatted for Chart.js rendering
    """
    try:
        aggregator = get_aggregator()
        graph_data = await aggregator.get_graph_data_async(
            graph_type,
            namespaces,
            limit
        )
        
        logger.log_api_call(
            'GET', f'/dashboard/graphs/{graph_type}', 'GUI',
            {'limit': limit, 'filter_count': len(namespaces) if namespaces else None},
            200,
            {'datasets': len(graph_data.datasets)}
        )
        
        return graph_data
    except ValueError as e:
        logger.log_api_call(
            'GET', f'/dashboard/graphs/{graph_type}', 'GUI',
            None, 400, None, str(e)
        )
        raise HTTPException(status_code=400, detail=f"Invalid graph type: {graph_type}")
    except Exception as e:
        logger.log_api_call(
            'GET', f'/dashboard/graphs/{graph_type}', 'GUI',
            None, 500, None, str(e)
        )
        raise HTTPException(status_code=500, detail="Failed to generate graph data")


@dashboard_router.get("/config/graphs")
async def get_available_graphs() -> List[GraphConfig]:
    """Get list of available graph types with metadata.
    
    Returns:
        List of graph configurations including id, name, description,
        chart type, and default enabled status.
    """
    try:
        aggregator = get_aggregator()
        configs = aggregator.get_available_graph_configs()
        
        logger.log_api_call(
            'GET', '/dashboard/config/graphs', 'GUI',
            None, 200,
            {'count': len(configs)}
        )
        
        return configs
    except Exception as e:
        logger.log_api_call(
            'GET', '/dashboard/config/graphs', 'GUI',
            None, 500, None, str(e)
        )
        raise HTTPException(status_code=500, detail="Failed to fetch graph configurations")


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

"""Dashboard aggregation service for multi-namespace storage analysis."""

import asyncio
from typing import List, Optional, Dict, Any, AsyncGenerator
from datetime import datetime

from ..clients.k8s_client import K8sClient
from ..analyzers.storage_analyzer import StorageAnalyzer
from ..models.dashboard_models import (
    ClusterOverview,
    NamespaceSummary,
    GraphData,
    GraphConfig
)


# Number of namespaces analyzed concurrently per batch when aggregating.
# Enterprise clusters tolerate higher concurrency; adjust carefully if API
# throttling is observed in specific environments.
DEFAULT_NAMESPACE_BATCH_SIZE = 20


class DashboardAggregator:
    """Aggregate storage metrics across multiple namespaces."""
    
    def __init__(self, storage_analyzer: StorageAnalyzer):
        """Initialize dashboard aggregator.
        
        Args:
            storage_analyzer: Storage analyzer instance for namespace analysis
        """
        self.analyzer = storage_analyzer
        self.namespace_service = storage_analyzer.namespace_service
        self.pvc_service = storage_analyzer.pvc_service
        self.quota_service = storage_analyzer.quota_service
    
    @classmethod
    def from_k8s_client(cls, k8s_client: K8sClient) -> "DashboardAggregator":
        """Create aggregator from K8s client.
        
        Args:
            k8s_client: Kubernetes API client
            
        Returns:
            Configured DashboardAggregator instance
        """
        analyzer = StorageAnalyzer.from_k8s_client(k8s_client)
        return cls(analyzer)
    
    def get_cluster_overview(self) -> ClusterOverview:
        """Get high-level cluster-wide statistics.
        
        Returns:
            Cluster overview with aggregate metrics
        """
        namespaces = self.namespace_service.list_runai_namespaces()
        
        total_pvcs = 0
        total_capacity_gi = 0.0
        unused_capacity_gi = 0.0
        total_unused_pvcs = 0
        namespaces_with_quota = 0
        
        for namespace in namespaces:
            try:
                analysis = self.analyzer.analyze_namespace(namespace)
                total_pvcs += analysis.summary.total_pvcs
                total_capacity_gi += analysis.summary.total_capacity_gi
                unused_capacity_gi += analysis.summary.unused_capacity_gi
                total_unused_pvcs += analysis.summary.unused_pvcs
                if analysis.summary.has_quota:
                    namespaces_with_quota += 1
            except Exception:
                # Skip failed namespaces for overview
                continue
        
        return ClusterOverview(
            total_namespaces=len(namespaces),
            total_pvcs=total_pvcs,
            total_capacity_gi=total_capacity_gi,
            unused_capacity_gi=unused_capacity_gi,
            total_unused_pvcs=total_unused_pvcs,
            namespaces_with_quota=namespaces_with_quota,
            timestamp=datetime.now()
        )
    
    async def _fetch_summary(self, namespace: str) -> NamespaceSummary:
        """Fetch summary for a single namespace (async).
        
        Args:
            namespace: Namespace to analyze
            
        Returns:
            Namespace summary with metrics
        """
        try:
            # Run sync analyzer in executor to avoid blocking
            loop = asyncio.get_event_loop()
            analysis = await loop.run_in_executor(
                None,
                self.analyzer.analyze_namespace,
                namespace
            )
            
            return NamespaceSummary(
                namespace=namespace,
                total_pvcs=analysis.summary.total_pvcs,
                unused_pvcs=analysis.summary.unused_pvcs,
                bound_pvcs=analysis.summary.bound_pvcs,
                pending_pvcs=analysis.summary.pending_pvcs,
                total_capacity_gi=analysis.summary.total_capacity_gi,
                unused_capacity_gi=analysis.summary.unused_capacity_gi,
                has_quota=analysis.summary.has_quota
            )
        except Exception as e:
            return NamespaceSummary(
                namespace=namespace,
                error=str(e)
            )
    
    async def get_namespace_summaries_async(
        self,
        namespaces: Optional[List[str]] = None,
        batch_size: int = DEFAULT_NAMESPACE_BATCH_SIZE
    ) -> List[NamespaceSummary]:
        """Get summaries for multiple namespaces (async parallel fetch with batching).
        
        Args:
            namespaces: Optional list to filter. If None, fetches all Run.ai namespaces.
            batch_size: Number of concurrent requests to K8s API (default: 20)
            
        Returns:
            List of namespace summaries (includes errors as error markers)
        """
        if namespaces is None:
            namespaces = self.namespace_service.list_runai_namespaces()
        
        # Fetch in batches to avoid overwhelming K8s API
        summaries = []
        for i in range(0, len(namespaces), batch_size):
            batch = namespaces[i:i + batch_size]
            tasks = [self._fetch_summary(ns) for ns in batch]
            
            # Use wait_for with timeout
            try:
                results = await asyncio.wait_for(
                    asyncio.gather(*tasks, return_exceptions=True),
                    timeout=30.0
                )
                
                for j, result in enumerate(results):
                    if isinstance(result, Exception):
                        summaries.append(NamespaceSummary(
                            namespace=batch[j],
                            error="Fetch timeout or error"
                        ))
                    else:
                        summaries.append(result)
            except asyncio.TimeoutError:
                # Mark entire batch as timed out
                for ns in batch:
                    summaries.append(NamespaceSummary(
                        namespace=ns,
                        error="Request timeout"
                    ))
        
        return summaries
    
    async def stream_namespace_summaries(
        self,
        namespaces: List[str]
    ) -> AsyncGenerator[NamespaceSummary, None]:
        """Stream namespace summaries as they complete (progressive loading).
        
        Args:
            namespaces: List of namespaces to fetch
            
        Yields:
            NamespaceSummary as each completes
        """
        tasks = [self._fetch_summary(ns) for ns in namespaces]
        
        for completed in asyncio.as_completed(tasks):
            try:
                summary = await completed
                yield summary
            except Exception as e:
                yield NamespaceSummary(
                    namespace="unknown",
                    error=str(e)
                )
    
    def get_available_graph_configs(self) -> List[GraphConfig]:
        """Get list of available graph types with metadata.
        
        Returns:
            List of graph configurations
        """
        return [
            GraphConfig(
                id="storage_usage",
                name="Storage Usage",
                description="Used vs unused capacity per namespace",
                chart_type="bar",
                default_enabled=True
            ),
            GraphConfig(
                id="top_unused",
                name="Top Unused PVCs",
                description="Namespaces with most unused PVCs",
                chart_type="bar",
                default_enabled=True
            ),
            GraphConfig(
                id="storage_class_dist",
                name="Storage Class Distribution",
                description="PVC distribution by storage class",
                chart_type="doughnut",
                default_enabled=False
            ),
            GraphConfig(
                id="age_distribution",
                name="Unused PVC Age Distribution",
                description="Histogram of unused PVC ages",
                chart_type="bar",
                default_enabled=False
            ),
            GraphConfig(
                id="unused_capacity",
                name="Unused Capacity by Namespace",
                description="Namespaces sorted by wasted capacity",
                chart_type="bar",
                default_enabled=False
            ),
            GraphConfig(
                id="pvc_count",
                name="PVC Count by Namespace",
                description="Total PVC count per namespace",
                chart_type="bar",
                default_enabled=False
            )
        ]
    
    async def get_graph_data_async(
        self,
        graph_type: str,
        namespaces: Optional[List[str]] = None,
        limit: Optional[int] = None
    ) -> GraphData:
        """Generate data for specific graph type (async).
        
        Args:
            graph_type: Type of graph to generate
            namespaces: Optional filter to specific namespaces
            limit: Optional limit for top-N graphs
            
        Returns:
            Graph data formatted for Chart.js
        """
        summaries = await self.get_namespace_summaries_async(namespaces)
        
        # Filter out error summaries
        valid_summaries = [s for s in summaries if s.error is None]
        
        if graph_type == "storage_usage":
            return self._generate_storage_usage_graph(valid_summaries, limit)
        elif graph_type == "top_unused":
            return self._generate_top_unused_graph(valid_summaries, limit)
        elif graph_type == "storage_class_dist":
            return self._generate_storage_class_graph(valid_summaries)
        elif graph_type == "age_distribution":
            return await self._generate_age_distribution_graph(namespaces)
        elif graph_type == "unused_capacity":
            return self._generate_unused_capacity_graph(valid_summaries, limit)
        elif graph_type == "pvc_count":
            return self._generate_pvc_count_graph(valid_summaries, limit)
        else:
            raise ValueError(f"Unknown graph type: {graph_type}")
    
    def _generate_storage_usage_graph(
        self,
        summaries: List[NamespaceSummary],
        limit: Optional[int] = None
    ) -> GraphData:
        """Generate storage usage bar chart."""
        if limit:
            summaries = sorted(
                summaries,
                key=lambda s: s.total_capacity_gi,
                reverse=True
            )[:limit]
        
        labels = [s.namespace for s in summaries]
        used_data = [s.total_capacity_gi - s.unused_capacity_gi for s in summaries]
        unused_data = [s.unused_capacity_gi for s in summaries]
        
        return GraphData(
            type="bar",
            labels=labels,
            datasets=[
                {
                    "label": "Used (GiB)",
                    "data": used_data,
                    "backgroundColor": "#76b900"
                },
                {
                    "label": "Unused (GiB)",
                    "data": unused_data,
                    "backgroundColor": "#ef4444"
                }
            ],
            options={
                "scales": {
                    "x": {"stacked": True},
                    "y": {"stacked": True, "beginAtZero": True}
                }
            }
        )
    
    def _generate_top_unused_graph(
        self,
        summaries: List[NamespaceSummary],
        limit: Optional[int] = None
    ) -> GraphData:
        """Generate top unused PVCs bar chart."""
        sorted_summaries = sorted(
            summaries,
            key=lambda s: s.unused_pvcs,
            reverse=True
        )
        
        if limit:
            sorted_summaries = sorted_summaries[:limit]
        
        labels = [s.namespace for s in sorted_summaries]
        data = [s.unused_pvcs for s in sorted_summaries]
        
        return GraphData(
            type="bar",
            labels=labels,
            datasets=[{
                "label": "Unused PVCs",
                "data": data,
                "backgroundColor": "#ef4444"
            }],
            options={
                "scales": {
                    "y": {"beginAtZero": True}
                }
            }
        )
    
    def _generate_storage_class_graph(
        self,
        summaries: List[NamespaceSummary]
    ) -> GraphData:
        """Generate storage class distribution pie chart."""
        # This would require fetching storage class data
        # Placeholder implementation
        return GraphData(
            type="doughnut",
            labels=["standard", "fast", "archive"],
            datasets=[{
                "data": [60, 30, 10],
                "backgroundColor": ["#76b900", "#3b82f6", "#9ca3af"]
            }]
        )
    
    def _generate_unused_capacity_graph(
        self,
        summaries: List[NamespaceSummary],
        limit: Optional[int] = None
    ) -> GraphData:
        """Generate unused capacity bar chart."""
        sorted_summaries = sorted(
            summaries,
            key=lambda s: s.unused_capacity_gi,
            reverse=True
        )
        
        if limit:
            sorted_summaries = sorted_summaries[:limit]
        
        labels = [s.namespace for s in sorted_summaries]
        data = [s.unused_capacity_gi for s in sorted_summaries]
        
        return GraphData(
            type="bar",
            labels=labels,
            datasets=[{
                "label": "Unused Capacity (GiB)",
                "data": data,
                "backgroundColor": "#ef4444"
            }],
            options={
                "scales": {
                    "y": {"beginAtZero": True}
                }
            }
        )
    
    def _generate_pvc_count_graph(
        self,
        summaries: List[NamespaceSummary],
        limit: Optional[int] = None
    ) -> GraphData:
        """Generate PVC count bar chart."""
        sorted_summaries = sorted(
            summaries,
            key=lambda s: s.total_pvcs,
            reverse=True
        )
        
        if limit:
            sorted_summaries = sorted_summaries[:limit]
        
        labels = [s.namespace for s in sorted_summaries]
        data = [s.total_pvcs for s in sorted_summaries]
        
        return GraphData(
            type="bar",
            labels=labels,
            datasets=[{
                "label": "Total PVCs",
                "data": data,
                "backgroundColor": "#3b82f6"
            }],
            options={
                "scales": {
                    "y": {"beginAtZero": True}
                }
            }
        )
    
    async def _generate_age_distribution_graph(
        self,
        namespaces: Optional[List[str]] = None
    ) -> GraphData:
        """Generate age distribution histogram for unused PVCs."""
        if namespaces is None:
            namespaces = self.namespace_service.list_runai_namespaces()
        
        age_buckets = {"0-7d": 0, "8-30d": 0, "31-90d": 0, "91-180d": 0, "180d+": 0}
        
        for namespace in namespaces:
            try:
                unused_pvcs = self.analyzer.get_unused_pvcs(namespace)
                for pvc_wp in unused_pvcs:
                    age_days = pvc_wp.pvc.age_days or 0
                    if age_days <= 7:
                        age_buckets["0-7d"] += 1
                    elif age_days <= 30:
                        age_buckets["8-30d"] += 1
                    elif age_days <= 90:
                        age_buckets["31-90d"] += 1
                    elif age_days <= 180:
                        age_buckets["91-180d"] += 1
                    else:
                        age_buckets["180d+"] += 1
            except Exception:
                continue
        
        return GraphData(
            type="bar",
            labels=list(age_buckets.keys()),
            datasets=[{
                "label": "Unused PVCs",
                "data": list(age_buckets.values()),
                "backgroundColor": "#ef4444"
            }],
            options={
                "scales": {
                    "y": {"beginAtZero": True}
                }
            }
        )


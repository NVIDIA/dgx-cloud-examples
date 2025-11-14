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

"""CLI interface for Run.ai Storage Monitor (Tier 2)."""

import sys
import json
import asyncio
import click
from pathlib import Path
from typing import Optional
from tabulate import tabulate

from .core.clients.k8s_client import K8sClient
from .core.analyzers.storage_analyzer import StorageAnalyzer
from .core.services.dashboard_aggregator import DashboardAggregator


@click.group()
@click.version_option(version="1.0.0")
def cli():
    """Run.ai Storage Monitor - Kubernetes storage visibility tool.
    
    A community example tool for DGX Cloud Run.ai deployments.
    """
    pass


@cli.command()
@click.option("--kubeconfig", type=click.Path(exists=True), help="Path to kubeconfig file")
@click.option("--context", help="Kubernetes context to use")
def list_namespaces(kubeconfig: Optional[str], context: Optional[str]):
    """List all Run.ai namespaces."""
    try:
        k8s_client = K8sClient(kubeconfig_path=kubeconfig, context=context)
        analyzer = StorageAnalyzer.from_k8s_client(k8s_client)
        
        namespaces = analyzer.list_runai_namespaces()
        
        if not namespaces:
            click.echo("No Run.ai namespaces found")
            return
        
        click.echo(f"Found {len(namespaces)} Run.ai namespaces:\n")
        for ns in namespaces:
            click.echo(f"  {ns}")
    
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@cli.command()
@click.argument("namespace")
@click.option("--kubeconfig", type=click.Path(exists=True), help="Path to kubeconfig file")
@click.option("--context", help="Kubernetes context to use")
@click.option("--format", "output_format", type=click.Choice(["text", "json"]), default="text")
def analyze(namespace: str, kubeconfig: Optional[str], context: Optional[str], output_format: str):
    """Analyze storage for a namespace."""
    try:
        k8s_client = K8sClient(kubeconfig_path=kubeconfig, context=context)
        analyzer = StorageAnalyzer.from_k8s_client(k8s_client)
        
        click.echo(f"Analyzing storage for namespace: {namespace}...")
        analysis = analyzer.analyze_namespace(namespace)
        
        if output_format == "json":
            click.echo(analysis.model_dump_json(indent=2))
        else:
            _print_text_analysis(analysis)
    
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@cli.command()
@click.argument("namespace")
@click.option("--kubeconfig", type=click.Path(exists=True), help="Path to kubeconfig file")
@click.option("--context", help="Kubernetes context to use")
def unused(namespace: str, kubeconfig: Optional[str], context: Optional[str]):
    """List unused PVCs in a namespace."""
    try:
        k8s_client = K8sClient(kubeconfig_path=kubeconfig, context=context)
        analyzer = StorageAnalyzer.from_k8s_client(k8s_client)
        
        unused_pvcs = analyzer.get_unused_pvcs(namespace)
        
        if not unused_pvcs:
            click.echo(f"No unused PVCs found in namespace: {namespace}")
            return
        
        click.echo(f"Found {len(unused_pvcs)} unused PVCs in {namespace}:\n")
        
        table_data = []
        total_capacity_gi = 0.0
        
        for pvc_wp in unused_pvcs:
            capacity_gi = analyzer.pvc_service.parse_capacity_to_gi(pvc_wp.pvc.capacity)
            total_capacity_gi += capacity_gi
            
            table_data.append([
                pvc_wp.pvc.name,
                pvc_wp.pvc.capacity,
                pvc_wp.pvc.storage_class or "default",
                f"{pvc_wp.pvc.age_days}d" if pvc_wp.pvc.age_days else "Unknown"
            ])
        
        click.echo(tabulate(
            table_data,
            headers=["PVC Name", "Capacity", "Storage Class", "Age"],
            tablefmt="simple"
        ))
        
        click.echo(f"\nTotal unused capacity: {total_capacity_gi:.2f}Gi")
    
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@cli.command()
@click.argument("namespace")
@click.option("--kubeconfig", type=click.Path(exists=True), help="Path to kubeconfig file")
@click.option("--context", help="Kubernetes context to use")
def quotas(namespace: str, kubeconfig: Optional[str], context: Optional[str]):
    """Show resource quotas for a namespace."""
    try:
        k8s_client = K8sClient(kubeconfig_path=kubeconfig, context=context)
        analyzer = StorageAnalyzer.from_k8s_client(k8s_client)
        
        quota = analyzer.quota_service.get_storage_quota(namespace)
        
        if not quota:
            click.echo(f"No resource quotas found in namespace: {namespace}")
            click.echo("\nConsider adding storage quotas to control usage.")
            return
        
        click.echo(f"Resource Quotas for {namespace}:\n")
        
        if quota.storage_limit:
            click.echo(f"Storage Limit: {quota.storage_limit}")
            if quota.storage_used:
                click.echo(f"Storage Used: {quota.storage_used}")
        
        if quota.pvc_count_limit:
            click.echo(f"PVC Count Limit: {quota.pvc_count_limit}")
            if quota.pvc_count_used is not None:
                usage_pct = (quota.pvc_count_used / quota.pvc_count_limit) * 100
                click.echo(f"PVC Count Used: {quota.pvc_count_used} ({usage_pct:.1f}%)")
    
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@cli.command()
@click.argument("namespace")
@click.argument("output_file", type=click.Path())
@click.option("--kubeconfig", type=click.Path(exists=True), help="Path to kubeconfig file")
@click.option("--context", help="Kubernetes context to use")
@click.option("--format", "output_format", type=click.Choice(["json", "csv"]), default="json")
def export(namespace: str, output_file: str, kubeconfig: Optional[str], context: Optional[str], output_format: str):
    """Export storage analysis to file."""
    try:
        k8s_client = K8sClient(kubeconfig_path=kubeconfig, context=context)
        analyzer = StorageAnalyzer.from_k8s_client(k8s_client)
        
        click.echo(f"Analyzing {namespace}...")
        analysis = analyzer.analyze_namespace(namespace)
        
        if output_format == "json":
            with open(output_file, "w") as f:
                f.write(analysis.model_dump_json(indent=2))
        elif output_format == "csv":
            # Simple CSV export of PVCs
            import csv
            with open(output_file, "w", newline="") as f:
                writer = csv.writer(f)
                writer.writerow(["Name", "Status", "Capacity", "Storage Class", "Pods", "Unused", "Age (days)"])
                for pvc_wp in analysis.pvcs:
                    writer.writerow([
                        pvc_wp.pvc.name,
                        pvc_wp.pvc.status,
                        pvc_wp.pvc.capacity,
                        pvc_wp.pvc.storage_class or "default",
                        len(pvc_wp.pods),
                        "Yes" if pvc_wp.is_unused else "No",
                        pvc_wp.pvc.age_days or "Unknown"
                    ])
        
        click.echo(f"Analysis exported to: {output_file}")
    
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@cli.command()
@click.option("--kubeconfig", type=click.Path(exists=True), help="Path to kubeconfig file")
@click.option("--context", help="Kubernetes context to use")
def check_permissions(kubeconfig: Optional[str], context: Optional[str]):
    """Check Kubernetes permissions."""
    try:
        k8s_client = K8sClient(kubeconfig_path=kubeconfig, context=context)
        
        click.echo("Checking Kubernetes permissions...\n")
        permissions = k8s_client.check_permissions()
        
        checks = [
            ("List Namespaces", permissions["can_list_namespaces"]),
            ("List PVCs", permissions["can_list_pvcs"]),
            ("List Pods", permissions["can_list_pods"]),
            ("List Storage Classes", permissions["can_list_storage_classes"]),
            ("List Resource Quotas", permissions["can_list_resource_quotas"]),
        ]
        
        for check_name, result in checks:
            status = "✓" if result else "✗"
            click.echo(f"{status} {check_name}")
        
        if permissions.get("error_message"):
            click.echo(f"\nError: {permissions['error_message']}", err=True)
    
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@cli.group()
def daemon():
    """Daemon management for API server."""
    pass


@daemon.command()
@click.option("--port", default=8081, help="Port for API server")
@click.option("--host", default="127.0.0.1", help="Host for API server")
def start(port: int, host: str):
    """Start API daemon."""
    click.echo(f"Starting API daemon on {host}:{port}...")
    click.echo("Use 'runai-storage daemon stop' to stop the daemon")
    
    # Import here to avoid loading FastAPI dependencies unless needed
    from .api.server import run_server
    run_server(host=host, port=port)


@daemon.command()
def stop():
    """Stop API daemon."""
    click.echo("Daemon stop not yet implemented (use Ctrl+C to stop running daemon)")


@daemon.command()
def status():
    """Check daemon status."""
    click.echo("Daemon status check not yet implemented")


def _print_text_analysis(analysis):
    """Print analysis in human-readable text format."""
    click.echo("\n" + "=" * 60)
    click.echo(f"Storage Analysis: {analysis.namespace}")
    click.echo("=" * 60)
    
    # Summary
    click.echo("\nSummary:")
    click.echo(f"  Total PVCs: {analysis.summary.total_pvcs}")
    click.echo(f"  Bound: {analysis.summary.bound_pvcs}")
    click.echo(f"  Pending: {analysis.summary.pending_pvcs}")
    click.echo(f"  Unused: {analysis.summary.unused_pvcs}")
    click.echo(f"  Total Capacity: {analysis.summary.total_capacity_gi:.2f}Gi")
    click.echo(f"  Unused Capacity: {analysis.summary.unused_capacity_gi:.2f}Gi")
    
    # Storage classes
    if analysis.summary.storage_classes:
        click.echo("\nStorage Classes:")
        for sc, count in analysis.summary.storage_classes.items():
            click.echo(f"  {sc}: {count} PVCs")
    
    # Quotas
    if analysis.summary.has_quota and analysis.summary.quota:
        click.echo("\nResource Quota:")
        quota = analysis.summary.quota
        if quota.storage_limit:
            click.echo(f"  Storage: {quota.storage_used or '0'} / {quota.storage_limit}")
        if quota.pvc_count_limit:
            click.echo(f"  PVC Count: {quota.pvc_count_used or 0} / {quota.pvc_count_limit}")
    
    # Recommendations
    if analysis.recommendations:
        click.echo("\nRecommendations:")
        for rec in analysis.recommendations:
            severity_icon = "⚠️" if rec.severity == "warning" else "ℹ️" if rec.severity == "info" else "❌"
            click.echo(f"  {severity_icon} {rec.title}")
            click.echo(f"     {rec.description}")


@cli.group()
def dashboard():
    """Multi-namespace dashboard commands."""
    pass


@dashboard.command()
@click.option("--kubeconfig", type=click.Path(exists=True), help="Path to kubeconfig file")
@click.option("--context", help="Kubernetes context to use")
@click.option("--format", "output_format", type=click.Choice(["text", "json"]), default="text")
def overview(kubeconfig: Optional[str], context: Optional[str], output_format: str):
    """Get cluster-wide storage overview."""
    try:
        k8s_client = K8sClient(kubeconfig_path=kubeconfig, context=context)
        aggregator = DashboardAggregator.from_k8s_client(k8s_client)
        
        cluster_overview = aggregator.get_cluster_overview()
        
        if output_format == "json":
            click.echo(cluster_overview.model_dump_json(indent=2))
        else:
            click.echo("\nCluster Storage Overview")
            click.echo("=" * 50)
            click.echo(f"Total Namespaces:        {cluster_overview.total_namespaces}")
            click.echo(f"Total PVCs:              {cluster_overview.total_pvcs}")
            click.echo(f"Total Capacity:          {cluster_overview.total_capacity_gi:.2f} GiB")
            click.echo(f"Unused Capacity:         {cluster_overview.unused_capacity_gi:.2f} GiB")
            click.echo(f"Total Unused PVCs:       {cluster_overview.total_unused_pvcs}")
            click.echo(f"Namespaces with Quota:   {cluster_overview.namespaces_with_quota}")
    
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@dashboard.command()
@click.option("--kubeconfig", type=click.Path(exists=True), help="Path to kubeconfig file")
@click.option("--context", help="Kubernetes context to use")
@click.option("--format", "output_format", type=click.Choice(["text", "json", "csv"]), default="text")
def summaries(kubeconfig: Optional[str], context: Optional[str], output_format: str):
    """Get storage summaries for all namespaces."""
    try:
        k8s_client = K8sClient(kubeconfig_path=kubeconfig, context=context)
        aggregator = DashboardAggregator.from_k8s_client(k8s_client)
        
        namespace_summaries = asyncio.run(aggregator.get_namespace_summaries_async())
        
        if output_format == "json":
            summaries_dict = [s.model_dump() for s in namespace_summaries]
            click.echo(json.dumps(summaries_dict, indent=2))
        elif output_format == "csv":
            click.echo("namespace,total_pvcs,unused_pvcs,total_capacity_gi,unused_capacity_gi,has_quota,error")
            for s in namespace_summaries:
                click.echo(f"{s.namespace},{s.total_pvcs},{s.unused_pvcs},{s.total_capacity_gi:.2f}," +
                          f"{s.unused_capacity_gi:.2f},{s.has_quota},{s.error or ''}")
        else:
            headers = ["Namespace", "Total PVCs", "Unused PVCs", "Total Capacity", "Unused Capacity", "Has Quota"]
            rows = []
            for s in namespace_summaries:
                if s.error:
                    rows.append([s.namespace, "ERROR", s.error, "", "", ""])
                else:
                    rows.append([
                        s.namespace,
                        s.total_pvcs,
                        s.unused_pvcs,
                        f"{s.total_capacity_gi:.2f} GiB",
                        f"{s.unused_capacity_gi:.2f} GiB",
                        "Yes" if s.has_quota else "No"
                    ])
            click.echo("\n" + tabulate(rows, headers=headers, tablefmt="simple"))
    
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@dashboard.command()
@click.argument("output_file", type=click.Path())
@click.option("--kubeconfig", type=click.Path(exists=True), help="Path to kubeconfig file")
@click.option("--context", help="Kubernetes context to use")
@click.option("--format", "output_format", type=click.Choice(["json", "csv"]), default="json")
def export(output_file: str, kubeconfig: Optional[str], context: Optional[str], output_format: str):
    """Export dashboard data to file."""
    try:
        k8s_client = K8sClient(kubeconfig_path=kubeconfig, context=context)
        aggregator = DashboardAggregator.from_k8s_client(k8s_client)
        
        cluster_overview = aggregator.get_cluster_overview()
        namespace_summaries = asyncio.run(aggregator.get_namespace_summaries_async())
        
        output_path = Path(output_file)
        
        if output_format == "json":
            data = {
                "overview": cluster_overview.model_dump(),
                "namespaces": [s.model_dump() for s in namespace_summaries]
            }
            output_path.write_text(json.dumps(data, indent=2, default=str))
        else:
            lines = ["namespace,total_pvcs,unused_pvcs,total_capacity_gi,unused_capacity_gi,has_quota,error"]
            for s in namespace_summaries:
                lines.append(f"{s.namespace},{s.total_pvcs},{s.unused_pvcs},{s.total_capacity_gi:.2f}," +
                           f"{s.unused_capacity_gi:.2f},{s.has_quota},{s.error or ''}")
            output_path.write_text("\n".join(lines))
        
        click.echo(f"Dashboard data exported to: {output_path}")
    
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


@dashboard.command()
@click.argument("graph_type")
@click.option("--kubeconfig", type=click.Path(exists=True), help="Path to kubeconfig file")
@click.option("--context", help="Kubernetes context to use")
@click.option("--limit", type=int, help="Limit for top-N graphs")
def graph(graph_type: str, kubeconfig: Optional[str], context: Optional[str], limit: Optional[int]):
    """Generate graph data for specific visualization."""
    try:
        k8s_client = K8sClient(kubeconfig_path=kubeconfig, context=context)
        aggregator = DashboardAggregator.from_k8s_client(k8s_client)
        
        graph_data = asyncio.run(aggregator.get_graph_data_async(graph_type, limit=limit))
        
        click.echo(graph_data.model_dump_json(indent=2))
    
    except ValueError as e:
        click.echo(f"Invalid graph type: {e}", err=True)
        click.echo("\nAvailable graph types:")
        click.echo("  - storage_usage")
        click.echo("  - top_unused")
        click.echo("  - storage_class_dist")
        click.echo("  - age_distribution")
        click.echo("  - unused_capacity")
        click.echo("  - pvc_count")
        sys.exit(1)
    except Exception as e:
        click.echo(f"Error: {e}", err=True)
        sys.exit(1)


if __name__ == "__main__":
    cli()


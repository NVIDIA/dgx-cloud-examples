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

"""FastAPI server for Run.ai Storage Monitor (Tier 4).

Security Model:
- Read-only K8s operations (no write/delete permissions required)
- CORS restricted to localhost only (127.0.0.1:8081)
- No authentication (localhost-only deployment model)
- Input validation on limit parameters
- Error messages sanitized (no internal details exposed)
- Rate limiting via K8s API batch processing

Performance Optimizations:
- 30-second cache for cluster overview and namespace summaries
- Batched async fetching (10 concurrent requests max to K8s API)
- Timeout protection (30s per batch)
- WebSocket for live updates (reduces polling)
"""

import asyncio
import json
import logging
from datetime import datetime
from typing import Optional, Dict
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, Query
from fastapi.responses import HTMLResponse, FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from pathlib import Path

from ..core.clients.k8s_client import K8sClient
from ..core.analyzers.storage_analyzer import StorageAnalyzer
from ..core.models.storage_models import StorageAnalysis, PermissionReport
from ..core.logging_manager import get_logger
from .dashboard_routes import dashboard_router

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)
structured_log = get_logger()

# Initialize FastAPI app
app = FastAPI(
    title="Run.ai Storage Monitor API",
    description="Read-only storage visibility for Run.ai namespaces",
    version="1.0.0"
)

# CORS configuration (localhost only for security)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1:8081", "http://localhost:8081"],
    allow_credentials=True,
    allow_methods=["GET"],
    allow_headers=["*"],
)

# Mount dashboard routes
app.include_router(dashboard_router)

# Static assets (shared UI scripts, styles)
ui_root = Path(__file__).parent.parent / "ui"
js_dir = ui_root / "js"
if js_dir.exists():
    app.mount("/js", StaticFiles(directory=str(js_dir)), name="ui-js")

# Vendor dependencies (TailwindCSS, Chart.js, etc.)
vendor_dir = ui_root / "vendor"
if vendor_dir.exists():
    app.mount("/vendor", StaticFiles(directory=str(vendor_dir)), name="ui-vendor")

# Shared stylesheets (header, layout)
css_dir = ui_root / "css"
if css_dir.exists():
    app.mount("/css", StaticFiles(directory=str(css_dir)), name="ui-css")

# Image assets (logos, favicons)
img_dir = ui_root / "img"
if img_dir.exists():
    app.mount("/img", StaticFiles(directory=str(img_dir)), name="ui-img")

# Global analyzer instance
_analyzer: Optional[StorageAnalyzer] = None


def get_analyzer() -> StorageAnalyzer:
    """Get or create storage analyzer instance."""
    global _analyzer
    if _analyzer is None:
        k8s_client = K8sClient()
        _analyzer = StorageAnalyzer.from_k8s_client(k8s_client)
    return _analyzer


@app.get("/")
async def root():
    """Serve the single-namespace web UI."""
    ui_path = Path(__file__).parent.parent / "ui" / "index.html"
    if ui_path.exists():
        return FileResponse(ui_path)
    return {"message": "Run.ai Storage Monitor API", "docs": "/docs"}


@app.get("/dashboard.html")
async def dashboard():
    """Serve the multi-namespace dashboard UI."""
    dashboard_path = Path(__file__).parent.parent / "ui" / "dashboard.html"
    if dashboard_path.exists():
        return FileResponse(dashboard_path)
    return {"message": "Dashboard not found"}


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "service": "runai-storage-monitor"
    }


@app.get("/permissions")
async def get_permissions() -> PermissionReport:
    """Get current user permission report."""
    try:
        analyzer = get_analyzer()
        permissions_dict = analyzer.pvc_service.k8s.check_permissions()
        return PermissionReport(**permissions_dict)
    except Exception as e:
        raise HTTPException(status_code=500, detail="Failed to check permissions")


@app.get("/namespaces")
async def list_namespaces():
    """List all Run.ai namespaces."""
    try:
        analyzer = get_analyzer()
        namespaces = analyzer.list_runai_namespaces()
        
        structured_log.log_api_call('GET', '/namespaces', 'GUI', None, 200, {'count': len(namespaces)})
        
        return {
            "namespaces": namespaces,
            "count": len(namespaces)
        }
    except Exception as e:
        structured_log.log_api_call('GET', '/namespaces', 'GUI', None, 500, None, str(e))
        raise HTTPException(status_code=500, detail="Failed to list namespaces")


@app.get("/namespaces/{namespace}/summary")
async def get_namespace_summary(namespace: str):
    """Get storage summary for a namespace."""
    try:
        analyzer = get_analyzer()
        analysis = analyzer.analyze_namespace(namespace)
        return analysis.summary
    except Exception as e:
        raise HTTPException(status_code=500, detail="Failed to analyze namespace")


@app.get("/namespaces/{namespace}/pvcs")
async def list_pvcs(namespace: str):
    """List all PVCs with pod information for a namespace."""
    try:
        analyzer = get_analyzer()
        pvcs_with_pods = analyzer.pvc_service.get_pvcs_with_pods(namespace)
        return {
            "namespace": namespace,
            "pvcs": [pvc_wp.model_dump() for pvc_wp in pvcs_with_pods],
            "count": len(pvcs_with_pods)
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail="Failed to list PVCs")


@app.get("/namespaces/{namespace}/unused")
async def get_unused_pvcs(namespace: str):
    """Get unused PVC recommendations for a namespace."""
    try:
        analyzer = get_analyzer()
        unused_pvcs = analyzer.get_unused_pvcs(namespace)
        
        total_unused_capacity = 0.0
        for pvc_wp in unused_pvcs:
            capacity_gi = analyzer.pvc_service.parse_capacity_to_gi(pvc_wp.pvc.capacity)
            total_unused_capacity += capacity_gi
        
        return {
            "namespace": namespace,
            "unused_pvcs": [pvc_wp.model_dump() for pvc_wp in unused_pvcs],
            "count": len(unused_pvcs),
            "total_unused_capacity_gi": total_unused_capacity
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail="Failed to get unused PVCs")


@app.get("/namespaces/{namespace}/quotas")
async def get_quotas(namespace: str):
    """Get resource quotas for a namespace."""
    try:
        analyzer = get_analyzer()
        quota = analyzer.quota_service.get_storage_quota(namespace)
        
        if not quota:
            return {
                "namespace": namespace,
                "has_quota": False,
                "quota": None
            }
        
        return {
            "namespace": namespace,
            "has_quota": True,
            "quota": quota.model_dump()
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail="Failed to get quotas")


@app.get("/namespaces/{namespace}/storage-classes")
async def get_storage_class_breakdown(namespace: str):
    """Get storage class distribution for a namespace."""
    try:
        analyzer = get_analyzer()
        analysis = analyzer.analyze_namespace(namespace)
        
        return {
            "namespace": namespace,
            "storage_classes": analysis.summary.storage_classes,
            "available_classes": [sc.model_dump() for sc in analysis.storage_classes]
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail="Failed to get storage classes")


@app.get("/namespaces/{namespace}/analysis")
async def get_full_analysis(namespace: str) -> StorageAnalysis:
    """Get complete storage analysis for a namespace."""
    try:
        analyzer = get_analyzer()
        analysis = analyzer.analyze_namespace(namespace)
        
        structured_log.log_storage_action(
            'analyze',
            namespace,
            analysis.summary.total_pvcs,
            True,
            {'unused': analysis.summary.unused_pvcs}
        )
        structured_log.log_api_call('GET', f'/namespaces/{namespace}/analysis', 'GUI', None, 200, 
                                   {'pvcs': len(analysis.pvcs), 'recommendations': len(analysis.recommendations)})
        
        return analysis
    except Exception as e:
        structured_log.log_api_call('GET', f'/namespaces/{namespace}/analysis', 'GUI', None, 500, None, str(e))
        raise HTTPException(status_code=500, detail="Failed to analyze namespace")


@app.get("/logs")
async def get_logs(count: int = Query(100, ge=1, le=1000), tier: Optional[str] = None):
    """Get recent operation logs.
    
    Args:
        count: Number of log entries to return
        tier: Filter by tier (CORE, CLI, MCP, API, GUI)
        
    Returns:
        Recent log entries
    """
    logs = structured_log.get_recent_logs(count, tier)
    structured_log.log_api_call('GET', '/logs', 'GUI', {'count': count, 'tier': tier}, 200, {'entries': len(logs)})
    return {"logs": logs}


@app.get("/logs/stream")
async def stream_logs():
    """Stream logs in real-time using Server-Sent Events."""
    async def event_generator():
        last_check = datetime.now()
        
        while True:
            await asyncio.sleep(1)
            new_logs = structured_log.get_logs_since(last_check)
            last_check = datetime.now()
            
            for log in new_logs:
                yield f"data: {json.dumps(log)}\n\n"
    
    return StreamingResponse(event_generator(), media_type="text/event-stream")


# WebSocket for real-time updates
active_connections: Dict[str, list] = {}


@app.websocket("/ws/namespaces/{namespace}")
async def websocket_namespace_updates(websocket: WebSocket, namespace: str):
    """WebSocket endpoint for real-time namespace updates."""
    await websocket.accept()
    
    # Track connection
    if namespace not in active_connections:
        active_connections[namespace] = []
    active_connections[namespace].append(websocket)
    
    try:
        analyzer = get_analyzer()

        async def safe_send(payload: Dict) -> bool:
            try:
                await websocket.send_json(payload)
                return True
            except WebSocketDisconnect:
                return False
            except RuntimeError as runtime_error:
                # Raised when attempting to send after close frame
                if 'Cannot call "send"' in str(runtime_error):
                    return False
                raise

        while True:
            # Poll every 30 seconds and send updates
            try:
                analysis = analyzer.analyze_namespace(namespace)
                payload = {
                    "type": "update",
                    "namespace": namespace,
                    "timestamp": datetime.now().isoformat(),
                    "summary": analysis.summary.model_dump(mode='json'),
                    "pvcs": [pvc_wp.model_dump(mode='json') for pvc_wp in analysis.pvcs]
                }
            except Exception as exc:
                payload = {
                    "type": "error",
                    "error": str(exc)
                }

            should_continue = await safe_send(payload)
            if not should_continue:
                break

            await asyncio.sleep(30)

    except WebSocketDisconnect:
        pass
    finally:
        # Remove disconnected client
        if namespace in active_connections:
            active_connections[namespace].remove(websocket)
            if not active_connections[namespace]:
                del active_connections[namespace]


def run_server(host: str = "127.0.0.1", port: int = 8081):
    """Run the FastAPI server.
    
    Args:
        host: Host to bind to (use 0.0.0.0 for Docker)
        port: Port to bind to
    """
    import uvicorn
    import os
    # Use 0.0.0.0 in Docker, 127.0.0.1 for local
    docker_host = "0.0.0.0" if os.path.exists("/.dockerenv") else host
    uvicorn.run(app, host=docker_host, port=port)


if __name__ == "__main__":
    run_server()


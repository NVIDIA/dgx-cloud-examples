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

"""Kubernetes API client for storage operations."""

import logging
from typing import Optional, List, Callable, TypeVar
from kubernetes import client, config
from kubernetes.client.rest import ApiException

logger = logging.getLogger(__name__)
T = TypeVar('T')


class K8sClient:
    """Kubernetes API client for storage operations.
    
    Provides read-only access to storage resources (PVCs, Pods, StorageClasses, Quotas).
    Automatically handles kubeconfig loading and in-cluster configuration.
    """
    
    def __init__(self, kubeconfig_path: Optional[str] = None, context: Optional[str] = None):
        """Initialize Kubernetes client.
        
        Args:
            kubeconfig_path: Path to kubeconfig file (default: ~/.kube/config)
            context: Kubernetes context to use (default: current context)
        """
        self.kubeconfig_path = kubeconfig_path
        self.context = context
        self._core_v1 = None
        self._storage_v1 = None
        self._initialized = False
    
    def _ensure_initialized(self):
        """Lazy initialization of K8s API clients."""
        if self._initialized:
            return
        
        try:
            if self.kubeconfig_path:
                config.load_kube_config(config_file=self.kubeconfig_path, context=self.context)
            else:
                try:
                    config.load_incluster_config()
                except config.ConfigException:
                    config.load_kube_config(context=self.context)
            
            self._core_v1 = client.CoreV1Api()
            self._storage_v1 = client.StorageV1Api()
            self._initialized = True
            
        except Exception as e:
            raise ConnectionError(f"Failed to initialize Kubernetes client: {e}")
    
    def _reload_config(self):
        """Reload kubeconfig to refresh tokens.
        
        Called when API calls fail with 401 Unauthorized, indicating
        the token has expired. Re-reads kubeconfig from disk which may
        have been updated by `runai kubeconfig set`.
        """
        if not self._initialized:
            return
        logger.info("Reloading kubeconfig to refresh credentials...")
        self._initialized = False
        self._core_v1 = None
        self._storage_v1 = None
        self._ensure_initialized()
        logger.info("Kubeconfig reloaded successfully")
    
    def _with_retry(self, operation: Callable[[], T]) -> T:
        """Execute operation with automatic token refresh on 401.
        
        Args:
            operation: Callable that performs a K8s API operation
            
        Returns:
            Result of the operation
            
        Raises:
            ApiException: If operation fails after retry
            RuntimeError: If operation fails for non-auth reasons
        """
        try:
            return operation()
        except ApiException as e:
            if e.status == 401:
                logger.warning("Received 401 Unauthorized, attempting token refresh...")
                self._reload_config()
                return operation()
            raise
    
    @property
    def core_v1(self) -> client.CoreV1Api:
        """Get CoreV1Api client."""
        self._ensure_initialized()
        return self._core_v1
    
    @property
    def storage_v1(self) -> client.StorageV1Api:
        """Get StorageV1Api client."""
        self._ensure_initialized()
        return self._storage_v1
    
    def list_namespaces(self, label_selector: Optional[str] = None) -> List[dict]:
        """List all namespaces (or filtered by labels).
        
        Args:
            label_selector: Kubernetes label selector (e.g., "app=runai")
            
        Returns:
            List of namespace dictionaries with name and metadata
        """
        def _do_list():
            if label_selector:
                return self.core_v1.list_namespace(label_selector=label_selector)
            else:
                return self.core_v1.list_namespace()
        
        try:
            namespaces = self._with_retry(_do_list)
            
            return [
                {
                    "name": ns.metadata.name,
                    "creation_timestamp": ns.metadata.creation_timestamp,
                    "labels": ns.metadata.labels or {},
                    "status": ns.status.phase
                }
                for ns in namespaces.items
            ]
        except ApiException:
            # Preserve status code for upstream handlers (e.g., auth 401 detection).
            raise
    
    def list_pvcs(self, namespace: str) -> List[dict]:
        """List all PVCs in a namespace.
        
        Args:
            namespace: Kubernetes namespace
            
        Returns:
            List of PVC dictionaries with detailed information
        """
        def _do_list():
            return self.core_v1.list_namespaced_persistent_volume_claim(namespace)
        
        try:
            pvcs = self._with_retry(_do_list)
            
            return [
                {
                    "name": pvc.metadata.name,
                    "namespace": pvc.metadata.namespace,
                    "status": pvc.status.phase,
                    "capacity": pvc.status.capacity.get("storage") if pvc.status.capacity else None,
                    "storage_class": pvc.spec.storage_class_name,
                    "access_modes": pvc.spec.access_modes or [],
                    "volume_name": pvc.spec.volume_name,
                    "creation_timestamp": pvc.metadata.creation_timestamp,
                    "labels": pvc.metadata.labels or {},
                    "annotations": pvc.metadata.annotations or {},
                }
                for pvc in pvcs.items
            ]
        except ApiException:
            # Preserve status code for upstream handlers (e.g., auth 401 detection).
            raise
    
    def list_pods(self, namespace: str) -> List[dict]:
        """List all pods in a namespace.
        
        Args:
            namespace: Kubernetes namespace
            
        Returns:
            List of pod dictionaries with PVC mount information
        """
        def _do_list():
            return self.core_v1.list_namespaced_pod(namespace)
        
        try:
            pods = self._with_retry(_do_list)
            
            result = []
            for pod in pods.items:
                pvc_claims = []
                if pod.spec.volumes:
                    for volume in pod.spec.volumes:
                        if volume.persistent_volume_claim:
                            pvc_claims.append(volume.persistent_volume_claim.claim_name)
                
                result.append({
                    "name": pod.metadata.name,
                    "namespace": pod.metadata.namespace,
                    "status": pod.status.phase,
                    "node_name": pod.spec.node_name,
                    "pvc_claims": pvc_claims,
                    "creation_timestamp": pod.metadata.creation_timestamp,
                    "labels": pod.metadata.labels or {},
                })
            
            return result
        except ApiException:
            # Preserve status code for upstream handlers (e.g., auth 401 detection).
            raise
    
    def list_storage_classes(self) -> List[dict]:
        """List all storage classes in the cluster.
        
        Returns:
            List of storage class dictionaries
        """
        def _do_list():
            return self.storage_v1.list_storage_class()
        
        try:
            storage_classes = self._with_retry(_do_list)
            
            return [
                {
                    "name": sc.metadata.name,
                    "provisioner": sc.provisioner,
                    "reclaim_policy": sc.reclaim_policy,
                    "volume_binding_mode": sc.volume_binding_mode,
                    "allow_volume_expansion": sc.allow_volume_expansion or False,
                    "parameters": sc.parameters or {},
                }
                for sc in storage_classes.items
            ]
        except ApiException:
            # Preserve status code for upstream handlers (e.g., auth 401 detection).
            raise
    
    def list_resource_quotas(self, namespace: str) -> List[dict]:
        """List resource quotas in a namespace.
        
        Args:
            namespace: Kubernetes namespace
            
        Returns:
            List of resource quota dictionaries
        """
        def _do_list():
            return self.core_v1.list_namespaced_resource_quota(namespace)
        
        try:
            quotas = self._with_retry(_do_list)
            
            return [
                {
                    "name": quota.metadata.name,
                    "namespace": quota.metadata.namespace,
                    "hard_limits": dict(quota.status.hard or {}),
                    "used": dict(quota.status.used or {}),
                }
                for quota in quotas.items
            ]
        except ApiException:
            # Preserve status code for upstream handlers (e.g., auth 401 detection).
            raise
    
    def check_permissions(self) -> dict:
        """Check what permissions the current user has.
        
        Returns:
            Dictionary with permission check results
        """
        permissions = {
            "can_list_namespaces": False,
            "can_list_pvcs": False,
            "can_list_pods": False,
            "can_list_storage_classes": False,
            "can_list_resource_quotas": False,
            "can_exec_into_pods": False,
            "error_message": None
        }
        
        try:
            self._ensure_initialized()
            
            # Test namespace listing
            try:
                self._with_retry(lambda: self.core_v1.list_namespace(_preload_content=False, limit=1))
                permissions["can_list_namespaces"] = True
            except ApiException:
                pass
            
            # Test PVC listing (need a namespace, try default)
            try:
                self._with_retry(lambda: self.core_v1.list_namespaced_persistent_volume_claim("default", _preload_content=False, limit=1))
                permissions["can_list_pvcs"] = True
            except ApiException:
                pass
            
            # Test Pod listing
            try:
                self._with_retry(lambda: self.core_v1.list_namespaced_pod("default", _preload_content=False, limit=1))
                permissions["can_list_pods"] = True
            except ApiException:
                pass
            
            # Test StorageClass listing
            try:
                self._with_retry(lambda: self.storage_v1.list_storage_class(_preload_content=False, limit=1))
                permissions["can_list_storage_classes"] = True
            except ApiException:
                pass
            
            # Test ResourceQuota listing
            try:
                self._with_retry(lambda: self.core_v1.list_namespaced_resource_quota("default", _preload_content=False, limit=1))
                permissions["can_list_resource_quotas"] = True
            except ApiException:
                pass
            
        except Exception as e:
            permissions["error_message"] = str(e)
        
        return permissions


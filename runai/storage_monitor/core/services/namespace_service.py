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

"""Namespace operations service."""

from typing import List
from ..clients.k8s_client import K8sClient


class NamespaceService:
    """Service for namespace-related operations."""
    
    def __init__(self, k8s_client: K8sClient):
        """Initialize namespace service.
        
        Args:
            k8s_client: Kubernetes API client
        """
        self.k8s = k8s_client
    
    def list_runai_namespaces(self) -> List[str]:
        """List all Run.ai namespaces (prefixed with 'runai-').
        
        Returns:
            List of Run.ai namespace names
        """
        all_namespaces = self.k8s.list_namespaces()
        
        runai_namespaces = [
            ns["name"] for ns in all_namespaces
            if ns["name"].startswith("runai-")
        ]
        
        return sorted(runai_namespaces)
    
    def list_all_namespaces(self) -> List[str]:
        """List all namespaces in the cluster.
        
        Returns:
            List of all namespace names
        """
        all_namespaces = self.k8s.list_namespaces()
        return sorted([ns["name"] for ns in all_namespaces])
    
    def namespace_exists(self, namespace: str) -> bool:
        """Check if a namespace exists.
        
        Args:
            namespace: Namespace name to check
            
        Returns:
            True if namespace exists, False otherwise
        """
        all_namespaces = self.k8s.list_namespaces()
        return any(ns["name"] == namespace for ns in all_namespaces)


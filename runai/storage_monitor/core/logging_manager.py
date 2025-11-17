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

"""Centralized logging for Run.ai Storage Monitor.

Tracks all operations across tiers (Core, CLI, MCP, API, GUI)
"""

import logging
import json
from datetime import datetime
from pathlib import Path
from typing import Optional, Dict, Any, List
from collections import deque
from threading import Lock


class StructuredLogger:
    """Centralized structured logging with live viewing support."""
    
    def __init__(self, max_entries: int = 1000):
        self.max_entries = max_entries
        self.log_buffer = deque(maxlen=max_entries)
        self.lock = Lock()
        self.state_dir = Path.home() / '.runai-storage-monitor'
        self.log_file = self.state_dir / 'logs' / 'operations.jsonl'
        self.log_file.parent.mkdir(parents=True, exist_ok=True)
        
        # Setup file logger
        self.logger = logging.getLogger('runai_storage_monitor')
        handler = logging.FileHandler(self.log_file)
        handler.setFormatter(logging.Formatter('%(message)s'))
        self.logger.addHandler(handler)
        self.logger.setLevel(logging.INFO)
    
    def log_operation(
        self,
        operation: str,
        tier: str,
        details: Optional[Dict[str, Any]] = None,
        status: str = 'initiated',
        error: Optional[str] = None
    ):
        """Log an operation across any tier.
        
        Args:
            operation: Operation name (e.g., 'list_pvcs', 'analyze_namespace')
            tier: Tier name (CORE, CLI, MCP, API, GUI)
            details: Additional operation details
            status: Operation status (initiated, success, error)
            error: Error message if status is error
            
        Returns:
            Log entry dictionary
        """
        entry = {
            'timestamp': datetime.now().isoformat(),
            'operation': operation,
            'tier': tier,
            'status': status,
            'details': details or {},
            'error': error
        }
        
        with self.lock:
            self.log_buffer.append(entry)
            self.logger.info(json.dumps(entry))
        
        return entry
    
    def log_api_call(
        self,
        method: str,
        endpoint: str,
        source: str,
        params: Optional[Dict] = None,
        response_code: Optional[int] = None,
        response_data: Optional[Dict] = None,
        error: Optional[str] = None
    ):
        """Log API HTTP call.
        
        Args:
            method: HTTP method (GET, POST, etc.)
            endpoint: API endpoint path
            source: Request source (GUI, CLI, MCP)
            params: Request parameters
            response_code: HTTP response code
            response_data: Response data summary
            error: Error message if failed
            
        Returns:
            Log entry dictionary
        """
        return self.log_operation(
            operation=f"{method} {endpoint}",
            tier='API',
            details={
                'source': source,
                'params': params,
                'response_code': response_code,
                'response_data': response_data
            },
            status='success' if response_code and response_code < 400 else 'error',
            error=error
        )
    
    def log_cli_command(
        self,
        command: str,
        args: Dict,
        result: str,
        error: Optional[str] = None
    ):
        """Log CLI command execution.
        
        Args:
            command: Command name
            args: Command arguments
            result: Execution result
            error: Error message if failed
            
        Returns:
            Log entry dictionary
        """
        return self.log_operation(
            operation=command,
            tier='CLI',
            details={'args': args, 'result': result},
            status='success' if not error else 'error',
            error=error
        )
    
    def log_mcp_tool(
        self,
        tool_name: str,
        params: Dict,
        result: Any,
        error: Optional[str] = None
    ):
        """Log MCP tool invocation.
        
        Args:
            tool_name: MCP tool name
            params: Tool parameters
            result: Tool result
            error: Error message if failed
            
        Returns:
            Log entry dictionary
        """
        return self.log_operation(
            operation=tool_name,
            tier='MCP',
            details={'params': params, 'result': result},
            status='success' if not error else 'error',
            error=error
        )
    
    def log_storage_action(
        self,
        action: str,
        namespace: str,
        resource_count: int,
        success: bool,
        details: Optional[Dict] = None
    ):
        """Log storage analysis action.
        
        Args:
            action: Action name (analyze, list_pvcs, etc.)
            namespace: Target namespace
            resource_count: Number of resources processed
            success: Whether action succeeded
            details: Additional action details
            
        Returns:
            Log entry dictionary
        """
        return self.log_operation(
            operation=f"storage_{action}",
            tier='CORE',
            details={
                'namespace': namespace,
                'resource_count': resource_count,
                'action_details': details or {}
            },
            status='success' if success else 'error'
        )
    
    def get_recent_logs(self, count: int = 100, tier: Optional[str] = None) -> List[Dict]:
        """Get recent log entries.
        
        Args:
            count: Number of recent entries to return
            tier: Filter by tier (optional)
            
        Returns:
            List of log entry dictionaries
        """
        with self.lock:
            entries = list(self.log_buffer)
        
        if tier:
            entries = [e for e in entries if e['tier'] == tier]
        
        return entries[-count:]
    
    def get_logs_since(self, since: datetime) -> List[Dict]:
        """Get logs since timestamp.
        
        Args:
            since: Datetime to filter from
            
        Returns:
            List of log entries after timestamp
        """
        with self.lock:
            entries = list(self.log_buffer)
        
        return [
            e for e in entries
            if datetime.fromisoformat(e['timestamp']) > since
        ]
    
    def clear_logs(self):
        """Clear in-memory log buffer."""
        with self.lock:
            self.log_buffer.clear()


# Global logger instance
_logger_instance = None


def get_logger() -> StructuredLogger:
    """Get global logger instance."""
    global _logger_instance
    if _logger_instance is None:
        _logger_instance = StructuredLogger()
    return _logger_instance


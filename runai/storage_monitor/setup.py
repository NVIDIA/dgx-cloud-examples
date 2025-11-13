#!/usr/bin/env python3
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

"""Setup script for Run.ai Storage Monitor."""

from setuptools import setup, find_packages
from pathlib import Path

# Read requirements
requirements_file = Path(__file__).parent / 'requirements.txt'
with open(requirements_file) as f:
    requirements = [line.strip() for line in f if line.strip() and not line.startswith('#')]

# Read README for long description
readme_file = Path(__file__).parent / 'README.md'
with open(readme_file, encoding='utf-8') as f:
    long_description = f.read()

setup(
    name="runai-storage-monitor",
    version="1.0.0",
    description="Kubernetes storage visibility tool for Run.ai environments",
    long_description=long_description,
    long_description_content_type="text/markdown",
    author="NVIDIA Corporation",
    author_email="jjenkinsiv@nvidia.com",
    url="https://github.com/NVIDIA/dgx-cloud-examples",
    # Explicit package list since setup.py is inside the package directory
    packages=[
        'runai_storage_monitor',
        'runai_storage_monitor.api',
        'runai_storage_monitor.core',
        'runai_storage_monitor.core.clients',
        'runai_storage_monitor.core.services',
        'runai_storage_monitor.core.analyzers',
        'runai_storage_monitor.core.models',
        'runai_storage_monitor.ui',
    ],
    # Map package to current directory
    package_dir={'runai_storage_monitor': '.'},
    install_requires=requirements,
    entry_points={
        'console_scripts': [
            'runai-storage-monitor=runai_storage_monitor.cli:cli',
            'runai-storage-server=runai_storage_monitor.api.server:run_server',
        ],
    },
    python_requires='>=3.8',
    include_package_data=True,
    package_data={
        'runai_storage_monitor': [
            'ui/*.html',
            'ui/css/*.css',
            'ui/js/*.js',
            'ui/vendor/*.js',
            'ui/img/*.jpg',
            'ui/img/*.svg',
            'ui/img/*.ico',
        ],
    },
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: System Administrators",
        "License :: OSI Approved :: Apache Software License",
        "Operating System :: OS Independent",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "Programming Language :: Python :: 3.13",
        "Topic :: System :: Monitoring",
    ],
    zip_safe=False,
)


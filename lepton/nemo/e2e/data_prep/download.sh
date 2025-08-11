#!/bin/bash
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

# Specify the directory to save data to
directory=$1

# Install cc-downloader to download Nemotron-CC pages
wget https://github.com/commoncrawl/cc-downloader/releases/download/v0.6.1/cc-downloader-v0.6.1-x86_64-unknown-linux-gnu.tar.gz
tar -xvf cc-downloader-v0.6.1-x86_64-unknown-linux-gnu.tar.gz
chmod +x cc-downloader

# Download the Nemotron-CC pages and eliminate low and medium-low quality data
wget https://data.commoncrawl.org/contrib/Nemotron/Nemotron-CC/data-jsonl.paths.gz
gunzip data-jsonl.paths.gz
sed -i '/quality=low/d' data-jsonl.paths
sed -i '/quality=medium-low/d' data-jsonl.paths
gzip data-jsonl.paths

# Download the compressed files from Nemotron-CC using cc-downloader
./cc-downloader download --threads 128 --progress data-jsonl.paths.gz $directory


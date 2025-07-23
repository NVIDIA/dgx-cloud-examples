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

import os
import requests
import time

CHUNKS = 10
SHARDS = 6000

def download_shard(url, filename, retry=False):
    if os.path.exists(filename):
        return

    response = requests.get(url)

    # In case of getting rate-limited, wait 3 seconds and retry the
    # download once.
    if response.status_code == 429 and not retry:
        time.sleep(3)
        download_shard(url, filename, retry=True)

    if response.status_code != 200:
        return

    with open(filename, 'wb') as fn:
        fn.write(response.content)

def split_shards(wsize):
    shards = []
    shards_to_download = list(range(SHARDS))

    for shard in range(wsize):
        idx_start = (shard * SHARDS) // wsize
        idx_end = ((shard + 1) * SHARDS) // wsize
        shards.append(shards_to_download[idx_start:idx_end])
    return shards

def download(directory=""):
    wrank = int(os.environ.get('RANK', 0))
    wsize = int(os.environ.get('WORLD_SIZE', 0))

    if wrank == 0:
        os.makedirs(directory, exist_ok=True)

    for chunk in range(1, CHUNKS + 1):
        shards_to_download = split_shards(wsize)

        for shard in shards_to_download[wrank]:
            filename = f'example_train_chunk{chunk}_shard{shard}.jsonl.zst'
            filename = os.path.join(directory, filename)
            url = f'https://huggingface.co/datasets/cerebras/SlimPajama-627B/resolve/main/train/chunk{chunk}/example_train_{shard}.jsonl.zst'
            download_shard(url, filename)

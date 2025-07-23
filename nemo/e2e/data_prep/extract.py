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
from glob import glob
import zstandard as zstd


def split_shards(wsize, dataset):
    shards = []

    for shard in range(wsize):
        idx_start = (shard * len(dataset)) // wsize
        idx_end = ((shard + 1) * len(dataset)) // wsize
        shards.append(dataset[idx_start:idx_end])
    return shards

def extract_shard(shard):
    extracted_filename = shard.replace(".zst", "")

    # Very rare scenario where another rank has already processed a shard
    if not os.path.exists(shard):
        return

    with open(shard, "rb") as in_file, open(extracted_filename, "wb") as out_file:
        dctx = zstd.ZstdDecompressor(max_window_size=2**27)
        reader = dctx.stream_reader(in_file)

        while True:
            chunk = reader.read(4096)
            if not chunk:
                break
            out_file.write(chunk)

    os.remove(shard)

def extract(directory=""):
    wrank = int(os.environ.get("RANK", 0))
    wsize = int(os.environ.get("WORLD_SIZE", 0))

    dataset = sorted(glob(os.path.join(directory, "example_train*zst")))
    shards_to_extract = split_shards(wsize, dataset)

    for shard in shards_to_extract[wrank]:
        extract_shard(shard)

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
import subprocess
from glob import glob

from huggingface_hub import hf_hub_download


def split_shards(wsize, dataset):
    shards = []

    for shard in range(wsize):
        idx_start = (shard * len(dataset)) // wsize
        idx_end = ((shard + 1) * len(dataset)) // wsize
        shards.append(dataset[idx_start:idx_end])
    return shards

def preprocess(directory=""):
    wrank = int(os.environ.get("RANK", 0))
    wsize = int(os.environ.get("WORLD_SIZE", 1))

    dataset = sorted(glob(os.path.join(directory, "slim_pajama*jsonl")))
    shards_to_extract = split_shards(wsize, dataset)

    if wrank == 0:
        # Download a specific file from a repository
        hf_hub_download(
            repo_id="meta-llama/Meta-Llama-3.1-8B",
            filename="original/tokenizer.model",
            local_dir="/nemo-workspace/tokenizers/llama-3.1-8b"
        )

    for num, shard in enumerate(shards_to_extract[wrank]):
        shard_num = wrank + (num * wsize)  # Counter for which file is processed
        output_path = os.path.join(directory, f"llama-slim-pajama-{shard_num}")
        command = (
            "python3 /opt/NeMo/scripts/nlp_language_modeling/preprocess_data_for_megatron.py "
            f"--input {shard} "
            f"--output-prefix {output_path} "
            f"--dataset-impl mmap "
            f"--tokenizer-type meta-llama/Meta-Llama-3.1-8B "
            f"--tokenizer-library huggingface "
            f"--tokenizer-model /nemo-workspace/tokenizers/llama-3.1-8b/original/tokenizer.model "
            f"--workers 80"
        )
        subprocess.run([command], shell=True)

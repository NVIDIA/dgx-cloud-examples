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

def prepare(directory=""):
    world_size = int(os.getenv('WORLD_SIZE', 1))
    rank = int(os.getenv('NODE_RANK', 0))

    # List and sort input files
    files = sorted(glob(os.path.join(directory, "nemotron-cc*jsonl")))

    # Process files assigned to this rank
    for i, file in enumerate(files):
        if i % world_size != rank:
            continue
        shard_num = i
        output_path = os.path.join(directory, f"nemotron-cc-{shard_num}")

        # Construct command (using subprocess with proper arguments)
        command = [
            "python3",
            "/opt/NeMo/scripts/nlp_language_modeling/preprocess_data_for_megatron.py",
            "--input",
            file,
            "--output-prefix",
            output_path,
            "--dataset-impl",
            "mmap",
            "--tokenizer-type",
            "nvidia/Nemotron-H-8B-Base-8K",
            "--tokenizer-library",
            "huggingface",
            "--workers",
            "240"
        ]

        # Execute the command
        print(f"Process {rank} is processing file {file}")
        try:
            subprocess.run(command, check=True)
        except:
            print(f"Error on file {file}")

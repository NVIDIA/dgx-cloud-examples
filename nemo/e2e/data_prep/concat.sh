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

directory=$1
shards_per_file=50

readarray -t files < <(find "${directory}" -name 'CC-MAIN*.jsonl' | xargs -0)
num_files=${#files[@]}
rank=$NODE_RANK
world_size=$WORLD_SIZE

# Calculate total chunks needed
shards=$(( (num_files + shards_per_file - 1) / shards_per_file ))

echo "Creating ${shards} combined chunk(s) comprising ${shards_per_file} files each"

for ((i=0; i<$shards; i++)); do
  if (( (i - rank) % world_size != 0 )); then
    continue
  fi

  # Calculate start/end indices for this chunk
  start=$((i * shards_per_file))
  if [[ $(((i+1)*shards_per_file)) -ge num_files ]]; then
    end=$((${#files[@]}-1))
  else
    end=$(((i+1)*shards_per_file))
  fi

  echo "Building chunk $i with files ${files[@]:start:$((end-start))}"

  # Concatenate files safely and remove them afterward
  for file in "${files[@]:start:$((end-start))}"; do
    cat "$file" >> "${directory}/nemotron-cc_${i}.jsonl"
    rm "$file"  # Remove immediately after processing
  done
done

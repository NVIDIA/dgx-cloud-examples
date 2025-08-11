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

from nemo.collections import llm


def last_checkpoint(directory=""):
    checkpoints = []

    for root, dirs, _ in os.walk(directory):
        for dir in dirs:
            if dir.endswith("-last"):
                checkpoints.append(os.path.join(root, dir))
    # Return the most recent checkpoint found
    return max(checkpoints, key=os.path.getmtime)

def convert_checkpoint(dir=""):
    checkpoint = last_checkpoint(dir)

    llm.export_ckpt(
        path=checkpoint,
        target="hf",
        overwrite=True,
        output_path=f"{dir}/huggingface"
    )

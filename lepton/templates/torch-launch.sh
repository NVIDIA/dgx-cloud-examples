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

# start non-template code for running a NCCL test across nodes
# assumes NGC nvcr.io/nvidia/pytorch:25.08-py3 or later

WORKDIR=/workspace/ddp
mkdir -p $WORKDIR && cd $WORKDIR

# retrieve the benchmark from this repo
wget https://raw.githubusercontent.com/NVIDIA/dgx-cloud-examples/refs/heads/main/lepton/templates/pytorch-benchmark.py

# latest of these work currently
# but may need to pin if there 
# are incompatabilities
pip install accelerate \
            deepspeed \
            mpi4py \
            pydantic \
            transformers

# optionally enable debugging
#export LOGLEVEL="DEBUG"
#export NCCL_DEBUG=INFO

torchrun \
    --nnodes=$PET_NNODES:$PET_NNODES\
    --nproc_per_node=$PET_NPROC_PER_NODE\
    --master_addr="$PET_MASTER_ADDR" \
    pytorch-benchmark.py

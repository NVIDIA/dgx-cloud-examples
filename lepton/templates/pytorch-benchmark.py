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

import argparse
import deepspeed
import os
import torch
import torch.distributed as dist
import time
import warnings

# ignore all FutureWarnings
warnings.simplefilter(action='ignore', category=FutureWarning)

# assume a full 8 gpu node
gpu_count = 8

def do_allreduce(mat):
    torch.cuda.synchronize()
    pre = time.perf_counter()
    dist.all_reduce(mat)
    
    torch.cuda.synchronize()
    duration = time.perf_counter() - pre
    tput = ((dim_x*dim_y*4*2)/duration) * gpu_count
    
    size = dim_x * dim_y * 4
    n = dist.get_world_size()
    busbw = (size / duration) * (2 * (n - 1) / n) * gpu_count
    
    return tput, busbw

def do_run(local_rank):
    global_rank = dist.get_rank()
    if global_rank == 0:
        print("Global rank", global_rank, "passing", dim_x*dim_y*4/1e9, "GB of data")
    mat = torch.rand(dim_y, dim_x, dtype=torch.float32).cuda(local_rank)

    tputs = []
    busbws = []
    for trial in range(trials):
        tput, busbw = do_allreduce(mat)
        if trial > 2:
            tputs.append(tput)
            busbws.append(busbw)

    local_avg = sum(tputs) / len(tputs)
    local_avg_bb = sum(busbws) / len(busbws)
    t = torch.tensor([local_avg/1e9, local_avg_bb/1e9], device='cuda')
    dist.all_reduce(t)
    tput_avg = t[0] / dist.get_world_size()
    busbw_avg = t[1] / dist.get_world_size()
    if dist.get_rank() == 0:
        print('Throughput average:', f'{tput_avg.item():.2f}', 'Gbps')
        print('Bus bandwidth average:', f'{busbw_avg.item():.2f}','Gbps')
    dist.barrier()
    dist.destroy_process_group()

def init_ranks(local_rank, fn, backend='nccl'):
    deepspeed.init_distributed(dist_backend=backend)
    local_rank = int(os.environ['LOCAL_RANK'])
    gpu_count = int(os.environ['PET_NPROC_PER_NODE'])
    torch.cuda.set_device(local_rank)
    fn(local_rank)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--local_rank", type=int)
    parser.add_argument("--trials", type=int, default=5)
    parser.add_argument("--dim_x", type=int, default=3000)
    parser.add_argument("--dim_y", type=int, default=500000)
    args = parser.parse_args()
    rank = args.local_rank
    trials = args.trials
    dim_x = args.dim_x
    dim_y = args.dim_y
    init_ranks(local_rank=rank, fn=do_run)

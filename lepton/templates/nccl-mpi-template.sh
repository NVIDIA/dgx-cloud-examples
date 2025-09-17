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
# assumes NGC nvcr.io/nvidia/nemo:25.07 or later which pre-builds
# the tests at https://github.com/NVIDIA/nccl-tests

# function from boilerplate code
barrier "prepare-finished"

# Rank0 is the head node, and other workers will wait for it to complete
COMPLETE_FILE="/tmp/lepton-mpi-complete"
if [[ $LEPTON_JOB_WORKER_INDEX -eq 0 ]]; then
    # Rank0 starts mpirun using NNODES*NGPUS devices
    mpirun --allow-run-as-root -verbose --map-by ppr:$NGPUS:node --hostfile $HOSTFILE \
           all_reduce_perf_mpi -b 1G -e 16G -f 2 -g 1

    mpi_ret_code=$?

    # Rank0 notifies other workers the job is done using a single process
    mpirun --map-by ppr:1:node -hostfile $HOSTFILE --allow-run-as-root touch ${COMPLETE_FILE}

    if [ $mpi_ret_code -ne 0 ]; then
        echo "MPI job failed with exit code $mpi_ret_code"
        exit $mpi_ret_code
    else
        echo "MPI job completed!"
    fi
else
    # Other workers wait for rank0 to complete
    while true; do
        [ ! -f "${COMPLETE_FILE}" ] || break
        sleep 5
    done
    exit 0
fi


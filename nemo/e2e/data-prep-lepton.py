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

import nemo_run as run

from data_prep.extract import extract
from data_prep.preprocess import prepare

def lepton_executor(nodes: int = 1, devices: int = 1) -> run.LeptonExecutor:
    mounts = [
        {
            "path": "/nemo-workspace",  # Directory to mount from the remote filesystem
            "mount_path": "/nemo-workspace",  # Where to mount the directory in pods
            "from": "local:nfs"  # (Optional) Which remote storage resource to mount
        }
    ]

    return run.LeptonExecutor(
        resource_shape=f"gpu.{devices}xh100-80gb",  # Replace with the resource shape for the node group
        container_image="nvcr.io/nvidia/nemo:25.04",  # Which container to deploy
        nemo_run_dir="/nemo-workspace/nemo-run",  # Specify the NeMo-Run directory to copy experiments to in the remote filesystem
        mounts=mounts,  # Which directories to mount from the remote filesystem
        node_group="xxxxx",  # Replace with the name of the node group available in the cluster
        nodes=nodes,  # Number of nodes to run on
        nprocs_per_node=devices,  # Number of processes per node to use
        env_vars={
            "HF_TOKEN": "xxxxxxxxxxxxxxxxxx",  # Add your Hugging Face API token here
            "TORCH_HOME": "/nemo-workspace/.cache"  # Save downloaded models and tokenizers to the remote storage cache
        },
        launcher="torchrun",  # Use torchrun to launch the processes
        packager=run.PatternPackager(  # Copy the data prep scripts to the filesystem for execution
            include_pattern="data_prep/*",
            relative_path=""
        )
    )

def prepare_nemotron_cc():
    # Create a NeMo-Run experiment which runs all sub-steps sequentially
    with run.Experiment("nemotron-cc-data-prep") as exp:
        # Data download only needs a single device
        executor = lepton_executor(nodes=1, devices=1)
        exp.add(run.Script("/nemo_run/code/data_prep/download.sh", args=["/nemo-workspace/data"]), name="download", executor=executor)
        # Extract, concat, and preprocess benefit from multiple nodes
        executor = lepton_executor(nodes=8, devices=1)
        exp.add(run.Partial(extract, "/nemo-workspace/data"), name="extract", executor=executor)
        exp.add(run.Script("/nemo_run/code/data_prep/concat.sh", args=["/nemo-workspace/data"]), name="concat", executor=executor)
        # Preprocessing requires more system memory to prepare the large files
        executor = lepton_executor(nodes=4, devices=8)
        exp.add(run.Partial(prepare, "/nemo-workspace/data"), name="preprocess", executor=executor)

        # Launch the experiment on the cluster
        exp.run(sequential=True)

if __name__ == "__main__":
    prepare_nemotron_cc()

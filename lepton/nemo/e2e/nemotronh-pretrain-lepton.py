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
import nemo_run as run

from nemo.collections import llm
from nemo.collections.common.tokenizers import AutoTokenizer
from nemo.collections.llm.gpt.data.pre_training import PreTrainingDataModule
from nemo.collections.llm.recipes.log.default import default_log, wandb_logger
from nemo.collections.llm.recipes.optim.adam import distributed_fused_adam_with_cosine_annealing

from scripts.convert import convert_checkpoint


def configure_recipe(
        nodes: int = 1,
        gpus_per_node: int = 2,
        dir: str = "/nemo-workspace/nemotronh_8b",
        name: str = "nemotronh_8b"
    ):
    paths = [os.path.join("/nemo-workspace/data/", f"nemotron-cc-{num}_text_document") for num in range(465)]
    tokenizer = run.Config(AutoTokenizer, pretrained_model_name="nvidia/Nemotron-H-8B-Base-8K")

    data=run.Config(
        PreTrainingDataModule,
        paths=paths,
        seq_length=8192,
        global_batch_size=768,
        micro_batch_size=1,
        tokenizer=tokenizer
    )

    wandb = wandb_logger(
        project="nemotronh",
        name="nemotronh-8b"
    )

    recipe = run.Partial(
        llm.pretrain,
        model=llm.nemotronh_8b.model(),
        trainer=llm.nemotronh_8b.trainer(
            dir=dir, # Path to store checkpoints
            num_nodes=nodes,
            num_gpus_per_node=gpus_per_node,
            val_check_interval=2000,
            limit_test_batches=10,
            limit_val_batches=10,
            ckpt_async_save=True,
            max_steps=160000,
        ),
        data=data,
        optim=distributed_fused_adam_with_cosine_annealing(max_lr=8e-4),
        log=default_log(dir=dir, name=name, wandb_logger=wandb),
    )

    return recipe

def lepton_executor(nodes: int = 1, devices: int = 1) -> run.LeptonExecutor:
    mounts = [
        {
            "path": "/nemo-workspace",  # Directory to mount from the remote filesystem
            "mount_path": "/nemo-workspace",  # Where to mount the directory in pods
            "from": "local:nfs"  # (Optional) Which remote storage resource to mount
        }
    ]

    return run.LeptonExecutor(
        resource_shape="gpu.8xh100-80gb",  # Replace with the resource shape for the node group
        container_image="nvcr.io/nvidia/nemo:25.04",  # Which container to deploy
        nemo_run_dir="/nemo-workspace/nemo-run",  # Specify the NeMo-Run directory to copy experiments to in the remote filesystem
        mounts=mounts,  # Which directories to mount from the remote filesystem
        node_group="xxxxx",  # Replace with the name of the node group available in the cluster
        nodes=nodes,  # Number of nodes to run on
        nprocs_per_node=devices,  # Number of processes per node to use
        env_vars={
            "PYTHONPATH": "/nemo-workspace/nemo-run:$PYTHONPATH",  # Add the NeMo-Run directory to the PYTHONPATH
            "TORCH_HOME": "/nemo-workspace/.cache",  # Save downloaded models and tokenizers to the remote storage cache
            "HF_TOKEN": "xxxxxxxxxxxxxxxxxx",  # Add your Hugging Face API token here
            "WANDB_API_KEY": "xxxxxxxxxxxxxxxxxx"  # Add your Weights & Biases API token here
        },
        launcher="torchrun",  # Use torchrun to launch the processes
        packager=run.PatternPackager(  # Copy the data prep scripts to the filesystem for execution
            include_pattern=["data_prep/*", "scripts/*"],
            relative_path=["", ""]
        )
    )

def run_pretraining():
    recipe = configure_recipe(nodes=8, gpus_per_node=8)
    executor = lepton_executor(nodes=recipe.trainer.num_nodes, devices=recipe.trainer.devices)

    run.run(recipe, executor=executor)

    executor = lepton_executor(nodes=1, devices=1)
    run.run(run.Partial(convert_checkpoint, "/nemo-workspace/nemotronh_8b"), name="convert-model", executor=executor)


if __name__ == "__main__":
    run_pretraining()

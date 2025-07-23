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
from nemo.collections.common.tokenizers.huggingface.auto_tokenizer import AutoTokenizer
from nemo.collections.llm.gpt.data.pre_training import PreTrainingDataModule
from nemo.collections.llm.recipes.log.default import default_log, wandb_logger
from nemo.collections.llm.recipes.optim.adam import distributed_fused_adam_with_cosine_annealing
from nemo.utils.exp_manager import TimingCallback
from scripts.convert import convert_checkpoint


def configure_recipe(nodes: int = 1, gpus_per_node: int = 2, dir=None, name="nemo"):
    paths = [os.path.join(data_dir, f"llama-slim-pajama-{num}_text_document") for num in range(30)]
    tokenizer = run.Config(AutoTokenizer, pretrained_model_name="meta-llama/Llama-3.1-8B")

    data=run.Config(
        PreTrainingDataModule,
        paths=paths,
        seq_length=8192,  # Use a sequence length or context window of 8K tokens
        global_batch_size=512,  # Batch size of 512
        micro_batch_size=1,
        tokenizer=tokenizer
    )

    wandb = wandb_logger(
        project="llama-3.1",  # Specify the Weights & Biases project name
        name="llama-3.1-8b"  # Specify the name of the training run to be displayed on Weights & Biases
    )

    recipe = run.Partial(
        llm.pretrain,  # Specify that we want to use the Pre-train method
        model=llm.llama31_8b.model(),  # Use the existing Llama 3.1-8B model config default settings
        trainer=llm.llama31_8b.trainer(
            num_nodes=nodes,
            num_gpus_per_node=gpus_per_node,
            max_steps=150000,  # Train for 150,000 steps - equal to 150,000 * batch size (512) * sequence length (8192) = 629B tokens
            callbacks=[run.Config(TimingCallback)],
        ),
        data=data,
        optim=distributed_fused_adam_with_cosine_annealing(max_lr=3e-4),
        log=default_log(dir=dir, name=name, wandb_logger=wandb),
    )

    recipe.trainer.val_check_interval = 2000  # Run evaluation and save a checkpoint every 2,000 steps
    recipe.trainer.strategy.tensor_model_parallel_size = 4  # Set the Tensor Parallelism size to 4
    return recipe

def lepton_executor(nodes: int = 1, devices: int = 1) -> run.LeptonExecutor:
    mounts = [
        {
            "path": "/nemo-workspace",  # Directory to mount from the remote filesystem
            "mount_path": "/nemo-workspace"  # Where to mount the directory in pods
            "from": "local:nfs"  # (Optional) Which remote storage resource to mount
        }
    ]

    return run.LeptonExecutor(
        resource_shape="gpu.8xh100-80gb",  # Replace with the resource shape for the node group
        container_image="nvcr.io/nvidia/nemo:25.02",  # Which container to deploy
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
    recipe = configure_recipe(nodes=8, gpus_per_node=8, dir="/nemo-workspace/llama-3.1-8b", name="llama-3.1-8b")
    executor = lepton_executor(nodes=recipe.trainer.num_nodes, devices=recipe.trainer.devices)

    run.run(recipe, executor=executor)

    # Re-initialize the executor as only a single GPU is needed for conversion
    executor = lepton_executor(nodes=1, devices=1)
    export_ckpt = convert_checkpoint(dir="/nemo-workspace/llama-3.1-8b")

    run.run(run.Partial(convert_checkpoint, "/nemo-workspace/llama-3.1-8b"), name="convert-model", executor=executor)

if __name__ == "__main__":
    run_pretraining()


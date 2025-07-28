# NeMo Framework End-to-End Examples
This directory contains the code for running the [NeMo Framework End-to-End Workflow on DGX Cloud Lepton](https://docs.nvidia.com/dgx-cloud/lepton/examples/batch-job/nemo-fw-e2e-guide/) tutorial. This tutorial walks through pre-training a Nemotron-H-based hybrid SSM model using NeMo Framework. There are currently two main stages in this example - preparing a custom dataset and launching pre-training. This document provides a brief overview of the workflow. For a more thorough explanation of the steps, refer to the guide linked above.

## Setup
This tutorial uses [NeMo-Run](https://github.com/nvidia-nemo/run) which allows the scripts to be run from a local workstation which will launch the data preparation and pre-training jobs remotely on your DGX Cloud Lepton cluster. Prior to running, some minimal setup is required. This can be run on a local workstation and an IDE such as Visual Studio Code is recommended.

Install the required dependencies with the following command. You are welcome to use a different virtual environment, such as Conda, as desired:

```bash
git clone https://github.com/nvidia/dgx-cloud-examples
cd dgx-cloud-examples/nemo/e2e
python3 -m venv env
source env/bin/activate
pip3 install nemo_toolkit[nlp] git+https://github.com/NVIDIA/nemo-run
```

Authenticate with your DGX Cloud Lepton workspace by creating a new access token in the UI in the **Settings > Tokens** page. Copy the command shown in the window and paste it in the terminal. It should look something like the following:

```bash
lep login -c xxxxxx:************************
```

Your local environment should now be authenticated with DGX Cloud Lepton and you can launch jobs remotely on your workspace.

## Prepare the dataset
This tutorial uses the Nemotron-CC dataset for pre-training which includes a large corpus of curated text from several domains and was used by NVIDIA to train several publicly-released models. Several helper scripts have been provided to prepare the dataset and can be found in the [data_prep](data_prep/) directory. The [download](data_prep/download.sh) script filters the Nemotron-CC dataset for only medium, medium-high, and high-quality subsets and downloads the shards using the Common Crawl dataset downloader tool. Then the [extract](data_prep/extract.py) script extracts all of the compressed files. The [concat](data_prep/concat.sh) script combines the shards to create fewer, larger files for efficiency. Lastly, the [preprocess](data_prep/preprocess.py) script tokenizes the concatenated files to make them ready for pre-training.

Data preparation is initiated by running the `data-prep-lepton.py` script. Prior to running, open the `data-prep-lepton.py` script locally using a text editor or IDE as some settings need to be changed for your environment. Look for the following lines in the script and modify them for your environment:

* `resource_shape=f"gpu.{devices}xh100-80gb"`: Replace `gpu.{devices}xh100-80gb` with the desired resource shape. This is the GPU type and configuration to use for the job, such as `gpu.8xh100-80gb` might refer to a pod with 8x H100 GPUs available in it.
* `node_group="xxxxx"`: Replace `xxxxx` with the node group to run in. The list of available node groups can be found in the Nodes tab in the UI.
* `"HF_TOKEN": "xxxxxxxxxxxxxxxxxx"`: Add your Hugging Face authentication token between the quotation marks.
* `executor = lepton_executor(nodes=8, devices=1)`: The example runs on eight pods with one process per node. If more nodes/processes are desired, specify the amount here.
* `"from": "local:nfs"`: If using remote shared storage, enter the name of the storage to mount in all jobs. This can be found in the UI while creating a job and selecting a storage option.

Once the script has been modified, launch data prep with:

```bash
chmod +x data_prep/*.sh
python3 data-prep-lepton.py
```

The command will copy the data prep scripts to the remote filesystem and run the four stages sequentially. The jobs will show up in the **Batch Jobs** page in your DGX Cloud Lepton UI once in the queue. Depending on the number of resources used, the data preparation process could take a couple of days to complete. By default, the data will be saved in the `/nemo-workspace/data` directory in the shared storage in the selected node group.

## Pre-train the model
After data preparation is complete, the model can be pre-trained. The [nemotronh-pretrain-lepton.py](nemotronh-pretrain-lepton.py) script pre-trains a new model from scratch following the Nemotron-H 8B architecture using the preprocessed Nemotron-CC dataset. Like with the data prep script, some settings will need to be changed for your environment. These are as follows:

* `resource_shape="gpu.8xh100-80gb"`: Replace `gpu.8xh100-80gb` with the desired resource shape. This is the GPU type and configuration to use for the job, such as `gpu.8xh100-80gb` might refer to a pod with 8x H100 GPUs available in it. It is highly recommended to use 8 GPUs per worker for training jobs for efficiency.
* `node_group="xxxxx"`: Replace `xxxxx` with the node group to run in. The list of available node groups can be found in the Nodes tab in the UI.
* `"HF_TOKEN": "xxxxxxxxxxxxxxxxxx"`: Add your Hugging Face authentication token between the quotation marks.
* `"WANDB_API_KEY": "xxxxxxxxxxxxxxxxxx"`: Add your Weights & Biases authentication token between the quotation marks.
* `"from": "local:nfs"`: If using remote shared storage, enter the name of the storage to mount in all jobs. This can be found in the UI while creating a job and selecting a storage option.
* `recipe = configure_recipe(nodes=8, gpus_per_node=8)`: Pre-training is a very compute intensive task and it is recommended to use as many resources as possible. If resources are available, increase the number of nodes to speed up training. Powers-of-2 are recommended for node counts.

The script is set to run pre-training for one trillion tokens. This can be configured by changing the `max_steps` value in the script. The number of tokens trained is a function of the sequence length, global batch size (GBS), and number of steps. For example, the script has a sequence length of 8192 tokens, GBS of 768, and 160,000 steps, giving 8192 * 768 * 160000 = 1 trillion tokens. Training for more tokens will increase the total training time, but should yield better accuracy in downstream tasks.

Once the script has been modified, launch pre-training with:

```bash
python3 nemotronh-pretrain-lepton.py
```

The script will launch pre-training on the selected node group in your DGX Cloud Lepton workspace once resources are available. This pushes training metrics to [Weights & Biases](https://wandb.ai) for easy monitoring of the training process.

## Next steps
Refer to the [official guide](https://docs.nvidia.com/dgx-cloud/lepton/examples/batch-job/nemo-fw-e2e-guide/) for this workflow for further explanation and additional steps, such as deploying the model for inference.

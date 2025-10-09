# Contributing to DGX Cloud Lepton Starter Kits

Thank you for your interest in contributing to DGX Cloud Lepton Starter Kits! Starter Kits are self-contained Jupyter notebooks that showcase interesting AI/ML workflows and run directly on DGX Cloud Lepton Dev Pods. We welcome new submissions of notebooks that will be showcased on the platform as part of the Starter Kits feature. This guide explains the design philosophy, requirements, and the submission workflow for new Starter Kits.

## Checklist

This section provides a checklist of requirements for submitting a new Starter Kit notebook to get started quickly. While this list aims at a quick summary of the requirements, we recommend reading this full guide to understand best practices and design philosophy of Starter Kit notebooks.

- [ ] I added a new notebook that covers an exciting use case in the AI space that I think developers would be interested in.
- [ ] My notebook is in the `lepton/starterkits` directory.
- [ ] I have fully tested this notebook and verified functionality.
- [ ] Each cell runs without errors and without user modification except for entering credentials.
- [ ] All additional packages and tools are directly installed via the notebook cells.
- [ ] If any external resources are required to be configured, the process is automated and documented for the user.
- [ ] Each cell contains a brief text explanation of what is happening.
- [ ] I cleared the output of each cell in my notebook.
- [ ] The notebook runs on a single node with one to eight NVIDIA GPUs.
- [ ] If datasets, models, or other files are required, the notebook will download them directly.
- [ ] Added `title`, `description` and `container_image` tags to the `metadata` field in the notebook's `.ipynb` file (see below for example).
- [ ] Open a new PR and add the [`starter-kits`](https://github.com/NVIDIA/dgx-cloud-examples/issues?q=state%3Aopen%20label%3Astarter-kits) label.

## Design Philosophy

Starter Kits aim to spark developer interest and inspire creativity. Users should be able to generate something of value and learn along the way. At a high level, Starter Kit notebooks should:

* Be self-contained: Do not require any manual setup outside the notebook unless strictly required.
* Run on a single node: Notebooks should use one to eight NVIDIA GPUs on a single node.
* Work out-of-the-box: All cells should execute without errors or modification (except for entering credentials).
* Showcase an interesting AI/ML application: The notebook should show something interesting, like a new fine-tuning technique, a common workflow, or other valuable use cases.
* Explain the "why": Provide a high-level description of what is happening in each cell.
* Suggest modifications: When appropriate, teach users how to change the example to meet their needs, such as using a different dataset, model, or settings. In the case of larger-scale applications, give pointers on how a user might run the workflow with more nodes.

## Notebook Requirements

This section lists all of the requirements for individual notebooks.

### Formatting

Notebooks should have a H1-level heading for the titles in the first cell (that is, Title starts with `# A Title About the Correct Use of Titles`). Logical sections within the notebook should be divided with H3-level headings (that is, `### Training Configuration`). If additional subdivisions are required, add H4 or lower level headings. All headings should be in Title Case.

### Requirements Section

Notebooks need a requirements section towards the top to indicate what is required for running the notebook. The following is a template for common requirements. Please add and complete this template in your notebook.

```
### Requirements:
* Container: # Specify the container this was tested on or the minimum required container version including the tag, such as `nvcr.io/nvidia/pytorch:25.08-py3`.
* GPUs: # Enter the number of GPUs and the minimum GPU memory required to run the notebook. If a minimum GPU architecture (ie. H100 or newer) is required, add it here.
* Storage: # Enter the storage requirements for the job. If shared storage on DGX Cloud Lepton is required, link to the [Storage Guide](https://docs.nvidia.com/dgx-cloud/lepton/features/storage/#use-storage-for-workloads).
* Shared Memory: # If you need a specific amount of shared memory (SHM), add that here.
* External Accounts: # If external accounts or API keys are required, specify them here.
```

### Directory Structure

New notebooks should be added to the `lepton/starterkits` directory. For example, if your new notebook is named `my-starter-kit.ipynb`, save it as `lepton/starterkits/my-starter-kit.ipynb`.

### Notebook Metadata

Each notebook needs additional metadata fields for DGX Cloud Lepton to properly display it in the featured notebook list. An `ipynb` file is in JSON format and includes a top-level `metadata` tag at the bottom of the file. The following fields must be added to this `metadata` tag:

* `title`: Name of the notebook to be displayed on the DGX Cloud Lepton UI.
* `description`: One or two sentence description of the notebook to be shown in the UI.
* `container_image`: The image name and tag to run the notebook in (ie. `nvcr.io/nvidia/pytorch:25.07-py3`).

The fields must follow the exact name and all-lowercase format as shown above. The following is an example:

```json
{
    "cells": [
        ...
    ],
    "metadata": {
        "title": "My Custom Starter Kit",
        "description": "An example Starter Kit running on DGX Cloud Lepton.",
        "container_image": "nvcr.io/nvidia/pytorch:25.07-py3",
        ...
    },
    ...
}
```

[!NOTE]
Each cell has its own `metadata` field. Only the top-level `metadata` field should contain these three items. This is typically at the very end of the file.

#### Adding Notebook Metadata

To update the metadata, open the `*.ipynb` file in a text editor, such as Vim. This will display the raw JSON fields. Navigate to the end of the file and add the three fields to the `metadata` tag as shown above.

### Self-Contained

Each notebook should be completely self-contained without requiring additional steps from the user outside of the platform unless strictly necessary. Follow these guidelines to keep the notebook self-contained:

* Install any additional required packages as part of the notebook. For example, if extra Python packages are required, they should be installed in one of the cells.
* If datasets, models, or other files are required for running, they should be downloaded in one of the cells.
* If user credentials or input is required, such as API keys, add a cell for users to enter their token. For example, to prompt a user to enter an API key a cell could look like:
  ```
  # Enter your API key between the quotes below
  API_KEY="xxxxxx"
  ```
* If the example requires setup of external services or tools, there should be comprehensive documentation showing users how to configure those services. Ideally, any external setup should be avoided or fully automated if possible.
* If notebooks require running inference on dedicated endpoints, the DGX Cloud Lepton CLI can be used in the notebook to spin up an endpoint to serve models. The notebook should walk through installation and configuration of the CLI and creation of the endpoints for the user.

### Notebook Context

The notebooks should be approachable to a wide audience of developers ranging in experience and skills. Assume that consumers of the notebooks have basic understanding of AI applications and Python. High-quality notebooks include explanations of what is happening at each step, demonstrate what users should expect results to look like, and why they should be interested in the example. The goal of the notebooks is for developers to learn something new and be a launching point for diving deeper in any area.

For areas that aren't considered general public knowledge, add a brief explainer on what it is trying to achieve and what users can do with it.

For deeper technical dives in any area, add links to further information for users that want to learn more on their own. Notebooks should provide enough explanation to give an idea of what's happening, but shouldn't focus on diving too deep in technical aspects to keep them approachable.

### Epilogue

It is recommended to add an epilogue or "Next Steps" to your notebook so users can expand upon the provided example to learn more about the subject or tailor it further to their needs.

### Notebook Standards

It's important to keep notebooks clean so they are easier to follow. Cells should be specific and focused as opposed to monolithic. The following are some best practices:

* Put all `import` lines in a single cell just for importing modules.
* Try to minimize the number of function declarations in each cell, and only group functions that have similar functionality.
* Avoid putting multiple steps in a single cell (ie. data download + data prep + preprocessing + training).
* Each cell should perform a specific action.

Additionally, cells should be cleared prior to uploading to reduce bloat. Prior to saving the notebook and committing it, make sure the output of all cells are empty.

### Time and Resource Estimates

When appropriate, provide indicators on how long certain tasks should take if they are expected to run for a while. Include examples of how long it takes on a specific GPU type/count when applicable.

## Contributing

Once your notebook is ready, open a new PR and add the [`starter-kits`](https://github.com/NVIDIA/dgx-cloud-examples/issues?q=state%3Aopen%20label%3Astarter-kits) label. Make sure you have satisfied every item in the checklist at the top of the document. The NVIDIA team will review the request and follow up with any additional feedback.

Thank you for helping make DGX Cloud Lepton Starter Kits a great resource for the community! 🚀

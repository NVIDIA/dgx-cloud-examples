# Sample Batch Job Templates for PyTorch and MPI

DGX Cloud Lepton provides the ability to use pre-generated run commands for batch jobs which employ two common
distributed job launch frameworks frequently used in LLM training, fine-tuning, and data preparation:

* Distributed PyTorch and its launch tool `torchrun`
* MPI and its launch tool `mpirun`

The pre-generated examples are essentially "Hello World" examples for each. The examples provided here expand 
on those basics and ensure that a user can see how multi-node NCCL communications could be set up for PyTorch and MPI.

![Lepton Batch Job Templates](../../img/template-launcher.png "Lepton Batch Job Templates")

## MPI


# Workload Examples using DGX Cloud Lepton SDK

These examples showcase how to use the DGX Cloud Lepton SDK to accomplish various tasks in DGX Cloud Lepton. To get started, install and authenticate into the DGX Cloud Lepton CLI with the following commands. 

```
pip install -U leptonai
lep login
```

More information on the SDK can be found in the [DGX Cloud Lepton Documentation](https://docs.nvidia.com/dgx-cloud/lepton/reference/api/).

## [Create Ray Cluster](./create-ray-cluster.py)

[create-ray-cluster.py](./create-ray-cluster.py) uses [LeptonRayCluster](https://github.com/leptonai/leptonai/blob/main/leptonai/api/v1/types/raycluster.py) to create a new `RayCluster` in DGX Cloud Lepton.

This example can be used directly with the following arguments to create your RayCluster.

```
python create-ray-cluster.py --name <NAME> \
--node-group-name <NODE_GROUP>\
--head-resource-shape <SHAPE> \
--worker-resource-shape <SHAPE> \
--image <IMAGE> \
--ray-version <VERSION> \
--workers <NUM_WORKERS> \
--image-pull-secret <SECRET> \
--env <ENV_NAME>=<ENV_VALUE> \
--secret <ENV_NAME>=<SECRET_NAME> \
--mount <PATH:MOUNT_PATH:STORAGE_TYPE:STORAGE_NAME> \
--is-private
```

`--env` and `--secret` arguments can be added multiple times to append additional environment variables and secrets.

If `--is-private` is not set, the RayCluster will default to being visible to all members of the workspace

## [Start Ray Job](./start-ray-job.py)

You can use the native ray SDK to interact with your Lepton Ray Clusters. This example showcases one way to start a job with the Ray SDK. 

```
python start-ray-job.py --cluster-name <NAME> \
--command <COMMAND> \
--job-name <NAME(optional argument)>
```
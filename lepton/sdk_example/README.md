# Workload Examples using Lepton SDK

These examples showcase how to use the Lepton SDK to accomplish various tasks in Lepton. To get started, install and authenticate into the Lepton CLI with the following commands. 

```
pip install -U leptonai
lep login
```

More information on the SDK can be found in the [Lepton Documentation](https://docs.nvidia.com/dgx-cloud/lepton/reference/api/).

## Create Ray Job

[create-ray-job.py](./create-ray-job.py) uses [LeptonRayCluster](https://github.com/leptonai/leptonai/blob/main/leptonai/api/v1/types/raycluster.py) to create a new `RayCluster` in Lepton.

This example can be used directly with the following arguments to create your RayCluster.

```
python create-ray-job.py --name <NAME> \
--node-group-name <NODE_GROUP>\
--head-resource-shape <SHAPE> \
--worker-resource-shape <SHAPE> \
--image <IMAGE> \
--image-version <VERSION> \
--workers <NUM_WORKERS> \
--image-pull-secret <SECRET> \
--env <ENV_NAME>=<ENV_VALUE> \
--secret <ENV_NAME>=<SECRET_NAME> \
--mount <PATH:MOUNT_PATH:STORAGE_TYPE:STORAGE_NAME> \
--is_private

```

`--env` and `--secret` arguments can be added multiple times to append additional environment variables and secrets.

If `--is_private` is not set, the RayCluster will default to being visible to all members of the workspace
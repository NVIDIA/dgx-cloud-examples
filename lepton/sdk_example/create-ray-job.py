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
from leptonai.api.v2.client import APIClient
from leptonai.api.v1.types.common import Metadata, LeptonVisibility
from leptonai.api.v1.types.affinity import LeptonResourceAffinity
from leptonai.api.v1.types.deployment import Mount, EnvVar, EnvValue
from leptonai.api.v1.types.raycluster import (
    LeptonRayCluster,
    LeptonRayClusterUserSpec,
    RayHeadGroupSpec,
    RayWorkerGroupSpec,
)

def get_node_group_id(node_group_name: str, client: APIClient) -> str:
    ### node affinity is a list of node group ids, so we need to get the id of the node group given it's name

    node_groups = client.nodegroup.list_all()
    for node_group in node_groups:
        if node_group.metadata.name == node_group_name:
            return node_group.metadata.id_

    raise ValueError(f"Node group {node_group_name} not found")

def set_env(env_name, env_value): 
    ### To set environment variables directly, use EnvVar type with value field directly set
    return EnvVar(name=env_name, value=env_value)

def set_secret(env_name, secret_name):
    ### To set secrets as environment variables, use EnvVar type with `value_from` field set to the secret name reference
    return EnvVar(name=env_name, value_from=EnvValue(secret_name_ref=secret_name))

def set_mount(path,mount_path,storage):
    ### Set mount object with from path and to path

    mount_dict= {
        "path": path, # path from storage to mount
        "from": storage, # storage system in format <storage_type>:<storage_name>
        "mount_path": mount_path # path mounted on node
    }
    return Mount(**mount_dict)

def create_ray_job(
    name: str,
    node_group_name: str,
    head_resource_shape: str,
    worker_resource_shape: str,
    image: str ="ray:2.46.0",
    ray_version: str ="2.46.0",
    image_pull_secret: str = "",
    worker_num_replicas: int = 1,
    env_vars: list[str] = [],
    secret_vars: list[str] = [],
    mounts: list[str] =[],
    is_private: bool = False,
    client: APIClient = APIClient(),
) -> None:
    """
    Create a Ray cluster job with configurable parameters.
    
    Args:
        name: Name of the Ray cluster
        node_group_name: Name of Node Group to allocate nodes from for the cluster
        head_resource_shape: RayCluster head node shape eg. gpu.8xh200
        worker_resource_shape: RayCluster worker nodes shape eg. gpu.8xh200
        image: Ray image (default: ray:2.46.0)
        ray_version: Ray version (default: 2.46.0)
        image_pull_secret: Name of image_pull_secret if needed
        worker_num_replicas: Number of worker replicas (default: 1)
        env_vars: List of environment variables (default: Empty list)
        secret_vars: List of secret environment variables (default: Empty list)
        mounts: List of storage mounts (default: Empty list)
        is_private: Cluster visibility (default: False for PUBLIC)
        client: Lepton API client object
    """

    env_list = []
    mount_objects = []

    for env_var in env_vars:
        if "=" not in env_var:
            raise ValueError(f"Invalid environment variable format: {env_var}. Use KEY=VALUE format.")
        key, value = env_var.split("=", 1)
        env_list.append(set_env(key, value))
    
    for secret_var in secret_vars:
        if "=" not in secret_var:
            raise ValueError(f"Invalid secret variable format: {secret_var}. Use ENV_NAME=SECRET_REF format.")
        key, value = secret_var.split("=", 1)
        env_list.append(set_secret(key, value))
    
    for mount in mounts:
        if ":" not in mount:
            raise ValueError(f"Invalid mount format: {mount}. Use PATH:MOUNT_PATH:STORAGE_TYPE:STORAGE_NAME format.")
        mount_list = mount.split(":",3)
        if len(mount_list) != 4:
            raise ValueError(f"Invalid mount format: {mount}. Use PATH:MOUNT_PATH:STORAGE_TYPE:STORAGE_NAME format.")
        from_obj=f'{mount_list[2]}:{mount_list[3]}' ## storage system in format <storage_type>:<storage_name>
        mount_objects.append(set_mount(mount_list[0],mount_list[1],from_obj))

    spec = LeptonRayClusterUserSpec(
        image=image,
        ray_version=ray_version,
        image_pull_secrets=[image_pull_secret],
        head_group_spec=RayHeadGroupSpec(
            resource_shape=head_resource_shape,
            min_replicas=1,
            affinity=LeptonResourceAffinity(
                allowed_dedicated_node_groups=[get_node_group_id(node_group_name, client)]
            ),
            envs=env_list,
            mounts=mount_objects
        ),
        worker_group_specs=[RayWorkerGroupSpec(
            resource_shape=worker_resource_shape,
            min_replicas=worker_num_replicas,
            affinity=LeptonResourceAffinity(
                allowed_dedicated_node_groups=[get_node_group_id(node_group_name, client)]
            ),
            envs=env_list,
            mounts=mount_objects
        )]
    )

    lepton_raycluster = LeptonRayCluster(
            metadata=Metadata(
                id=name,
                name=name,
                visibility=LeptonVisibility.PRIVATE if is_private else LeptonVisibility.PUBLIC
            ),
            spec=spec,
        )

    created = client.raycluster.create(lepton_raycluster)
    if created:
        print(f"Ray cluster {name} created")
        print(f"Ray dashboard URL will be {client.url}/rayclusters/{name}/dashboard")
    else:
        print(f"Ray cluster {name} creation failed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Create a Ray cluster with configurable node groups and environment variables",
    )
    parser.add_argument(
        "--name",
        type=str,
        required=True,
        help="Name of the Ray cluster"
    )
    
    parser.add_argument(
        "--node-group-name",
        type=str,
        required=True,
        help="Name of the dedicated node group"
    )
    
    parser.add_argument(
        "--head-resource-shape",
        type=str,
        required=True,
        help="Resource shape for head node (e.g., 'gpu.8xh200')"
    )
    
    parser.add_argument(
        "--worker-resource-shape",
        type=str,
        required=True,
        help="Resource shape for workers (e.g., 'gpu.8xh200')"
    )
    
    parser.add_argument(
        "--image",
        type=str,
        default="ray:2.46.0",
        help="Container image to use (default: ray:2.46.0)"
    )
    
    parser.add_argument(
        "--ray-version",
        type=str,
        default="2.46.0",
        help="Ray version (default: 2.46.0)"
    )
    
    parser.add_argument(
        "--image-pull-secret",
        type=str,
        default="",
        help="Image pull secret name (default: empty string)"
    )

    parser.add_argument(
        "--workers",
        type=int,
        default=1,
        help="Number of worker replicas (default: 1)"
    )
    
    parser.add_argument(
        "--env",
        action="append",
        dest="env_vars",
        default=[],
        metavar="KEY=VALUE",
        help="Environment variable in ENV_NAME=ENV_VALUE format. Can be specified multiple times."
    )
    
    parser.add_argument(
        "--secret",
        action="append",
        dest="secret_vars",
        default=[],
        metavar="ENV_NAME=SECRET_REF",
        help="Secret environment variable in ENV_NAME=SECRET_REF format (e.g., WANDB_API_KEY=WANDB_API_KEY.zozhang). Can be specified multiple times."
    )

    parser.add_argument(
        "--mount",
        action="append",
        dest="mounts",
        default=[],        
        metavar="PATH:MOUNT_PATH:STORAGE_TYPE:STORAGE_NAME",
        help="Mount storage in PATH:MOUNT_PATH:STORAGE_TYPE:STORAGE_NAME format (e.g., /data:/workspace/data:pfs:my-storage). Can be specified multiple times."
    )
    
    parser.add_argument(
        "--is-private",
        action="store_true",
        default=False,
        help="Make RayCluster private from other workspace users (default: False)"
    )

    args = parser.parse_args()

    client = APIClient()

    # Create the Ray cluster
    create_ray_job(
        name=args.name,
        node_group_name=args.node_group_name,
        head_resource_shape=args.head_resource_shape,
        worker_resource_shape=args.worker_resource_shape,
        image=args.image,
        ray_version=args.ray_version,
        image_pull_secret=args.image_pull_secret,
        worker_num_replicas=args.workers,
        mounts=args.mounts,
        env_vars=args.env_vars,
        secret_vars=args.secret_vars,
        is_private=args.is_private,
        client=client,
    )

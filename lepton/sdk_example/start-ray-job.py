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

from leptonai.api.v2.client import APIClient
from ray.job_submission import JobSubmissionClient
import argparse

def run_ray_job(cluster_name: str, job_name: str, command: str, client: APIClient):
    ray_url= f"{client.url}/rayclusters/{cluster_name}/dashboard"
    job_submission_client = JobSubmissionClient(
        address=ray_url,
        headers={
            "Authorization": f"Bearer {client.token()}",
            "origin": client.get_dashboard_base_url()
        },
        verify=False
    )
    job_id = job_submission_client.submit_job(submission_id=job_name, entrypoint=command)
    return job_id

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--cluster-name", type=str, required=True)
    parser.add_argument("--job-name", type=str, required=False)
    parser.add_argument("--command", type=str, required=True)
    args = parser.parse_args()

    client = APIClient()
    id = run_ray_job(cluster_name=args.cluster_name, job_name=args.job_name, command=args.command, client=client)
    print(f"Job {args.job_name if args.job_name else ''} submitted with ID: {id}")

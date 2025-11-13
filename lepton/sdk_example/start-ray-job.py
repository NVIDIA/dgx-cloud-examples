from leptonai.api.v2.client import APIClient
from ray.job_submission import JobSubmissionClient, JobStatus
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

# ACI Automation For AFD WebSocket Testing

## Goal

Automate Azure Front Door WebSocket load tests by running the load generator inside Azure Container Instances (ACI) instead of from a local machine.

## Approach

1. Provision a dedicated ACI container group for each test run.
2. Run a Python command inside the container that:
- installs `websockets`
- runs a lightweight async WebSocket load test against the AFD endpoint
- prints a compact summary to container logs
3. Collect results using `az container logs` and (optionally) store them in a file from CI/CD.
4. Delete the container group after each run to keep costs low and avoid stale state.

## Why ACI

- No local machine resource bottlenecks.
- Easy to run in repeatable CI pipelines.
- Supports quick horizontal scale by creating multiple container groups.

## Deliverables In This Folder

- `infra/main.bicep`: ACI resource definition for running the test.
- `infra/main.parameters.example.json`: sample parameters.
- `deploy_aci_test.sh`: deploys or updates the ACI test runner.
- `run_aci_test.sh`: executes a complete test cycle (deploy, wait, fetch logs, cleanup).
- `run_aci_distributed_test.sh`: launches multiple ACI groups in parallel and aggregates one summary report.

## Deployment Process

1. Copy example parameters and adjust test inputs:
- target websocket URL
- number of connections
- test duration
- message size
2. Deploy with `deploy_aci_test.sh`.
3. Wait until container terminates.
4. Read logs with `az container logs`.
5. Remove the container group.

## Testing Process

1. Start with a baseline run (for example: 200 connections, 60s).
2. Increase concurrency in steps (for example: 200, 500, 1000, 2000).
3. Track:
- successful connects
- failed connects
- send and echo success counts
- latency percentiles
- dominant error categories
4. Optionally run multiple ACI container groups in parallel for higher distributed load.

## Distributed Parallel Test

Use this script to distribute load across multiple ACI groups and aggregate all results:

```bash
bash tester/aci/run_aci_distributed_test.sh \
	rg-ws-echo \
	tester/aci/infra/main.parameters.example.json \
	afd-ws-dist \
	4 \
	500 \
	true
```

Arguments:

- `resource-group`
- `base-parameters-json`
- `group-prefix`
- `groups-count`
- `connections-per-group`
- `cleanup` (`true` or `false`, default: `true`)

Outputs:

- per-group logs in `tester/aci/.runs/<run_id>/`
- aggregated report in `tester/aci/.runs/<run_id>/aggregate-summary.txt`

Reliability behavior:

- uses unique ARM deployment names per group to avoid collisions in parallel runs
- retries transient image pull failures (`RegistryErrorResponse`) up to 3 times
- continues with successfully created groups when some groups fail to deploy
- exits early with diagnostics if no groups were created

## Notes

- This method validates from Azure network perspective, which is closer to production than local testing.
- For very high connection counts, split load across several ACI groups and aggregate logs.

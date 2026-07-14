# WebSocket Echo Behind Azure Front Door (Plan First)

## Simple Plan

1. Build a Python WebSocket echo backend service.
2. Add a Python load and limit test client that opens many WebSocket connections to an Azure Front Door endpoint.
3. Add infrastructure code to provision Azure Front Door Standard/Premium with a route to a backend origin.
4. Add configuration templates so endpoint URL, connection count, duration, and message size can be tuned quickly.
5. Document run and validation steps: local test, deploy infra, point backend, then run AFD limit tests.
6. Capture expected metrics: successful connections, failures, latency, echo success rate, and disconnect reasons.

## Deliverables

- Python echo service
- Python AFD WebSocket stress and limit tester
- Infra-as-code for Azure Front Door routing to WebSocket backend
- Minimal usage instructions

## What Was Implemented

- `backend/app.py`: FastAPI WebSocket echo service on `/ws/echo` and health endpoint on `/health`.
- `tester/afd_ws_limit_test.py`: Concurrent WebSocket tester for Azure Front Door, including latency and error summary.
- `infra/main.bicep`: Deploys Linux App Service (WebSockets enabled) and Azure Front Door profile/endpoint/route/origin.
- `infra/main.parameters.example.json`: Example deployment parameters.
- `requirements.txt`: Python dependencies for backend and tester.
- `run_local.sh`: Local run helper.
- `deploy_azure.sh`: Resource group deployment helper.
- `test_afd.sh`: AFD load test helper.

## Local Run

1. Start the backend service:

```bash
bash run_local.sh
```

2. In a second terminal, run a local test directly against the service:

```bash
source .venv/bin/activate
python tester/afd_ws_limit_test.py --url ws://localhost:8000/ws/echo --connections 50 --duration 20
```

## Azure Deployment (Infra)

1. Create or use a resource group:

```bash
az group create --name rg-ws-echo --location westeurope
```

2. Copy and adjust parameters:

```bash
cp infra/main.parameters.example.json infra/main.parameters.json
```

3. Deploy infrastructure:

```bash
bash deploy_azure.sh rg-ws-echo infra/main.parameters.json
```

Deployment outputs include:

- Web app URL
- Front Door URL

## Deploy Backend Code To App Service

Build a zip package and deploy it using the helper scripts in this folder.

1. Build deployment zip:

```bash
bash package_app_zip.sh
```

This creates `appservice-package.zip` with:

- `backend/`
- `requirements.txt`

2. Deploy zip to App Service:

```bash
bash deploy_app_zip.sh <resource-group> <web-app-name> appservice-package.zip
```

Sample:
```bash
bash deploy_app_zip.sh rg-ws-echo websocket-echo-demo-12345 appservice-package.zip
```

The deploy script also sets:

- WebSockets enabled
- Oryx build settings (`SCM_DO_BUILD_DURING_DEPLOYMENT=1`, `ENABLE_ORYX_BUILD=true`)
- Startup command:

```bash
uvicorn backend.app:app --host 0.0.0.0 --port 8000
```

Manual deployment command (if needed):

```bash
az webapp deploy --resource-group <resource-group> --name <web-app-name> --src-path appservice-package.zip --type zip
```

## AFD Limit Testing

After Front Door is active and backend is deployed, run:

```bash
source .venv/bin/activate
bash test_afd.sh wss://<your-afd-endpoint>/ws/echo 500 60
```

Get the actual Front Door host (it includes a generated suffix) and use it in the test URL:

```bash
az afd endpoint show -g rg-ws-echo --profile-name afd-ws-echo-demo --endpoint-name afd-ws-echo-endpoint --query hostName -o tsv
```

Example with generated host:

```bash
bash test_afd.sh wss://afd-ws-echo-endpoint-hfgkfee9heergudn.z01.azurefd.net/ws/echo 500 60
```

Example manual invocation:

```bash
python tester/afd_ws_limit_test.py \
	--url wss://afd-ws-echo-endpoint.z01.azurefd.net/ws/echo \
	--connections 1000 \
	--duration 120 \
	--ramp-delay 0.005 \
	--send-interval 0.2 \
	--message-size 256
```

## Metrics Captured

- `connect_ok`, `connect_fail`
- `echo_ok`, `echo_mismatch`
- `recv_fail`, `disconnects`
- `latency_p50_ms`, `latency_p95_ms`
- grouped error reasons by exception type

@description('Deployment location')
param location string = resourceGroup().location

@description('ACI container group name')
param containerGroupName string = 'afd-ws-test-runner'

@description('Container image to run the test command')
param containerImage string = 'mcr.microsoft.com/devcontainers/python:1-3.11-bullseye'

@description('CPU cores for container')
param cpuCores int = 2

@description('Memory in GB for container')
param memoryInGb int = 4

@description('Target WebSocket URL (wss://.../ws/echo)')
param targetWsUrl string

@description('Number of concurrent connections')
param connections int = 500

@description('Test duration in seconds')
param duration int = 60

@description('Delay between connection starts in seconds')
param rampDelay string = '0.01'

@description('Delay between sends in seconds')
param sendInterval string = '0.5'

@description('Message size in bytes')
param messageSize int = 128

@description('Restart policy for container group')
@allowed([
  'Never'
  'OnFailure'
  'Always'
])
param restartPolicy string = 'Never'

var testCommand = '''
set -e
pip install --no-cache-dir websockets==15.0.1
python - <<'PY'
import asyncio
import os
import random
import statistics
import string
import time
from dataclasses import dataclass, field
import websockets

TARGET = os.environ["TARGET_WS_URL"]
CONNECTIONS = int(os.environ["CONNECTIONS"])
DURATION = int(os.environ["DURATION"])
RAMP_DELAY = float(os.environ["RAMP_DELAY"])
SEND_INTERVAL = float(os.environ["SEND_INTERVAL"])
MESSAGE_SIZE = int(os.environ["MESSAGE_SIZE"])

@dataclass
class ResultStore:
    connect_ok: int = 0
    connect_fail: int = 0
    sends_ok: int = 0
    echo_ok: int = 0
    echo_mismatch: int = 0
    recv_fail: int = 0
    disconnects: int = 0
    latencies_ms: list[float] = field(default_factory=list)
    errors: dict[str, int] = field(default_factory=dict)

    def add_error(self, message: str) -> None:
        self.errors[message] = self.errors.get(message, 0) + 1


def build_payload(size: int, connection_id: int, sequence: int) -> str:
    prefix = f"conn={connection_id};seq={sequence};"
    remaining = max(0, size - len(prefix))
    body = "".join(random.choices(string.ascii_letters + string.digits, k=remaining))
    return prefix + body


async def run_connection(connection_id: int, store: ResultStore, lock: asyncio.Lock) -> None:
    start = time.perf_counter()
    stop_at = start + DURATION
    try:
        async with websockets.connect(TARGET, open_timeout=10, ping_interval=20, ping_timeout=20) as ws:
            async with lock:
                store.connect_ok += 1
            seq = 0
            while time.perf_counter() < stop_at:
                payload = build_payload(MESSAGE_SIZE, connection_id, seq)
                seq += 1
                t0 = time.perf_counter()
                await ws.send(payload)
                async with lock:
                    store.sends_ok += 1
                try:
                    echoed = await asyncio.wait_for(ws.recv(), timeout=10)
                except Exception as ex:
                    async with lock:
                        store.recv_fail += 1
                        store.add_error(f"recv:{type(ex).__name__}")
                    break
                elapsed_ms = (time.perf_counter() - t0) * 1000.0
                async with lock:
                    store.latencies_ms.append(elapsed_ms)
                    if echoed == payload:
                        store.echo_ok += 1
                    else:
                        store.echo_mismatch += 1
                await asyncio.sleep(SEND_INTERVAL)
    except Exception as ex:
        async with lock:
            store.connect_fail += 1
            store.add_error(f"connect:{type(ex).__name__}")
    finally:
        async with lock:
            store.disconnects += 1


def summarize(store: ResultStore, elapsed_s: float) -> str:
    p50 = statistics.median(store.latencies_ms) if store.latencies_ms else 0.0
    p95 = statistics.quantiles(store.latencies_ms, n=100)[94] if len(store.latencies_ms) >= 100 else max(store.latencies_ms, default=0.0)
    lines = [
        "WebSocket AFD limit test summary (ACI)",
        f"duration_s={elapsed_s:.2f}",
        f"target_connections={CONNECTIONS}",
        f"connect_ok={store.connect_ok}",
        f"connect_fail={store.connect_fail}",
        f"sends_ok={store.sends_ok}",
        f"echo_ok={store.echo_ok}",
        f"echo_mismatch={store.echo_mismatch}",
        f"recv_fail={store.recv_fail}",
        f"disconnects={store.disconnects}",
        f"latency_p50_ms={p50:.2f}",
        f"latency_p95_ms={p95:.2f}",
    ]
    if store.errors:
        lines.append("errors=")
        for key, value in sorted(store.errors.items(), key=lambda item: item[0]):
            lines.append(f"  {key}: {value}")
    return "\\n".join(lines)


async def main() -> None:
    store = ResultStore()
    lock = asyncio.Lock()
    tasks = []
    t0 = time.perf_counter()
    for i in range(CONNECTIONS):
        tasks.append(asyncio.create_task(run_connection(i, store, lock)))
        await asyncio.sleep(RAMP_DELAY)
    await asyncio.gather(*tasks)
    elapsed_s = time.perf_counter() - t0
    print(summarize(store, elapsed_s))


if __name__ == "__main__":
    asyncio.run(main())
PY
'''

resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: location
  properties: {
    osType: 'Linux'
    restartPolicy: restartPolicy
    containers: [
      {
        name: 'afd-ws-tester'
        properties: {
          image: containerImage
                    environmentVariables: [
                        {
                            name: 'TARGET_WS_URL'
                            value: targetWsUrl
                        }
                        {
                            name: 'CONNECTIONS'
                            value: '${connections}'
                        }
                        {
                            name: 'DURATION'
                            value: '${duration}'
                        }
                        {
                            name: 'RAMP_DELAY'
                            value: rampDelay
                        }
                        {
                            name: 'SEND_INTERVAL'
                            value: sendInterval
                        }
                        {
                            name: 'MESSAGE_SIZE'
                            value: '${messageSize}'
                        }
                    ]
          command: [
            '/bin/sh'
            '-lc'
            testCommand
          ]
          resources: {
            requests: {
              cpu: cpuCores
              memoryInGB: memoryInGb
            }
          }
        }
      }
    ]
  }
}

output containerGroupName string = containerGroup.name
output containerGroupState string = containerGroup.properties.instanceView.state

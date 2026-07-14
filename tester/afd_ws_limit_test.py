import argparse
import asyncio
import random
import statistics
import string
import time
from dataclasses import dataclass, field

import websockets


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


async def run_connection(
    connection_id: int,
    url: str,
    test_duration_s: int,
    send_interval_s: float,
    message_size: int,
    connect_timeout_s: float,
    receive_timeout_s: float,
    store: ResultStore,
    lock: asyncio.Lock,
) -> None:
    start = time.perf_counter()
    stop_at = start + test_duration_s

    try:
        async with websockets.connect(url, open_timeout=connect_timeout_s, ping_interval=20, ping_timeout=20) as ws:
            async with lock:
                store.connect_ok += 1

            seq = 0
            while time.perf_counter() < stop_at:
                payload = build_payload(message_size, connection_id, seq)
                seq += 1

                t0 = time.perf_counter()
                await ws.send(payload)

                async with lock:
                    store.sends_ok += 1

                try:
                    echoed = await asyncio.wait_for(ws.recv(), timeout=receive_timeout_s)
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

                await asyncio.sleep(send_interval_s)

    except Exception as ex:
        async with lock:
            store.connect_fail += 1
            store.add_error(f"connect:{type(ex).__name__}")
    finally:
        async with lock:
            store.disconnects += 1


def summarize(store: ResultStore, total_connections: int, elapsed_s: float) -> str:
    p50 = statistics.median(store.latencies_ms) if store.latencies_ms else 0.0
    p95 = (
        statistics.quantiles(store.latencies_ms, n=100)[94]
        if len(store.latencies_ms) >= 100
        else max(store.latencies_ms, default=0.0)
    )

    lines = [
        "WebSocket AFD limit test summary",
        f"duration_s={elapsed_s:.2f}",
        f"target_connections={total_connections}",
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

    return "\n".join(lines)


async def main() -> None:
    parser = argparse.ArgumentParser(description="AFD WebSocket echo stress and limit tester")
    parser.add_argument("--url", required=True, help="wss://<afd-endpoint>/ws/echo")
    parser.add_argument("--connections", type=int, default=200, help="Concurrent WebSocket connections")
    parser.add_argument("--duration", type=int, default=30, help="Test duration per connection in seconds")
    parser.add_argument("--ramp-delay", type=float, default=0.01, help="Delay between connection starts in seconds")
    parser.add_argument("--send-interval", type=float, default=0.5, help="Delay between sends per connection in seconds")
    parser.add_argument("--message-size", type=int, default=128, help="Payload size in bytes")
    parser.add_argument("--connect-timeout", type=float, default=10.0, help="Connection timeout in seconds")
    parser.add_argument("--receive-timeout", type=float, default=10.0, help="Echo receive timeout in seconds")
    args = parser.parse_args()

    store = ResultStore()
    lock = asyncio.Lock()
    tasks: list[asyncio.Task[None]] = []

    t0 = time.perf_counter()

    for i in range(args.connections):
        task = asyncio.create_task(
            run_connection(
                connection_id=i,
                url=args.url,
                test_duration_s=args.duration,
                send_interval_s=args.send_interval,
                message_size=args.message_size,
                connect_timeout_s=args.connect_timeout,
                receive_timeout_s=args.receive_timeout,
                store=store,
                lock=lock,
            )
        )
        tasks.append(task)
        await asyncio.sleep(args.ramp_delay)

    await asyncio.gather(*tasks)

    elapsed_s = time.perf_counter() - t0
    print(summarize(store, args.connections, elapsed_s))


if __name__ == "__main__":
    asyncio.run(main())

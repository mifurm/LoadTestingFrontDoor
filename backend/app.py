import logging
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

app = FastAPI(title="ws-echo-service", version="0.1.0")
logger = logging.getLogger("ws-echo")


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.websocket("/ws/echo")
async def echo_socket(websocket: WebSocket) -> None:
    await websocket.accept()
    client = f"{websocket.client.host}:{websocket.client.port}" if websocket.client else "unknown"
    logger.info("connected client=%s", client)

    try:
        while True:
            message = await websocket.receive()
            message_type = message.get("type")

            if message_type == "websocket.disconnect":
                break

            text_data = message.get("text")
            bytes_data = message.get("bytes")

            if text_data is not None:
                await websocket.send_text(text_data)
            elif bytes_data is not None:
                await websocket.send_bytes(bytes_data)
    except WebSocketDisconnect:
        logger.info("disconnected client=%s", client)
    finally:
        try:
            await websocket.close()
        except RuntimeError:
            # Connection may already be closed by peer.
            pass

#!/usr/bin/env python3
"""OBS push-to-talk evdev daemon.

Watches all attached keyboards for any of the configured PTT keys and
drives the OBS Mic/Aux source's mute state via obs-websocket v5. Mic is
unmuted while any tracked key is held (Bellum uses three keys for
local/squad/platoon channels); muted when all are released. Designed to
run as a systemd user service.

Failure modes:
  - OBS not running          retry the websocket connect every 2s
  - daemon crash             systemd restarts (Restart=always)
  - daemon dies mid-record   mic stays in whatever state it was last set
                             to; next PTT press resyncs
"""
import asyncio
import base64
import hashlib
import json
import logging
import os
from pathlib import Path

import evdev
import websockets

KEY_NAMES = os.environ.get("OBS_PTT_KEYS", "KEY_V,KEY_B,KEY_N").split(",")
INPUT_NAME = os.environ.get("OBS_PTT_INPUT", "Mic/Aux")
WS_URL = os.environ.get("OBS_PTT_WS_URL", "ws://127.0.0.1:4455")
OBS_WS_CFG = (
    Path.home() / ".config/obs-studio/plugin_config/obs-websocket/config.json"
)
KEY_CODES = {evdev.ecodes.ecodes[n] for n in KEY_NAMES}

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
)
log = logging.getLogger("obs-ptt")

held: set[int] = set()
state_changed = asyncio.Event()


def desired_muted() -> bool:
    return not held


def load_password() -> str:
    return json.loads(OBS_WS_CFG.read_text())["server_password"]


def find_keyboards() -> list[evdev.InputDevice]:
    devs: list[evdev.InputDevice] = []
    for path in evdev.list_devices():
        try:
            d = evdev.InputDevice(path)
        except (OSError, PermissionError) as e:
            log.warning("skip %s: %s", path, e)
            continue
        caps = set(d.capabilities().get(evdev.ecodes.EV_KEY, []))
        if caps & KEY_CODES:
            devs.append(d)
    return devs


async def watch_device(dev: evdev.InputDevice) -> None:
    async for ev in dev.async_read_loop():
        if ev.type != evdev.ecodes.EV_KEY or ev.code not in KEY_CODES:
            continue
        # ev.value: 0=up, 1=down, 2=autorepeat (ignored)
        prev = bool(held)
        if ev.value == 1:
            held.add(ev.code)
        elif ev.value == 0:
            held.discard(ev.code)
        if bool(held) != prev:
            state_changed.set()


async def evdev_loop() -> None:
    devices = find_keyboards()
    if not devices:
        log.error(
            "no keyboards report %s — check input group membership", KEY_NAMES
        )
        return
    log.info(
        "watching %d keyboards for %s: %s",
        len(devices),
        KEY_NAMES,
        [d.path for d in devices],
    )
    await asyncio.gather(*(watch_device(d) for d in devices))


async def obs_identify(ws: websockets.WebSocketClientProtocol, password: str) -> None:
    hello = json.loads(await ws.recv())
    auth = hello["d"].get("authentication")
    payload: dict = {"op": 1, "d": {"rpcVersion": 1}}
    if auth:
        secret = base64.b64encode(
            hashlib.sha256((password + auth["salt"]).encode()).digest()
        ).decode()
        ident = base64.b64encode(
            hashlib.sha256((secret + auth["challenge"]).encode()).digest()
        ).decode()
        payload["d"]["authentication"] = ident
    await ws.send(json.dumps(payload))
    resp = json.loads(await ws.recv())
    if resp["op"] != 2:
        raise RuntimeError(f"OBS identify failed: {resp}")


async def send_mute(ws: websockets.WebSocketClientProtocol, muted: bool) -> None:
    await ws.send(
        json.dumps(
            {
                "op": 6,
                "d": {
                    "requestType": "SetInputMute",
                    "requestId": "ptt",
                    "requestData": {
                        "inputName": INPUT_NAME,
                        "inputMuted": muted,
                    },
                },
            }
        )
    )


async def ws_loop() -> None:
    password = load_password()
    while True:
        try:
            async with websockets.connect(WS_URL) as ws:
                await obs_identify(ws, password)
                log.info("connected to OBS at %s", WS_URL)
                last_sent: bool | None = None
                while True:
                    want = desired_muted()
                    if last_sent != want:
                        await send_mute(ws, want)
                        last_sent = want
                    state_changed.clear()
                    recv = asyncio.create_task(ws.recv())
                    chg = asyncio.create_task(state_changed.wait())
                    _, pending = await asyncio.wait(
                        {recv, chg}, return_when=asyncio.FIRST_COMPLETED
                    )
                    for t in pending:
                        t.cancel()
        except (
            OSError,
            websockets.exceptions.WebSocketException,
            FileNotFoundError,
        ) as e:
            log.info("OBS unavailable (%s); retrying in 2s", e)
            await asyncio.sleep(2)


async def main() -> None:
    await asyncio.gather(evdev_loop(), ws_loop())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

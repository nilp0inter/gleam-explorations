#!/usr/bin/env python3
"""Generate fake roulette test run data and send via WebSocket."""

import asyncio
import json
import random
import sys

import websockets

# European roulette number -> color mapping
RED_NUMBERS = {1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36}
BLACK_NUMBERS = {2, 4, 6, 8, 10, 11, 13, 15, 17, 20, 22, 24, 26, 28, 29, 31, 33, 35}


def number_to_color(n: int) -> str:
    if n == 0:
        return "green"
    if n in RED_NUMBERS:
        return "red"
    return "black"


def generate_run() -> dict:
    # Correlated but not deterministic: mix a shared factor with independent noise
    shared = random.random()  # 0..1, drives the correlation
    force = round(0.5 + 9.5 * (0.6 * shared + 0.4 * random.random()), 2)
    duration = round(0.5 + 11.5 * (0.6 * shared + 0.4 * random.random()), 2)
    winning_number = random.randint(0, 36)
    color = number_to_color(winning_number)
    return {
        "type": "submit_test_run",
        "force": force,
        "duration": duration,
        "winning_number": winning_number,
        "color": color,
    }


async def main():
    url = "ws://localhost:8080/ws"
    rate = float(sys.argv[1]) if len(sys.argv) > 1 else 2.0  # runs per second
    total = int(sys.argv[2]) if len(sys.argv) > 2 else 0  # 0 = infinite
    delay = 1.0 / rate

    print(f"Connecting to {url}...")
    async with websockets.connect(url) as ws:
        print(f"Connected. Sending {total or '∞'} runs at {rate}/s")
        count = 0
        while total == 0 or count < total:
            run = generate_run()
            await ws.send(json.dumps(run))
            count += 1
            if count % 10 == 0:
                print(f"  Sent {count} runs...")
            await asyncio.sleep(delay)
        print(f"Done. Sent {count} runs total.")


if __name__ == "__main__":
    asyncio.run(main())

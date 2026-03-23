#!/usr/bin/env python3
"""Generate UNFAIR roulette test run data and send via WebSocket.

The wheel is rigged:
- Black numbers are heavily favored (~60% of outcomes)
- High force + long duration tends to land on a few "house" numbers (17, 20, 22)
- Low force spins cluster around 0 and neighbors (0, 32, 15, 19, 4)
- Number 7 almost never hits
"""

import asyncio
import json
import random
import sys

import websockets

# European roulette number -> color mapping
RED_NUMBERS = {1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36}
BLACK_NUMBERS = {2, 4, 6, 8, 10, 11, 13, 15, 17, 20, 22, 24, 26, 28, 29, 31, 33, 35}

# Weighted number pools
HOUSE_NUMBERS = [17, 20, 22, 26, 28, 31, 33, 35]  # all black
LOW_FORCE_NUMBERS = [0, 32, 15, 19, 4, 2, 21]  # near 0 on the wheel
REGULAR_BLACK = sorted(BLACK_NUMBERS)
REGULAR_RED = sorted(RED_NUMBERS)


def number_to_color(n: int) -> str:
    if n == 0:
        return "green"
    if n in RED_NUMBERS:
        return "red"
    return "black"


def pick_rigged_number(force: float, duration: float) -> int:
    r = random.random()

    if force < 3.0:
        # Low force: cluster around 0 and neighbors
        if r < 0.50:
            return random.choice(LOW_FORCE_NUMBERS)
        elif r < 0.80:
            return random.choice(REGULAR_BLACK)
        else:
            return random.choice(REGULAR_RED)
    elif force > 7.0 and duration > 7.0:
        # High force + long duration: house numbers dominate
        if r < 0.55:
            return random.choice(HOUSE_NUMBERS)
        elif r < 0.85:
            return random.choice(REGULAR_BLACK)
        else:
            return random.choice(REGULAR_RED)
    else:
        # Medium: still biased toward black
        if r < 0.50:
            return random.choice(REGULAR_BLACK)
        elif r < 0.80:
            return random.choice(REGULAR_RED)
        elif r < 0.85:
            return 0
        else:
            # Avoid 7
            pool = [n for n in range(1, 37) if n != 7]
            return random.choice(pool)


def generate_run() -> dict:
    shared = random.random()
    force = round(0.5 + 9.5 * (0.6 * shared + 0.4 * random.random()), 2)
    duration = round(0.5 + 11.5 * (0.6 * shared + 0.4 * random.random()), 2)
    winning_number = pick_rigged_number(force, duration)
    color = number_to_color(winning_number)
    return {
        "type": "submit_test_run",
        "force": force,
        "duration": duration,
        "winning_number": winning_number,
        "color": color,
    }


async def drain(ws):
    """Continuously read and discard incoming messages to prevent buffer backup."""
    try:
        async for _ in ws:
            pass
    except websockets.exceptions.ConnectionClosed:
        pass


async def main():
    url = "ws://localhost:8080/ws"
    rate = float(sys.argv[1]) if len(sys.argv) > 1 else 2.0  # runs per second
    total = int(sys.argv[2]) if len(sys.argv) > 2 else 0  # 0 = infinite
    delay = 1.0 / rate

    print(f"Connecting to {url}...")
    print("*** UNFAIR ROULETTE MODE ***")
    async with websockets.connect(url) as ws:
        asyncio.create_task(drain(ws))
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

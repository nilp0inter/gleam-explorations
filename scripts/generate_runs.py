#!/usr/bin/env python3
"""Generate roulette test run data and send via WebSocket.

Supports fair and unfair (rigged) modes.
"""

import argparse
import asyncio
import json
import random
import sys
from datetime import datetime, timezone

import websockets

# European roulette number -> color mapping
RED_NUMBERS = {1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36}
BLACK_NUMBERS = {2, 4, 6, 8, 10, 11, 13, 15, 17, 20, 22, 24, 26, 28, 29, 31, 33, 35}

# Weighted number pools (unfair mode)
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


def pick_fair_number() -> int:
    return random.randint(0, 36)


def pick_rigged_number(force: float, duration: float) -> int:
    r = random.random()

    if force < 3.0:
        if r < 0.50:
            return random.choice(LOW_FORCE_NUMBERS)
        elif r < 0.80:
            return random.choice(REGULAR_BLACK)
        else:
            return random.choice(REGULAR_RED)
    elif force > 7.0 and duration > 7.0:
        if r < 0.55:
            return random.choice(HOUSE_NUMBERS)
        elif r < 0.85:
            return random.choice(REGULAR_BLACK)
        else:
            return random.choice(REGULAR_RED)
    else:
        if r < 0.50:
            return random.choice(REGULAR_BLACK)
        elif r < 0.80:
            return random.choice(REGULAR_RED)
        elif r < 0.85:
            return 0
        else:
            pool = [n for n in range(1, 37) if n != 7]
            return random.choice(pool)


def generate_run(unfair: bool) -> dict:
    shared = random.random()
    force = round(0.5 + 9.5 * (0.6 * shared + 0.4 * random.random()), 2)
    duration = round(0.5 + 11.5 * (0.6 * shared + 0.4 * random.random()), 2)

    if unfair:
        winning_number = pick_rigged_number(force, duration)
    else:
        winning_number = pick_fair_number()

    color = number_to_color(winning_number)

    start_time = datetime.now(timezone.utc)

    # Simulate step execution with realistic timings
    steps = [
        {
            "name": "Place bet",
            "duration_ms": round(random.uniform(5, 80), 2),
            "status": "pass",
        },
        {
            "name": "Launch ball",
            "duration_ms": round(random.uniform(10, 500), 2),
            "status": "pass",
        },
        {
            "name": "Spin wheel",
            "duration_ms": round(random.uniform(100, 2000), 2),
            "status": "pass",
        },
        {
            "name": "Ball lands",
            "duration_ms": round(random.uniform(5, 100), 2),
            "status": "pass",
        },
        {
            "name": "Verify color",
            "duration_ms": round(random.uniform(1, 50), 2),
            "status": "pass",
        },
    ]

    end_time = datetime.now(timezone.utc)
    status = "pass" if all(s["status"] == "pass" for s in steps) else "fail"

    logs = [
        f"[{start_time.strftime('%H:%M:%S.%f')[:-3]}] Starting roulette run",
        f"[{start_time.strftime('%H:%M:%S.%f')[:-3]}] Bet placed on table",
    ]
    for s in steps:
        logs.append(
            f"[{start_time.strftime('%H:%M:%S.%f')[:-3]}] Step '{s['name']}': "
            f"{s['status'].upper()} ({s['duration_ms']}ms)"
        )
    if status == "fail":
        logs.append(f"[{end_time.strftime('%H:%M:%S.%f')[:-3]}] Run FAILED")
    else:
        logs.append(f"[{end_time.strftime('%H:%M:%S.%f')[:-3]}] Run completed successfully")

    gherkin_text = (
        f"Scenario: Roulette spin\n"
        f"  Given a European roulette wheel\n"
        f"  When the ball is launched with force {force}\n"
        f"  And the wheel spins for {duration}s\n"
        f"  Then the ball lands on number {winning_number}\n"
        f"  And the winning color is {color}"
    )

    return {
        "type": "submit_full_test_run",
        "force": force,
        "duration": duration,
        "winning_number": winning_number,
        "color": color,
        "start_date": start_time.isoformat(),
        "end_date": end_time.isoformat(),
        "status": status,
        "logs": logs,
        "gherkin_text": gherkin_text,
        "step_metrics": steps,
    }


async def drain(ws):
    """Continuously read and discard incoming messages to prevent buffer backup."""
    try:
        async for _ in ws:
            pass
    except websockets.exceptions.ConnectionClosed:
        pass


async def run(args):
    url = args.url
    delay = 1.0 / args.rate

    mode = "UNFAIR" if args.unfair else "FAIR"
    print(f"Connecting to {url}...")
    if args.unfair:
        print("*** UNFAIR ROULETTE MODE ***")

    async with websockets.connect(url) as ws:
        asyncio.create_task(drain(ws))
        total_label = args.count or "\u221e"
        print(f"Connected. Sending {total_label} {mode} runs at {args.rate}/s")
        count = 0
        while args.count == 0 or count < args.count:
            msg = generate_run(unfair=args.unfair)
            await ws.send(json.dumps(msg))
            count += 1
            if count % 10 == 0:
                print(f"  Sent {count} runs...")
            await asyncio.sleep(delay)
        print(f"Done. Sent {count} runs total.")


def main():
    parser = argparse.ArgumentParser(description="Generate roulette test runs via WebSocket")
    parser.add_argument(
        "--unfair", action="store_true",
        help="Use rigged roulette (biased toward black, house numbers)",
    )
    parser.add_argument(
        "--rate", type=float, default=2.0,
        help="Runs per second (default: 2.0)",
    )
    parser.add_argument(
        "--count", type=int, default=0,
        help="Total runs to send, 0 for infinite (default: 0)",
    )
    parser.add_argument(
        "--url", type=str, default="ws://localhost:8080/ws",
        help="WebSocket URL (default: ws://localhost:8080/ws)",
    )
    args = parser.parse_args()
    asyncio.run(run(args))


if __name__ == "__main__":
    main()

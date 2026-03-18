# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This project uses [go-task](https://taskfile.dev/) (not Make) for build orchestration.

```bash
task          # Build everything (shared → client → server)
task run      # Build and run the server on http://localhost:8080
task clean    # Remove all build artifacts
```

Individual packages can be built with `task shared`, `task client`, `task server`. The build chain is: shared → client (compiles to JS, bundled via esbuild) → server.

To build a single package during development: `cd <package> && gleam build`.

## Architecture

Three-package Gleam monorepo: a message queue explorer where HTTP clients POST messages to named queues, and browser users explore them in real-time via WebSocket.

### Packages

- **shared/** — Cross-platform (no target set). Message types (`ServerMessage`, `ClientMessage`) and their JSON encoders/decoders. Used by both server and client, so it must only use libraries that work on both Erlang and JavaScript targets (`gleam_stdlib`, `gleam_json`).
- **server/** — Erlang target. HTTP + WebSocket server using mist and wisp.
- **client/** — JavaScript target. Lustre SPA using `lustre_websocket` for real-time communication.

### Server: mist + wisp coexistence

The main entry point (`server/src/server.gleam`) creates a top-level mist handler that dispatches by path: `/ws` routes to `mist.websocket()` directly, everything else delegates to `wisp_mist.handler()`. This is necessary because wisp doesn't handle WebSocket natively.

### Server: state actor

`server/src/server/state.gleam` is an OTP actor holding all application state: queues (name → messages), subscribers (queue → list of WS client subjects), and connected clients. All mutations go through this actor.

### Server: WebSocket push via Selector

Each WebSocket connection creates a `Subject(String)` registered with the state actor. When the actor needs to push data, it `process.send`s a JSON string to that subject. Mist's Selector mechanism delivers it as a `Custom(String)` message to the WS handler, which calls `send_text_frame`. This indirection is required because `send_text_frame` must be called from the WebSocket's owning process.

### Client: JS bundling

The client compiles to ES modules, then esbuild bundles everything into `server/priv/static/app.js`. The server's HTML shell loads it via `<script type="module">` and calls `main()`.

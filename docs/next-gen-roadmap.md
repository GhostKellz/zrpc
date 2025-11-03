# zRPC Next-Gen Readiness Plan (November 2025)

## Snapshot of the Current State

- **Core architecture (`src/core/*.zig`)** – The transport-agnostic core exists, but critical paths such as client response handling (`src/core/client.zig`) and server stream lifecycle (`src/core/server.zig`) still contain TODOs for timeout handling, status parsing, and error propagation. Active stream tracking is wired, yet cancellation, deadlines, and backpressure are unfinished.
- **Transport adapters**
  - **QUIC (`src/adapters/quic/transport.zig`)** – Connection setup uses the in-tree QUIC implementation, but listener `accept` and ping logic currently return `TransportError.Protocol`, so servers cannot accept real connections. TLS integration is stubbed and connection metrics are absent.
  - **HTTP/2 (`src/adapters/http2/transport.zig`)** – Built on the legacy `transport.zig` API instead of the new SPI. It implements framing helpers but is not wired into the build and lacks server support, HPACK dynamic table management, and TLS/ALPN negotiation.
  - **WebSocket / HTTP/3 adapters** – Source files exist with rich scaffolding, yet they depend on unimplemented handshake/TLS paths and observability hooks. None are exposed via `build.zig` so they cannot be consumed.
- **Legacy surface (`src/root.zig`, `src/service.zig`, `src/transport.zig`)** – The old monolithic API still exports incomplete functionality (e.g., streaming methods return `Error.NotImplemented`) and collides conceptually with the modular core.
- **Observability modules (`src/logging.zig`, `src/metrics*.zig`, `src/tracing.zig`)** – Comprehensive utility code is present, but nothing invokes these modules from the core server/client, so instrumentation is effectively dead code.
- **Documentation** – Marketing copy (README, TODO) asserts completion of HTTP/2/3, WebSocket, compression, metrics, and tracing even though these are pre-release. The getting-started guide still references the monolithic `@import("zrpc")` entry point and synchronous APIs removed from the new core.
- **Tooling & CLI** – The build installs a placeholder binary (`src/main.zig`) that just prints a string. There is no CLI, REPL, or contract-test harness exposed to users.
- **Testing/CI** – Many test binaries are registered (`alpha`, `beta`, `rc*`), but they all point at example stubs. There is no automated contract test run, fuzzing harness, or CI workflow.

## Immediate Priorities (Weeks 0-4)

1. **Make QUIC adapter production-ready**
   - Implement listener `accept` and `ping`, wire TLS config, and exercise real request/response flows using the SPI.
   - Add integration tests that spin up `Server` + QUIC transport and perform unary + streaming RPCs.
2. **Reconcile legacy and modular APIs**
   - Decide whether to keep `src/root.zig` as a facade or deprecate it.
   - Update or remove `service.zig` streaming stubs that currently return `Error.NotImplemented`.
   - Ensure documentation and examples import `zrpc-core` + explicit transport modules.
3. **Truth-align the docs and TODO**
   - Trim or mark speculative features as "planned" rather than "complete" in `README.md` and `TODO.md`.
   - Refresh `docs/guides/getting-started.md` to match the new API surface.
4. **Instrumentation integration**
   - Thread `logging`, `metrics`, and `tracing` through `Client` and `Server`, and expose configuration knobs in their configs.
   - Add a simple `/metrics` example wiring `MetricsServer` so the Prometheus endpoint is validated.

## Near-Term Roadmap (Weeks 5-12)

- **Transport portfolio**
  - Finish HTTP/2 adapter against the new SPI, including ALPN negotiation and flow control.
  - Stub HTTP/3 adapter on top of the matured QUIC transport.
  - Validate WebSocket adapter with a browser-compatible handshake and optional TLS (wss) support.
- **Developer tooling**
  - Stand-up a minimal `zrpc` CLI with `call`, `list`, and `gen` commands using the existing proto parser/codegen.
  - Ship contract-test binaries that adapters can run (QUIC + mock) and integrate into CI.
- **Async & backpressure**
  - Complete the zsync executor path for the server, ensuring per-connection tasks honour semaphores and deadlines.
  - Implement flow-control-aware streaming APIs in both client and server.
- **Testing & quality gates**
  - Introduce fuzzing for frame parsing (transport + codecs) and enable sanitizers in CI.
  - Add benchmarks that validate latency/throughput claims and fail on regressions.

## Medium-Term Initiatives (2026 H1)

- **Security hardening** – mTLS, API keys, rate limiting, and secrets management layered on top of the stabilized core.
- **Plugin/IPC story** – Unix domain sockets and shared memory transports targeted at `ghostshell`/`gsh` use cases.
- **AI-focused extensions** – Provider abstraction layer, context streaming, and cost tracking once streaming is stable.
- **Packaging & distribution** – Automated releases, package index publication, Docker images, and first-class CI workflows.

## Supporting Actions

- Establish a living design document that tracks SPI changes and adapter contracts.
- Create a "status matrix" document that clearly indicates which transports/features are **Available**, **In Progress**, or **Planned**.
- Stand up nightly CI runs (GitHub Actions) for linting, tests, and contract compliance across supported Zig versions.
- Maintain changelog discipline to avoid vNext marketing overshoot.

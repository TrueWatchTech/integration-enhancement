# Go `log/slog` Trace–Log Correlation Guide · TrueWatch

Scope: for applications using the Go standard library `log/slog`, enabling logs to automatically carry the TraceID and correlate with TrueWatch APM traces. This guide covers only TraceID injection on the logging side; it does not cover base ddtrace setup.

---

## 1. Prerequisites

1. The application is already instrumented with `dd-trace-go` (ddtrace), and trace data is reported to TrueWatch (collected via DataKit).
2. Unified Service Tagging (UST) is configured at runtime: `DD_ENV`, `DD_SERVICE`, `DD_VERSION`.

---

## 2. How it works

Log–trace correlation relies on extracting the active span from the `context` at log time and writing its trace/span identifiers into that log record. This yields a single hard requirement:

**Every log call must receive a `ctx` that carries the span.**

- Context-aware methods (`InfoContext(ctx, …)`): the span is available, and the log is injected with `dd.trace_id` and related fields.
- Non-context methods (`slog.Info(…)`): no span is available, and the log carries no TraceID.

This requirement is independent of the integration method and cannot be omitted.

---

## 3. Integration methods

### Option 1: Orchestrion (compile-time wiring)

Orchestrion injects the slog correlation logic at compile time; no handler-wrapping code is written in the source. Changes are concentrated in the build pipeline.

1. Install (ensure `$(go env GOBIN)` or `$(go env GOPATH)/bin` is on `PATH`):

   ```sh
   go install github.com/DataDog/orchestrion@latest
   ```

2. Register into the project (updates `go.mod`/`go.sum`, generates `orchestrion.tool.go` including the slog integration):

   ```sh
   orchestrion pin
   ```

3. Commit the managed files (skip if integrating directly in CI/CD):

   ```sh
   git add go.mod go.sum orchestrion.tool.go
   git commit -m "chore: enable orchestrion"
   ```

4. Build via Orchestrion (choose one; replace `go build` in CI/Dockerfile):

   ```sh
   orchestrion go build .
   # or
   go build -toolexec="orchestrion toolexec" .
   # or
   export GOFLAGS="${GOFLAGS} '-toolexec=orchestrion toolexec'"
   go build .
   ```

Handled automatically: handler wrapping (`NewJSONHandler`/`WrapHandler` from Option 2).
Still required: the ctx refactor in Section 4.

### Option 2: Manual wiring (no build changes)

Wrap a trace-aware slog handler in code. Choose one.

New logger — `NewJSONHandler` (returns a `*slog.JSONHandler` already enhanced with tracing information):

```go
import (
    "log/slog"
    "os"

    slogtrace "github.com/DataDog/dd-trace-go/contrib/log/slog/v2"
)

logger := slog.New(slogtrace.NewJSONHandler(os.Stdout, nil))
```

Wrap an existing handler — `WrapHandler` (attaches tracing information to an existing handler, preserving its configuration):

```go
myHandler := slog.NewJSONHandler(os.Stdout, nil)
logger := slog.New(slogtrace.WrapHandler(myHandler))
```

`slogtrace.IsAlreadyWrapped(h)` checks whether a handler is already wrapped, to avoid double wrapping (e.g. repeated `slog.SetDefault`).

Still required: the ctx refactor in Section 4.

---

## 4. The ctx refactor

Convert log calls to their context-aware form, passing a `ctx` that carries the current span:

Before (no span, no TraceID):

```go
slog.Info("processing order", "order_id", id)
```

After (with ctx, TraceID present):

```go
span, ctx := tracer.StartSpanFromContext(ctx, "process.order")
defer span.Finish()

logger.InfoContext(ctx, "processing order", "order_id", id)
// equivalent: logger.Log(ctx, slog.LevelInfo, "processing order", "order_id", id)
```

### Engineering workflow for large-scale migration

For existing projects with many `slog.Info/Warn/Error/Debug` calls, plain-text `sed` replacement is discouraged (it damages strings/comments and cannot guarantee `ctx` is in scope). Use AST-based rewriting with the compiler as a safety net — four steps:

**1. Inventory the call sites**

```sh
rg -n --stats 'slog\.(Info|Warn|Error|Debug)\(' .
```

Assess distribution and total count to estimate scope and blast radius.

**2. Rewrite via AST**

Use a syntax-tree refactoring tool to avoid text-level damage. `gopatch` (`github.com/uber-go/gopatch`) natively supports variadic `...`:

```
# slog2ctx.patch
@@
@@
-slog.Info(...)
+slog.InfoContext(ctx, ...)
```

```sh
gopatch -p slog2ctx.patch ./...
```

Add one rule per method for `Warn/Error/Debug`. Alternatives: `gofmt -r` rewrite rules, `golang.org/x/tools/cmd/eg`.

**3. Compiler safety net — pinpoint calls missing ctx**

After rewriting:

```sh
go build ./...
```

`gopatch` cannot conjure a `ctx`; any call site without `ctx` in scope produces an `undefined: ctx` compile error. The compiler's error list is the precise set of sites needing manual ctx propagation — thread `ctx` down the call chain for each. This step guarantees correctness: there are no silent incorrect replacements.

**4. Lint to prevent regression**

Add a static check in CI (e.g. a `forbidigo` rule) that forbids bare `slog.Info/Warn/Error/Debug` and enforces the `*Context` variants, preventing new code from breaking correlation.

Call sites that already have `ctx` in scope are fully handled by Step 2; those missing `ctx` are surfaced by Step 3 and require manual propagation. Overall effort depends on the number of gaps surfaced in Step 3.

---

## 5. Choosing between the two methods

| Criterion | Option 1: Orchestrion | Option 2: Manual wiring |
|---|---|---|
| Handler wiring | Automatic (0 lines) | 1 line by hand |
| Build pipeline | Must change (swap build command in CI/Dockerfile) | Unchanged |
| Added files | `go.mod`/`go.sum` + `orchestrion.tool.go` | None |
| <span style="color:red">**ctx refactor**</span> | <span style="color:red">**Required**</span> | <span style="color:red">**Required**</span> |
| Bonus coverage | Also auto-instruments frameworks/dependencies/stdlib, broader trace coverage | Log correlation only |

Guidance:

- Able to adjust CI/build image → Option 1, gaining full auto-instrumentation with minimal source changes.
- Cannot change the build → Option 2, one line of wiring.
- The primary effort for both is the ctx refactor in Section 4; run Step 1 (inventory) before choosing, and decide based on the gap size.

---

## Appendix: Official references

- slog integration API (`NewJSONHandler`/`WrapHandler`): `https://pkg.go.dev/github.com/DataDog/dd-trace-go/contrib/log/slog/v2`
- Correlating Go Logs and Traces: `https://docs.datadoghq.com/tracing/other_telemetry/connect_logs_and_traces/go/`
- Compile-time instrumentation (Orchestrion): `https://docs.datadoghq.com/tracing/trace_collection/automatic_instrumentation/dd_libraries/go/`
- Orchestrion default integration list (includes slog): `https://github.com/DataDog/dd-trace-go/blob/main/orchestrion/all/orchestrion.tool.go`



# OpenTelemetry Go Observability Practices: SQLCommenter and Trace–Log Correlation

This document is organized into three chapters and can be read selectively as needed:

- **Chapter 1** explains how to inject trace context into SQL and correlate it with PostgreSQL slow query logs. Suitable for scenarios focused solely on database slow-query troubleshooting.
- **Chapter 2** explains how to inject trace identifiers into Go application logs, enabling correlated analysis between APM and application logs.
- **Chapter 3** builds on the foundations of the first two chapters to present a combined injection approach, suitable when both capabilities need to be delivered together.

---

## Chapter 1: Correlating SQLCommenter Traces with PostgreSQL Slow Query Logs

### 1.1 Architecture Overview

In a distributed architecture, the database server runs independently and by default has no awareness of the application-layer distributed trace. To bridge this information gap, **SQL Comment Propagation** can be used: before the application-layer database driver executes a SQL statement, the instrumentation component appends the currently active trace context to the statement as a non-executing block comment. This mechanism originates from the **SQLCommenter** specification open-sourced by Google; the `traceparent` value carried in the comment follows the **W3C Trace Context** standard format.

```text
[App / ORM] --inject traceparent into SQL string--> [PostgreSQL engine] --exceeds threshold--> slow query log
```

**Context transformation example**

Original SQL statement:

```sql
SELECT * FROM orders WHERE user_id = 1001;
```

SQL statement actually sent to the database after trace information is injected:

```sql
SELECT * FROM orders WHERE user_id = 1001 /*traceparent='00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01'*/;
```

> **On SQLCommenter support in the Go ecosystem**
> SQLCommenter began as a standalone open-source project, and its specification has since been adopted by the OpenTelemetry community ecosystem. In Go, the `database/sql` instrumentation library `github.com/XSAM/otelsql` integrates this capability, and SQL comment injection can be explicitly enabled via a configuration option; the `traceparent` field within the comment follows the W3C Trace Context format. Note that SQLCommenter itself is a community specification, not a W3C standard.

---

### 1.2 Application-Layer Implementation

#### Option A: Standard `database/sql` and ORMs Built on It (using `otelsql`)

Applicable to the standard library `database/sql`, as well as ORM frameworks built on top of it (e.g., GORM, XORM, Ent).

Add the dependency:

```bash
go get github.com/XSAM/otelsql
```

Code integration:

```go
package main

import (
	"database/sql"
	"time"

	_ "github.com/lib/pq" // register the underlying postgres driver
	"github.com/XSAM/otelsql"
	semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
)

// InitializeDatabase initializes the database connection and enables SQLCommenter
func InitializeDatabase(dsn string) (*sql.DB, error) {
	db, err := otelsql.Open("postgres", dsn,
		otelsql.WithAttributes(semconv.DBSystemPostgreSQL),
		otelsql.WithSQLCommenter(true), // enable SQL comment injection
	)
	if err != nil {
		return nil, err
	}

	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(25)
	db.SetConnMaxLifetime(5 * time.Minute)

	return db, nil
}
```

#### Option B: High-Performance `pgx` Driver Ecosystem

One key point must be clarified first: the native tracing library for `github.com/jackc/pgx/v5`, namely `github.com/exaring/otelpgx`, only produces OpenTelemetry spans and metrics — **it does not write trace context into the SQL text**. Therefore, relying on otelpgx alone cannot make `traceparent` appear in PostgreSQL slow query logs.

To achieve this chapter's goal in a pgx-based project (getting the comment into slow logs), the recommended approach is to access pgx through the `database/sql` interface and let `otelsql` perform the comment injection uniformly:

Add the dependencies:

```bash
go get github.com/jackc/pgx/v5
go get github.com/XSAM/otelsql
```

Code integration:

```go
package main

import (
	"database/sql"

	_ "github.com/jackc/pgx/v5/stdlib" // expose pgx via the database/sql interface; driver name is "pgx"
	"github.com/XSAM/otelsql"
	semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
)

// InitializePgxViaSQL connects to pgx through the database/sql interface, with otelsql injecting the SQL comment
func InitializePgxViaSQL(dsn string) (*sql.DB, error) {
	return otelsql.Open("pgx", dsn,
		otelsql.WithAttributes(semconv.DBSystemPostgreSQL),
		otelsql.WithSQLCommenter(true),
	)
}
```

If the project needs to continue using the native `pgxpool` connection pool, otelpgx can be layered on to obtain span-level tracing and metrics (complementary to, but not a replacement for, slow-log comments). The correct way to set it up is to assign the Tracer to the connection configuration:

```go
config, err := pgxpool.ParseConfig(dsn)
if err != nil {
	return nil, err
}
config.ConnConfig.Tracer = otelpgx.NewTracer(
	otelpgx.WithIncludeQueryParameters(),
)
pool, err := pgxpool.NewWithConfig(ctx, config)
```

---

### 1.3 PostgreSQL Server-Side Slow Query Configuration

To ensure PostgreSQL records the commented SQL when a query exceeds the threshold, adjust the following parameter in the target instance's `postgresql.conf`:

```ini
# Log all statements that take longer than 200 milliseconds to execute
log_min_duration_statement = 200
```

> **No additional server-side plugin required.** This approach is agentless on the database server side: PostgreSQL preserves the full SQL string (including the block comment), so `traceparent` can be seen in the slow query log without installing any third-party database plugin.

---

## Chapter 2: Correlated Analysis Between OpenTelemetry APM and Go Application Logs

### 2.1 Why "Zero-Code Automatic Injection" Is Difficult in Go

In some language ecosystems (such as Java and Node.js), runtime probes or bytecode enhancement can automatically inject trace identifiers into logs without modifying business code. **Go differs fundamentally in this respect.**

Go is a statically compiled language and lacks a runtime bytecode-modification mechanism. As a result, "context-aware injection" for a logging library requires explicitly configuring a Handler/Core interceptor during initialization. This is a one-time initialization task; once configured, the business layer does not need to be aware of it at each call site.

---

### 2.2 Application Logging Component Integration

#### Option A: Standard Library Structured Logging `slog` (Go 1.21+)

Implement a lightweight custom `slog.Handler` that extracts trace identifiers from the `context` when writing logs. Note that `WithAttrs` and `WithGroup` must also be implemented, so that derived loggers (created via `With(...)`) retain the injection capability:

```go
package main

import (
	"context"
	"log/slog"
	"os"

	"go.opentelemetry.io/otel/trace"
)

// OTelLogHandler injects trace metadata into log records
type OTelLogHandler struct {
	slog.Handler
}

func NewOTelLogHandler(next slog.Handler) *OTelLogHandler {
	return &OTelLogHandler{Handler: next}
}

func (h *OTelLogHandler) Handle(ctx context.Context, r slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r.AddAttrs(
			slog.String("trace_id", sc.TraceID().String()),
			slog.String("span_id", sc.SpanID().String()),
		)
	}
	return h.Handler.Handle(ctx, r)
}

func (h *OTelLogHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &OTelLogHandler{Handler: h.Handler.WithAttrs(attrs)}
}

func (h *OTelLogHandler) WithGroup(name string) slog.Handler {
	return &OTelLogHandler{Handler: h.Handler.WithGroup(name)}
}

func InitLogger() {
	base := slog.NewJSONHandler(os.Stdout, nil)
	slog.SetDefault(slog.New(NewOTelLogHandler(base)))
}
```

#### Option B: A Commonly Used Logging Library `zap` (using `otelzap`)

For projects based on Uber's `zap`, the `otelzap` extension package can be introduced. Note: otelzap's default behavior is to associate logs with the span. **To carry `trace_id` in the structured log output, `WithTraceIDField` must be explicitly enabled.**

Add the dependency:

```bash
go get github.com/uptrace/opentelemetry-go-extra/otelzap
```

Code integration:

```go
package main

import (
	"github.com/uptrace/opentelemetry-go-extra/otelzap"
	"go.uber.org/zap"
)

var logger *otelzap.Logger

func InitZapLogger() {
	zapLogger := zap.Must(zap.NewProduction()) // JSON encoding by default
	logger = otelzap.New(zapLogger,
		otelzap.WithTraceIDField(true), // write trace_id into the structured log
	)
}
```

> When using the zap path, logs must be written via the context-aware methods (e.g., `logger.Ctx(ctx).Info(...)`) to carry trace identifiers; the `trace_id` field is injected by `WithTraceIDField(true)`.

---

### 2.3 Correlated Output

Once configured, passing `context` when logging (e.g., `slog.InfoContext(ctx, ...)`) causes the output JSON log to automatically carry the trace identifiers:

```json
{
  "time": "2026-06-26T10:00:00Z",
  "level": "INFO",
  "msg": "Database operation completed",
  "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
  "span_id": "00f067aa0ba902b7",
  "user_id": "1001"
}
```

---

## Chapter 3: Architecture Integration Recommendation — Delivering Both Capabilities at Once via Context Propagation

Comparing the two monitoring needs from the previous chapters (database slow-query correlation and application-log correlation) reveals that their underlying implementations share a technical intersection. Therefore, when modifying the application, an integrated, unified approach is worth considering rather than splitting the work into two independent efforts.

### 3.1 The Core Technical Link: `context.Context`

Whether SQLCommenter injects trace comments into the database or the logging component injects trace identifiers into log lines, both draw their data from the same object: the `context.Context` propagated layer by layer through business logic.

| Monitoring need | Data source | Key prerequisite |
| --- | --- | --- |
| Chapter 1: SQLCommenter (PG slow query) | SpanContext within `ctx` | Must use context-aware methods such as `QueryContext` / `ExecContext` |
| Chapter 2: APM-Log (log correlation) | SpanContext within `ctx` | Must use context-aware methods such as `InfoContext` |

This means that if the two tasks are split into two separate efforts, the same business code blocks would need to undergo two rounds of repeated review and intrusive modification.

---

### 3.2 Integration Example (One Modification, Both Capabilities)

After configuring the Chapter 1 database driver wrapper and the Chapter 2 logging interceptor during global initialization, the business layer only needs to maintain proper Context propagation to satisfy both kinds of injection simultaneously:

```go
package main

import (
	"context"
	"database/sql"
	"log/slog"
)

// BusinessWorkflow: the business layer only needs to maintain good Context propagation habits
func BusinessWorkflow(ctx context.Context, db *sql.DB) {
	// Synergy 1: the logging interceptor automatically extracts the TraceID from ctx and writes it into the log
	slog.InfoContext(ctx, "Starting order status verification", "order_id", "8899")

	// Synergy 2: otelsql extracts the TraceID from the same ctx and sends it to PG as a comment alongside the SQL
	if _, err := db.ExecContext(ctx, "UPDATE orders SET verified = true WHERE id = $1", "8899"); err != nil {
		slog.ErrorContext(ctx, "Failed to update order in database", "error", err)
		return
	}

	slog.InfoContext(ctx, "Workflow completed successfully")
}
```

### 3.3 Conclusions and Recommended Actions

- **Avoid fragmented modifications**: Implementing the two separately compounds communication cost, testing cost, and code-change risk.
- **Drive it as a one-time, dedicated effort**: Configure the logging middleware and database driver wrapper during global initialization; thereafter the business layer only needs to follow Go's standard Context-propagation conventions.
- **End result**: At a relatively small code-modification cost, gain end-to-end tracing that connects code, logs, and database slow queries.

---

## Appendix: Modification Cost and Implementation Guidance

The modification cost of this approach falls into two categories of different natures, which should be assessed separately before planning.

### One-Time Initialization Changes (Centralized, Low Cost)

This is the work that genuinely requires "changing only one place" and is independent of codebase size:

| Change | Location | Scale |
| --- | --- | --- |
| Database init: `sql.Open` → `otelsql.Open(...)` with `WithSQLCommenter` enabled | The database initialization site, typically 1 place | A dozen or so lines |
| Logging init: install the context-aware Handler / `otelzap` | The logging initialization site, 1 place | A dozen or so lines |
| PostgreSQL server side: adjust `log_min_duration_statement` | Instance configuration, no code | 1 parameter |

### Call-Site Changes (Proportional to the Number of Call Sites)

Trace context can only be passed in explicitly at the call site via `context.Context`, so the following two kinds of calls must use the context-aware method variants:

- Database: use `ExecContext` / `QueryContext` rather than `Exec` / `Query`;
- Logging: use `InfoContext(ctx, ...)` (or the corresponding logging library's context-aware method) rather than the non-context logging calls.

Among these, the **number of log statements that need to carry trace identifiers** is the main variable in the modification effort. Logs emitted during startup and by background tasks are excluded; only business logs on the request path need to be modified.

### A Prerequisite That Significantly Lowers the Cost

If the application has already implemented OpenTelemetry tracing, then `context.Context` is already propagated layer by layer through the request path — this foundational work is already done. Given that:

- **Database slow-query correlation**: If database spans are already observable in traces, that indicates database calls are already using context-aware methods. In this case, only the initialization options and the server-side parameter need to be added, and **call sites require virtually no changes**.
- **Full log correlation**: The incremental cost is roughly equal to the number of log statements on the request path that need to be correlated. IDE-assisted bulk replacement can help, but this is a broad, surface-level change and should be assessed honestly.

### Recommended Implementation Sequence

1. **Confirm the current state first**: (1) whether database spans are observable in traces; (2) whether database calls already use context-aware methods; (3) which logging library is in use and whether `context` is already widely passed to logs.
2. **Deliver in phases**: Prioritize database slow-query correlation (low cost, quick results); treat log correlation as a second phase, and set clear effort expectations based on "the number of request-path log statements."
3. **Assess the modification scope reasonably**: Initialization changes can be completed once and centrally; the scope of log correlation grows with the number of log call sites, and should be estimated during planning based on the actual call-site scale rather than treated as a single-point change.

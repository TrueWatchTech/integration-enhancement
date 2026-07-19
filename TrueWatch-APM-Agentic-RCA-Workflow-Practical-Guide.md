# TrueWatch APM Agentic Root-Cause Analysis (RCA) Workflow — Practical Guide

This guide provides step-by-step instructions for building an **automated incident root-cause analysis (RCA) workflow** on TrueWatch Toby AI Agent Teams.

**Typical scenario**: A business service returns interface errors (non-2xx HTTP status codes) during operation, and a monitor opens an incident based on this. An AI agent periodically inspects unresolved incidents, locates a representative error trace based on the affected service and time range, queries the corresponding logs from a log platform (this guide uses Tencent Cloud Log Service — CLS — as the example) by TraceID, combines the APM trace with the error information in the logs to produce a root-cause conclusion and remediation recommendation, and writes the conclusion back to the incident. This achieves "once an incident occurs, the cause and remediation direction are visible in the incident record without any human intervention."

This guide is intended for technical readers with a background in operations and observability. It is based on the official TrueWatch English documentation, with links to the corresponding documentation provided in the relevant sections. Commands, endpoints, and configurations shown are examples; replace placeholders such as `<service>`, `<site>`, `<region>`, and `<topic-id>` with actual values.

---

## Table of Contents

1. Overview and Objectives
2. Architecture Overview
3. Prerequisites and Runtime Deployment
4. Deploying the Log Collection and Analysis Scripts
5. Integrating the Analysis Tools as an MCP Service
6. Configuring the Monitor (Methodology and Example for This Solution)
7. Writing the RCA Skill
8. Configuring the Unattended Scheduled Task
9. Triggering an Incident and Validating the Workflow
- Appendix A: Scripts, Tools, and Endpoints
- Appendix B: Script Source Code
- Appendix C: Reference Links

---

## 1. Overview and Objectives

Traditional alerting can only indicate "where something went wrong"; identifying the root cause still requires a human to switch back and forth between traces, logs, and metrics. This workflow delegates this correlation and analysis work to an AI agent:

- **Automated inspection**: Periodically checks for newly created, unresolved incidents.
- **Automated correlation**: Locates a representative error trace based on the service and time range involved in the incident, and retrieves the corresponding logs by TraceID.
- **Automated analysis**: Combines the trace and logs to produce a root-cause conclusion and remediation recommendation.
- **Persisted conclusions**: Writes the analysis result back to the incident's comment section, so the responder sees the cause and remediation direction as soon as they open the incident.

## 2. Architecture Overview

```
[APM data from the monitored service]
        │  Anomaly (e.g., non-2xx HTTP status)
        ▼
   Monitor + alert policy ──►  Incident (the entry point where the responder views conclusions)
                                   ▲
                                   │ Write back root cause and recommendation
   Scheduled task (unattended) triggers the AI agent │
        │                          │
        ├─ Locate error trace: obtain a representative TraceID
        ├─ Fetch logs: retrieve logs from the log platform by TraceID
        └─ Root-cause analysis: combine trace and logs to reach a conclusion ──────┘
```

Components: the agent and its self-hosted runtime, the monitor and alert policy, analysis capabilities (OWL MCP for reading observability data + the analysis tool packaged in this solution), the scheduled task, and the incident as the carrier of the conclusion.

## 3. Prerequisites and Runtime Deployment

Before starting, confirm the following:

- A TrueWatch account and workspace, with the account holding the Administrator or Workspace Owner role required to create agents.
- A TrueWatch API Key whose Open API permissions cover the operations required below (in particular, **incident comment write** permission, used to write conclusions back).
- A Linux host to deploy the runtime on (a virtual machine may be used for local testing).
- The monitored service is already reporting APM trace data; the logs required for analysis are accessible via the log platform's API.

Installation of the agent runtime is not covered in this guide; refer to the published deployment guide:

> Agent deployment guide: https://github.com/TrueWatchTech/integration-enhancement/blob/main/TrueWatch-Toby-AI-Agent-Teams-Practical-Configuration-Guide.md

Choose one of the following based on your situation:

- **Fresh deployment**: If the host has no runtime yet, complete "obtain the installation command → run it on the host → confirm it is online" per the deployment guide, then continue to Chapter 4.
- **Reuse an existing runtime**: On a host that already has a runtime deployed, after creating this workflow's agent in the target workspace, run **that agent's installation command** (generated by the platform). This command rewrites the runtime configuration with that agent's credentials and connects it to the agent, without needing to manually edit configuration files item by item; afterward, confirm the agent is online in the console.

When creating the agent, it is recommended that the **Identity** definition remain generic and not hard-code a specific service name — the service name and time range should always be taken from the incident/task input, to avoid fixed information in the identity interfering with judgment of the analysis target. Reference identity definition:

```
You are an APM fault root-cause analysis assistant for observability/SRE workflows. When a task references a specific incident or service, always take the service name and time window from that incident/task input — never assume a fixed service name. Output concise, structured conclusions: root cause, key evidence (trace/logs), and remediation suggestions.
```

## 4. Deploying the Log Collection and Analysis Scripts

This solution ships with two scripts (source code in Appendix B): `cls_query_by_trace.py` (queries the log platform by TraceID) and `cls_mcp_server.py` (an MCP service that exposes the analysis tools to the agent). Both are deployed on the runtime host.

> Key prerequisite: the runtime runs as the local user `beak-agent`. The scripts, dependencies, and credential file must be placed somewhere this user can read/execute — **do not place them in a personal home directory** (default permissions would block `beak-agent` from accessing them). This guide uniformly uses `/opt/rca`, and places credentials in `/etc/beak-agent`.

**Step 1: Place the scripts**

Save the two scripts from Appendix B into `/opt/rca`:

```bash
sudo mkdir -p /opt/rca
# Place cls_query_by_trace.py and cls_mcp_server.py into /opt/rca
sudo chmod -R a+rX /opt/rca
```

**Step 2: Install dependencies**

For a typical Linux environment, install directly:

```bash
sudo python3 -m pip install "mcp[cli]" tencentcloud-sdk-python
```

> **If you get `externally-managed-environment`**: newer distributions (e.g., Debian 12+ / Ubuntu 23.04+) prohibit installing directly into the system Python per PEP 668. In this case, use a virtual environment instead:
>
> ```bash
> sudo apt install -y python3-venv     # if venv is missing
> sudo python3 -m venv /opt/rca/venv
> sudo /opt/rca/venv/bin/pip install "mcp[cli]" tencentcloud-sdk-python
> sudo chmod -R a+rX /opt/rca
> ```

> Note the absolute path of the "Python interpreter with dependencies installed" — it is needed for the MCP configuration in Chapter 5: for a system install it is `python3` (e.g., `/usr/bin/python3`); for a virtual-environment install it is `/opt/rca/venv/bin/python`. The examples below use the latter.

**Step 3: Configure credentials (restricted file)**

Write the credentials into `/etc/beak-agent/cls.env` (readable only on this host, and never entered into any platform configuration):

```bash
sudo tee /etc/beak-agent/cls.env >/dev/null <<'EOF'
CLS_MCP_TRANSPORT=stdio
TENCENT_SECRET_ID=<log platform SecretId>
TENCENT_SECRET_KEY=<log platform SecretKey>
CLS_REGION=<region>
CLS_TOPIC_ID=<topic-id>
TW_API_KEY=<TrueWatch API Key, must have incident comment write permission>
TW_OPENAPI_URL=https://<site>-openapi.truewatch.com/api/v1/df/query_data_v1
TW_OPENAPI_BASE=https://<site>-openapi.truewatch.com
EOF
sudo chown beak-agent:beak-agent /etc/beak-agent/cls.env
sudo chmod 600 /etc/beak-agent/cls.env
```

**Step 4: Self-test the three tools as the runtime user**

Before wiring this up formally, confirm that credentials, network access, and the APIs all work (run as the `beak-agent` user, simulating the real runtime environment):

```bash
cd /opt/rca
# 1) Locate an error trace (returns trace_id)
sudo -u beak-agent bash -c 'set -a; . /etc/beak-agent/cls.env; set +a; /opt/rca/venv/bin/python - <<PY
import cls_mcp_server as m
print(m.find_error_trace_id("<service>"))
PY'
# 2) Fetch logs by trace_id (replace with the trace_id returned in the previous step)
sudo -u beak-agent bash -c 'set -a; . /etc/beak-agent/cls.env; set +a; /opt/rca/venv/bin/python /opt/rca/cls_query_by_trace.py <trace_id> --minutes 60'
# 3) Write an incident comment (replace with a real incident_uuid; this will write a test comment)
sudo -u beak-agent bash -c 'set -a; . /etc/beak-agent/cls.env; set +a; /opt/rca/venv/bin/python - <<PY
import cls_mcp_server as m
print(m.add_incident_comment("<incident_uuid>", "connectivity test"))
PY'
```

The three steps should return a trace_id, log records, and `success: True` respectively, indicating that the scripts and APIs are ready.

## 5. Integrating the Analysis Tools as an MCP Service

### 5.1 Why package these as an MCP service instead of running the scripts directly

During reasoning, an agent can only invoke external capabilities through tools (MCP) — it **cannot directly execute local scripts on the host**. Therefore, to let the agent use the capabilities the scripts provide during analysis (locating traces, fetching logs, writing back conclusions), they must be packaged as MCP tools and exposed, so the agent can call them.

Furthermore, packaging steps such as querying and writing as **tools with well-defined parameters and deterministic behavior** allows the agent to express only "what to do," while the tool guarantees the correctness of "how to do it" — significantly improving reliability and reproducibility. This is the key to turning a one-off validation into a workflow that runs stably over the long term.

### 5.2 Two integration methods

A self-built MCP service can use one of two transport methods, and the choice depends on network and security requirements:

| Transport | Connection initiator | Network requirement | Applicable scenario |
|---|---|---|---|
| `streamableHttp` (HTTP endpoint) | Initiated by the TrueWatch platform side | The endpoint must be reachable from the platform's network (public internet or tunnel); localhost/internal networks are not reachable | Capabilities that already provide an externally facing service (e.g., the official OWL MCP) |
| `stdio` (local command) | The self-hosted runtime spawns a subprocess locally | No network exposure required, only local file permissions | Self-built, internal-network, or sensitive capabilities |

> For self-built capabilities that a customer does not want exposed externally, **stdio** is recommended: the runtime spawns it locally on its own host, without ever listening on a port or requiring public reachability. The analysis tool in this solution is integrated via stdio; the official OWL MCP is a publicly hosted endpoint and uses streamableHttp.
>
> **General applicability**: this method of "registering and integrating an MCP service" applies to integrating **any third-party service that conforms to the MCP protocol** — externally reachable services use `streamableHttp`, and internal/private services use `stdio`. The integration process for this solution's analysis tool can serve as a general pattern for third-party MCP integration.

### 5.3 Registration and enablement

This workflow requires registering two MCP services.

**Step 1: Global registration (Settings Center → MCP Services → Add MCP Service)**

Paste each of the following configurations and save:

- Analysis tool (stdio; use the interpreter path noted in Chapter 4 for `command`):

  ```json
  {
    "mcpServers": {
      "cls-logs": {
        "command": "/opt/rca/venv/bin/python",
        "args": ["/opt/rca/cls_mcp_server.py"],
        "transport": "stdio",
        "env": { "CLS_ENV_FILE": "/etc/beak-agent/cls.env" }
      }
    }
  }
  ```

- OWL MCP (streamableHttp, used to read incidents):

  ```json
  {
    "mcpServers": {
      "owl": {
        "url": "https://<site>-owl-mcp.truewatch.com/mcp",
        "transport": "streamableHttp",
        "headers": { "Authorization": "Bearer <TrueWatch API Key>" }
      }
    }
  }
  ```

**Step 2: Enable on the agent**

Go to this workflow agent's **Workbench → MCP Services**, and enable both `cls-logs` and `owl`.

> Note: it is normal for the stdio service to not show a status or tool count on the global MCP services list page (it is spawned locally by the runtime, and tools are discovered, at session time). If the script is later updated or new tools are added, restart the runtime so it re-discovers them: `sudo systemctl restart beak-agent`.

> Official documentation: [MCP Services Configuration](https://docs.truewatch.com/toby-agent-teams/mcp-services/), [OWL MCP Quickstart](https://docs.truewatch.com/owl/mcp-quickstart/)

## 6. Configuring the Monitor (Methodology and Example for This Solution)

Monitor design varies by objective. This guide does not prescribe "how a given class of monitor should be designed"; instead, it first presents a general methodology, then gives concrete steps using this solution as an example.

### 6.1 General configuration methodology

1. **Clarify the monitoring objective and target**: what problem to detect, and which data domain and objects to watch.
2. **Choose the detection type and data scope.**
3. **Define the detection metric and filter conditions**: how to quantify an "anomaly," and narrow the scope with filters.
4. **Choose the detection dimension(s)**: use low-cardinality fields that can localize the problem (e.g., service, endpoint); avoid using high-cardinality fields as dimensions, as this produces an enormous number of groups and can trigger alert storms.
5. **Set the trigger condition and severity level.**
6. **Configure event notification and incident association**: whether to open an incident.
7. **Configure the alert policy and notification targets.**

> A general point to understand: monitors are mostly **aggregate detections** — the event carries grouping dimensions and statistical values, and typically does not carry the identifier of a single detailed record (such as a specific TraceID). This is an inherent characteristic of aggregation. When detail is needed, a downstream process should use the event's dimensions and time range to locate it in the raw data — in this solution, the AI performs exactly this during the analysis stage.

### 6.2 Example for this solution (concrete steps)

Objective: detect interface errors (non-2xx HTTP status, covering 4xx/5xx) for the target service, and open an incident once the threshold is reached.

Go to **Monitoring → Monitors → New Monitor → Custom Rule → APM Detection**, and configure as follows:

1. **Detection frequency / interval**: e.g., frequency `5m`, interval `15m` (interval ≥ frequency, and matching the data reporting cycle).
2. **Detection metric**: choose Trace statistics, sourced from the trace data source.
3. **Filter condition**: `http_status_code` not equal to `200` (covering 4xx/5xx); if you only care about a specific service, add a corresponding `service` filter condition.
4. **Detection dimension**: choose `service` (add `resource` for finer granularity if needed); **do not choose `trace_id`** (its high cardinality would trigger an alert storm).
5. **Trigger condition**: set a threshold, e.g., trigger once 2 records are reached (for demonstration; adjust in production and combine with "consecutive-trigger judgment" to reduce noise).
6. **Event notification**: fill in the event title and content, and **enable "Associate Incident" so an incident is opened when triggered**.
7. **Alert configuration**: select the alert policy and notification targets.
8. Save and enable.

> Official documentation: [APM Detection](https://docs.truewatch.com/monitoring/monitor/application-performance-detection/), [Monitor Overview](https://docs.truewatch.com/monitoring/monitor/)

## 7. Writing the RCA Skill

First, it is worth clarifying a common misconception: "If AI is already being used, why is a Skill still needed? Does that mean the AI isn't smart enough on its own?" — this is not the case. **Toby AI does not depend on prompts or Skills to function; it has autonomous reasoning capability of its own and can independently complete incident analysis.** The purpose of a Skill is not to "compensate for the AI's ability," but to help the agent **quickly converge its reasoning scope** (constraining the problem and exploration space, and reducing unnecessary trial-and-error and tool round-trips), thereby reaching conclusions faster and improving the efficiency and consistency of output. At the same time, it significantly **saves token and credit consumption, preventing AI usage costs from spiraling out of control**. Therefore, preparing the necessary Skills for high-frequency, repetitive analysis scenarios is the key to continuously leveraging AI capability at a reasonable cost.

A Skill is used to codify a working method so it can be reused across multiple tasks. Once the RCA method is saved as a custom Skill, each scheduled task only needs to reference that Skill, without repeating the full process in every task; the analysis process also becomes more stable, consistent, and reproducible as a result.

It should be emphasized that "an AI agent equipped with a Skill" is fundamentally different from a "traditional, formula-driven/rule-based analysis robot" — a Skill only constrains scope, it does not replace reasoning:

| Dimension | Rule/script-based automation | AI agent equipped with a Skill |
|---|---|---|
| Processing logic | Executes only pre-coded, fixed steps | Reasons autonomously and adapts as needed, within the method and boundaries given by the Skill |
| Unexpected situations | Interrupts if not covered | Responds flexibly based on context (e.g., still produces a trace-based analysis when no logs are available) |
| Data understanding | Matches fields against rules | Semantically understands traces and logs, and infers the root cause |
| Output | Fixed template | Natural-language root-cause conclusion and targeted recommendations |
| Role of the Skill/prompt | Is the entirety of the logic itself | Only constrains scope and improves efficiency and consistency; reasoning is still performed by the AI |

Skills follow a "configure globally in the Settings Center first, then enable on the specific agent" pattern.

### 7.1 General methodology for writing a Skill

A reliable Skill's method content should cover at least the following elements:

- **Objective and applicable scenario**: what problem this Skill solves, and under what kind of task it should be used (this also determines how the Skill's "description" should be written, since the agent uses it to judge when to invoke the Skill).
- **Available tools and usage conventions**: explicitly list which tools should be used, how to use them, and any restrictions (e.g., use only the listed tools, do not fabricate tool names, avoid pointlessly re-listing the tool catalog repeatedly).
- **Processing steps**: clear, ordered execution steps.
- **Input sources**: where the parameters for each step come from (e.g., the service name and time range should come from the incident, not a fixed assumption).
- **Output requirements and format**: what the conclusion should contain, what format it should use, and what evidence is required (e.g., quoting key log lines).
- **Boundaries and exceptions**: which objects to skip, how to deduplicate, what to do when there is no data or a failure occurs, and what explicitly not to do.

**How to derive the method content**: start from the scenario, and make explicit "what a human would do when troubleshooting" — clarify what the input is, what data is needed, how to correlate it, and what the final output is, then transcribe each of these into the elements above. Toby AI can also be used to draft an initial version: describe the scenario, the available tools, and the expected output, have it generate a draft method, and then manually revise and converge it.

### 7.2 Creating the Skill (Settings Center → Skills → New Skill)

Fill in the following (field names as they actually appear in the console):

- **Name**: e.g., `APM RCA Analysis`.
- **Description**: must be filled in. The agent uses the description to judge when to invoke this Skill; a missing description means it cannot be triggered automatically. For example: inspect unresolved incidents, locate the error trace and fetch logs by TraceID, combine the trace and logs to produce a root cause and remediation recommendation, and write it back to the incident's comment section.
- **Method content**: enter the analysis method (see 7.3 for the example used in this solution).

### 7.3 This solution's Skill method content (example)

> **Objective**: Perform root-cause analysis on APM incidents and write the conclusion back to the incident.
>
> **Available tools** (use only the following tools; do not fabricate other tool names, and do not repeatedly re-list the tool catalog):
> - `owl.incident.list`: reads the list of incidents;
> - `find_error_trace_id(service?, from_ms?, to_ms?)`: locates one representative error trace and returns its TraceID;
> - `get_logs_by_trace_id(trace_id, from_ms?, to_ms?)`: fetches logs by TraceID;
> - `add_incident_comment(incident_uuid, comment)`: writes the conclusion back to the incident's comment section.
>
> **Steps**:
> 1. Use `owl.incident.list` to read incidents within the specified time range whose status is **Open (unresolved)**, **skipping any that are already Resolved/Closed**. From each incident, read its unique identifier, the **service name**, and the **time range** during which it occurred.
> 2. The service name and time range should **always be taken from the incident itself** (do not use a fixed or assumed service name). Call `find_error_trace_id` to locate a representative error trace and obtain its TraceID.
> 3. Call `get_logs_by_trace_id`, using the incident's time range, to fetch logs for that TraceID (the tool automatically widens the time window when necessary).
> 4. Combine the trace and logs to produce a concise "**root cause + remediation recommendation**." **If logs were obtained, 1–3 key log lines must be quoted verbatim as evidence**, and the conclusion should state that it is based on a joint analysis of the trace and logs; if no logs were obtained, state honestly that no related logs were found, and give an analysis based on the trace and incident information instead. The conclusion must include the TraceID.
> 5. Before writing back, first check whether this incident already has an analysis comment from this agent, to **avoid duplication**; after confirming there is no duplicate, call `add_incident_comment` to write the conclusion into the incident's comment section.
> 6. Process each incident at most once; after processing one, move on to the next, and finish once all have been processed.

### 7.4 Enabling on the agent

After saving, the Skill enters the team's global skill library. Go to this workflow agent's **Workbench → Skills**, and enable the `APM RCA Analysis` Skill. Once enabled, it can be referenced in scheduled tasks (see Chapter 8).

> Official documentation: [Skills](https://docs.truewatch.com/toby-agent-teams/skills/)

## 8. Configuring the Unattended Scheduled Task

Create a task in the agent workbench's scheduled tasks section, to periodically drive the agent to execute this Skill:

1. **Create a new task**, and fill in a title (e.g., "APM Incident Root-Cause Inspection").
2. **Prompt**: since the shared Skill already exists, the task prompt should remain short and carry only the information for "this particular run." It is recommended to include four elements: **the Skill being referenced** (which Skill to use), **the execution scope and parameters** (time range, target scope, e.g., only a certain severity level or category of service), **the expected output and destination** (e.g., write the conclusion back to the incident's comment section), and **any constraints specific to this run** (if applicable). The complete analysis process belongs in the Skill and should not be repeated here. Example:

   > Use the "APM RCA Analysis" Skill to inspect unresolved incidents from the past 12 hours, perform root-cause analysis on each incident, and write the conclusion back to its comment section.

3. **Associated Skill**: select `APM RCA Analysis`.
4. **Permission Mode**: select **Full access** — this is essential for unattended operation. Under the default permission mode, tool calls require confirmation each time, which will cause the task to fail on timeout when unattended; under Full access mode, the agent can execute the relevant operations directly.
5. **Execution schedule and time**: set as needed (the finest granularity is once per day).
6. **Result push (optional)**: if proactive notification is desired, enable result push and select a message channel.
7. Save.

> Because tool calls under Full access mode execute automatically, be sure to also configure the agent's behavioral boundaries and workspace role permissions accordingly, following the principle of least privilege.

> Official documentation: [Scheduled Tasks](https://docs.truewatch.com/toby-agent-teams/scheduled-tasks/)

## 9. Triggering an Incident and Validating the Workflow

1. **Generate an anomaly**: send a request to the target service that will return a non-2xx status (for example, a request missing a required authentication header will return 401):

   ```bash
   curl -i https://<target service endpoint>
   ```

   Alternatively, use existing error data directly.

2. **Confirm the incident was opened**: wait for the monitor's detection cycle to elapse, then confirm in the **Incident** list that the corresponding incident has been opened (status: unresolved).
3. **Trigger the analysis**: wait for the scheduled task's run time, or manually execute it once from the scheduled task page.
4. **Review the conclusion**: open the incident's **comments** section and confirm that the AI-written root-cause conclusion and remediation recommendation are visible, and that the conclusion includes the TraceID and key log evidence.

## Appendix A: Scripts, Tools, and Endpoints

**Included scripts**

| File | Purpose |
|---|---|
| `cls_query_by_trace.py` | Queries logs from the log platform by TraceID (this solution connects to Tencent Cloud CLS; credentials are injected via environment variables). |
| `cls_mcp_server.py` | An MCP service (stdio) that reuses the logic of the script above and exposes the three tools listed below to the agent. |

**Exposed tools**

| Tool | Description |
|---|---|
| `find_error_trace_id(service?, from_ms?, to_ms?)` | Locates a representative error trace from APM data based on the service and time range, and returns its TraceID. Service name and time range are optional; the time window auto-widens if nothing is found. |
| `get_logs_by_trace_id(trace_id, from_ms?, to_ms?)` | Fetches logs from the log platform by TraceID; supports an absolute time window, and auto-widens when necessary to cover the moment the incident occurred. |
| `add_incident_comment(incident_uuid, comment)` | Writes the analysis conclusion into the comment section of the specified incident. |

**Environment variables (`/etc/beak-agent/cls.env`)**

`CLS_MCP_TRANSPORT`, `TENCENT_SECRET_ID`, `TENCENT_SECRET_KEY`, `CLS_REGION`, `CLS_TOPIC_ID`, `TW_API_KEY`, `TW_OPENAPI_URL`, `TW_OPENAPI_BASE` (optional: `CLS_PAD_MIN`, `CLS_WIDEN_HOURS`).

**TrueWatch endpoints relied upon**

- OWL MCP (reads incidents): `https://<site>-owl-mcp.truewatch.com/mcp`, authenticated with `Authorization: Bearer <API Key>`.
- DQL Query OpenAPI (locates error traces): `POST /api/v1/df/query_data_v1`, authenticated with header `DF-API-KEY: <API Key>`.
- Incident Comment OpenAPI (writes back conclusions): `POST /api/v1/incidents/comment/{incident_uuid}/add`, authenticated with header `DF-API-KEY: <API Key>`.

> Replace the site identifier `<site>` in the endpoints with the site of your workspace.

## Appendix B: Script Source Code

> Default values in the scripts are placeholders only; the actual configuration is governed by the environment variables in Chapter 4.

### B.1 `cls_query_by_trace.py`

```python
#!/usr/bin/env python3
"""
Query Tencent Cloud CLS logs by trace_id.

Credentials & config are read from environment variables; trace_id / time window
are parameters. Structured JSON is written to stdout; progress goes to stderr.

Environment variables:
    TENCENT_SECRET_ID    (required)  Tencent Cloud SecretId
    TENCENT_SECRET_KEY   (required)  Tencent Cloud SecretKey
    CLS_REGION           (required)  your CLS region
    CLS_TOPIC_ID         (required)  target log topic id

Usage:
    python3 cls_query_by_trace.py <TRACE_ID> [--minutes N] [--out FILE]
    python3 cls_query_by_trace.py <TRACE_ID> --from-ms <MS> --to-ms <MS>

Requires: pip install tencentcloud-sdk-python
"""
import os
import sys
import json
import time
import argparse

from tencentcloud.common import credential
from tencentcloud.common.exception.tencent_cloud_sdk_exception import TencentCloudSDKException
from tencentcloud.cls.v20201016 import cls_client, models

REGION   = os.environ.get("CLS_REGION", "")
TOPIC_ID = os.environ.get("CLS_TOPIC_ID", "")
SECRET_ID  = os.environ.get("TENCENT_SECRET_ID")
SECRET_KEY = os.environ.get("TENCENT_SECRET_KEY")

MAX_TOTAL_RECORDS = 1000
PAGE_LIMIT = 1000


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def get_cls_data(trace_id, from_ms, to_ms):
    cred = credential.Credential(SECRET_ID, SECRET_KEY)
    client = cls_client.ClsClient(cred, REGION)

    query = (f'"{trace_id}" | SELECT __CONTENT__, __TAG__.container_name, __SOURCE__, '
             f'__TAG__.pod_ip, __TAG__.pod_name, __TAG__.namespace limit 1000')

    req = models.SearchLogRequest()
    req.TopicId = TOPIC_ID
    req.Query = query
    req.From = from_ms
    req.To = to_ms
    req.UseNewAnalysis = True
    req.Limit = PAGE_LIMIT
    req.Offset = 0

    results = []
    total = 0
    while total < MAX_TOTAL_RECORDS:
        try:
            resp = client.SearchLog(req)
        except TencentCloudSDKException as e:
            msg = str(e)
            # When the trace matches no logs in the window, CLS's SQL-analysis mode
            # cannot bind the SELECT columns and raises a column-resolution QueryError
            # instead of returning an empty set. Treat that as "no records".
            if "cannot be resolved" in msg or "FailedOperation.QueryError" in msg:
                log(f"No matching logs in window (treated as 0 records): {msg}")
                break
            raise
        if not resp.AnalysisRecords:
            break
        for record_str in resp.AnalysisRecords:
            results.append(json.loads(record_str))
        total += len(resp.AnalysisRecords)
        log(f"Fetched {total} records so far...")
        if len(resp.AnalysisRecords) < req.Limit:
            break
        req.Offset += req.Limit

    log(f"Total records fetched: {len(results)}")
    return results


def parse_args():
    p = argparse.ArgumentParser(
        description="Query Tencent Cloud CLS logs by trace_id.",
        formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    p.add_argument("trace_id", help="Trace ID to search for")
    p.add_argument("--minutes", type=int, default=15,
                   help="Look back N minutes from now (default 15)")
    p.add_argument("--from-ms", type=int, default=None,
                   help="Explicit window start, 13-digit ms epoch (overrides --minutes)")
    p.add_argument("--to-ms", type=int, default=None,
                   help="Explicit window end, 13-digit ms epoch (default: now)")
    p.add_argument("--out", default=None, help="Also write the full JSON to FILE")
    return p.parse_args()


def main():
    args = parse_args()
    if not SECRET_ID or not SECRET_KEY:
        log("ERROR: set TENCENT_SECRET_ID and TENCENT_SECRET_KEY environment variables.")
        sys.exit(2)

    to_ms = args.to_ms if args.to_ms is not None else int(time.time() * 1000)
    from_ms = args.from_ms if args.from_ms is not None else to_ms - args.minutes * 60 * 1000

    log(f"Searching CLS: trace_id={args.trace_id} region={REGION} topic={TOPIC_ID} "
        f"window=[{from_ms},{to_ms}]")
    try:
        records = get_cls_data(args.trace_id, from_ms, to_ms)
    except TencentCloudSDKException as err:
        log(f"CLS Error: {err}")
        print(json.dumps({"trace_id": args.trace_id, "error": str(err), "records": []},
                         ensure_ascii=False))
        sys.exit(1)

    payload = {
        "trace_id": args.trace_id,
        "region": REGION,
        "topic_id": TOPIC_ID,
        "from_ms": from_ms,
        "to_ms": to_ms,
        "count": len(records),
        "records": records,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        log(f"Full JSON written to: {args.out}")


if __name__ == "__main__":
    main()
```

### B.2 `cls_mcp_server.py`

```python
#!/usr/bin/env python3
"""
MCP server (stdio) exposing three deterministic RCA tools to a Toby AI Agent:
  - find_error_trace_id : locate a representative error trace via TrueWatch DQL OpenAPI
  - get_logs_by_trace_id: fetch logs by trace_id from the log platform (Tencent CLS)
  - add_incident_comment: write the analysis back to a TrueWatch incident

Credentials/config are loaded from a local env file (CLS_ENV_FILE, default cls.env
next to this script), so secrets stay on the host and never enter platform config.

Dependencies: pip install "mcp[cli]" tencentcloud-sdk-python
"""
import os
import sys
import time
import json
import urllib.request
import urllib.error


def _load_env_file(path):
    """Load KEY=VALUE lines from a local file into os.environ (does not override
    already-set vars). Keeps secrets on the host, out of platform-side MCP config."""
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))
    except FileNotFoundError:
        pass


# Load config from local env file BEFORE importing the query module (reads env at import).
_ENV_FILE = os.environ.get(
    "CLS_ENV_FILE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cls.env"))
_load_env_file(_ENV_FILE)

import cls_query_by_trace as cls   # reuse the CLS query logic (env-var based)

try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    raise SystemExit('Missing dependency: pip install "mcp[cli]"')

try:
    from mcp.types import ToolAnnotations
    _ANNOTATIONS = ToolAnnotations(title="Read-only query tool", readOnlyHint=True,
                                   destructiveHint=False, idempotentHint=True, openWorldHint=True)
    _ANNOTATIONS_WRITE = ToolAnnotations(title="Add a comment to a TrueWatch incident",
                                         readOnlyHint=False, destructiveHint=False,
                                         idempotentHint=False, openWorldHint=True)
except Exception:
    _ANNOTATIONS = None
    _ANNOTATIONS_WRITE = None

# stdio (spawned locally by the self-hosted runtime; private) or streamable-http.
TRANSPORT = os.environ.get("CLS_MCP_TRANSPORT", "streamable-http")
HOST = os.environ.get("CLS_MCP_HOST", "127.0.0.1")
PORT = int(os.environ.get("CLS_MCP_PORT", "8890"))

# TrueWatch DQL query / incident OpenAPI. Auth header: DF-API-KEY.
TW_OPENAPI_URL  = os.environ.get("TW_OPENAPI_URL", "")
TW_OPENAPI_BASE = os.environ.get("TW_OPENAPI_BASE", "")
TW_API_KEY      = os.environ.get("TW_API_KEY", "")

# Log-window robustness: pad the given window; auto-widen if nothing found
# (safe because trace_id is exact/unique).
CLS_PAD_MIN = int(os.environ.get("CLS_PAD_MIN", "30"))
CLS_WIDEN_HOURS = int(os.environ.get("CLS_WIDEN_HOURS", "12"))

mcp = FastMCP("cls-logs", host=HOST, port=PORT)


def _run_dql(dql, from_ms, to_ms):
    body = json.dumps({"queries": [{"qtype": "dql",
        "query": {"q": dql, "timeRange": [int(from_ms), int(to_ms)], "limit": 50}}]}).encode("utf-8")
    req = urllib.request.Request(TW_OPENAPI_URL, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("DF-API-KEY", TW_API_KEY)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


@mcp.tool(annotations=_ANNOTATIONS)
def get_logs_by_trace_id(trace_id: str, minutes: int = 15,
                         from_ms: int = 0, to_ms: int = 0) -> dict:
    """Query logs for a given trace_id. If from_ms/to_ms (13-digit ms) are given,
    that window is used (set to the incident's occurrence time); otherwise the last
    `minutes` minutes. The window is padded, and auto-widened if nothing is found."""
    pad = CLS_PAD_MIN * 60 * 1000
    if from_ms and to_ms:
        f, t = int(from_ms) - pad, int(to_ms) + pad
        center = (int(from_ms) + int(to_ms)) // 2
    else:
        t = int(time.time() * 1000)
        f = t - minutes * 60 * 1000
        center = t
    records = cls.get_cls_data(trace_id, f, t)
    widened = False
    if not records:
        wf = center - CLS_WIDEN_HOURS * 3600 * 1000
        wt = center + CLS_WIDEN_HOURS * 3600 * 1000
        widened_records = cls.get_cls_data(trace_id, wf, wt)
        if widened_records:
            records, f, t, widened = widened_records, wf, wt, True
    return {"trace_id": trace_id, "region": cls.REGION, "topic_id": cls.TOPIC_ID,
            "from_ms": f, "to_ms": t, "widened": widened,
            "count": len(records), "records": records}


def _parse_trace_id(data):
    for d in (data.get("content", {}).get("data") or []):
        for s in (d.get("series") or []):
            cols = s.get("columns") or []
            idx = next((i for i, c in enumerate(cols) if "trace_id" in str(c)), None)
            if idx is None:
                continue
            for row in (s.get("values") or []):
                if idx < len(row) and row[idx]:
                    return row[idx]
    return None


@mcp.tool(annotations=_ANNOTATIONS)
def find_error_trace_id(service: str = "", from_ms: int = 0, to_ms: int = 0) -> dict:
    """Find one representative error (non-2xx) trace_id from TrueWatch APM.
    service is optional (empty = all services); time window is optional and
    auto-widens if nothing is found."""
    if not TW_API_KEY:
        return {"service": service, "trace_id": None, "error": "TW_API_KEY not set"}
    cond = "`http_status_code` != '200'"
    if service:
        svc = str(service).replace("'", "").replace("`", "")
        cond += f" AND `service` IN ['{svc}']"
    dql = f"T::RE(`.*`):(last(`trace_id`)) {{ {cond} }} BY `service`"

    def run(f, t):
        try:
            return _parse_trace_id(_run_dql(dql, f, t)), None
        except urllib.error.HTTPError as e:
            return None, f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:300]}"
        except Exception as e:
            return None, str(e)

    if from_ms and to_ms:
        f, t = int(from_ms), int(to_ms)
        center = (f + t) // 2
    else:
        t = int(time.time() * 1000)
        f = t - CLS_WIDEN_HOURS * 3600 * 1000
        center = t
    trace_id, err = run(f, t)
    if err:
        return {"service": service, "trace_id": None, "error": err, "dql": dql}
    widened = False
    if not trace_id:
        wf = center - CLS_WIDEN_HOURS * 3600 * 1000
        wt = center + CLS_WIDEN_HOURS * 3600 * 1000
        trace_id, err = run(wf, wt)
        if err:
            return {"service": service, "trace_id": None, "error": err, "dql": dql}
        if trace_id:
            f, t, widened = wf, wt, True
    return {"service": service, "from_ms": f, "to_ms": t, "widened": widened, "trace_id": trace_id}


@mcp.tool(annotations=_ANNOTATIONS_WRITE)
def add_incident_comment(incident_uuid: str, comment: str) -> dict:
    """Add a comment to a TrueWatch incident via the Incident OpenAPI (DF-API-KEY)."""
    if not TW_API_KEY:
        return {"incident_uuid": incident_uuid, "success": False, "error": "TW_API_KEY not set"}
    url = f"{TW_OPENAPI_BASE}/api/v1/incidents/comment/{incident_uuid}/add"
    body = json.dumps({"comment": comment, "attachmentUUIDs": [], "extend": {}}).encode("utf-8")
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json;charset=UTF-8")
    req.add_header("DF-API-KEY", TW_API_KEY)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            resp = json.loads(r.read().decode("utf-8", "replace"))
        return {"incident_uuid": incident_uuid, "success": bool(resp.get("success")), "response": resp}
    except urllib.error.HTTPError as e:
        return {"incident_uuid": incident_uuid, "success": False,
                "error": f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:300]}"}
    except Exception as e:
        return {"incident_uuid": incident_uuid, "success": False, "error": str(e)}


if __name__ == "__main__":
    if not cls.SECRET_ID or not cls.SECRET_KEY:
        raise SystemExit("ERROR: set TENCENT_SECRET_ID and TENCENT_SECRET_KEY env vars.")
    if TRANSPORT == "stdio":
        print(f"CLS MCP server (stdio) region={cls.REGION} topic={cls.TOPIC_ID}", file=sys.stderr)
        mcp.run(transport="stdio")
    else:
        print(f"CLS MCP server on http://{HOST}:{PORT}/mcp")
        mcp.run(transport="streamable-http")
```

## Appendix C: Reference Links

- Agent deployment guide: https://github.com/TrueWatchTech/integration-enhancement/blob/main/TrueWatch-Toby-AI-Agent-Teams-Practical-Configuration-Guide.md
- APM Detection: https://docs.truewatch.com/monitoring/monitor/application-performance-detection/
- Monitor Overview: https://docs.truewatch.com/monitoring/monitor/
- MCP Services Configuration: https://docs.truewatch.com/toby-agent-teams/mcp-services/
- OWL MCP Quickstart: https://docs.truewatch.com/owl/mcp-quickstart/
- Skills: https://docs.truewatch.com/toby-agent-teams/skills/
- Scheduled Tasks: https://docs.truewatch.com/toby-agent-teams/scheduled-tasks/
</content>
</invoke>

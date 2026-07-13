# TrueWatch Toby AI Agent Teams Practical Configuration Guide

This guide is intended for technical personnel planning to set up TrueWatch Toby AI Agent Teams on local or self-managed infrastructure. It provides an end-to-end configuration process covering environment preparation, Agent onboarding, integration of query capabilities (OWL MCP), LLM configuration, and orchestration of Skills and Tasks. This guide follows the official TrueWatch English documentation, and each operational section concludes with a link to the corresponding official documentation for reference.

Commands and configuration fields in this document illustrate mainstream scenarios. For production environments, use the actual workspace site, credentials, and security policies applicable to the deployment.

---

## Table of Contents

1. Overview and Architecture
2. Prerequisites (including Local Linux Environment Setup on macOS)
3. Creating an Agent
4. Deploying the Self-Hosted Agent Runtime
5. Configuring the LLM
6. Integrating the OWL MCP Server
7. Configuring Skills
8. Tasks and Scheduled Tasks
9. Integrating Third-Party Message Channels (Optional)
10. Verification and Troubleshooting

---

## 1. Overview and Architecture

Toby AI Agent Teams is TrueWatch's multi-Agent work platform designed for teams. Around a single Agent, the following components can be combined:

- **Agent**: An intelligent entity with a clearly defined responsibility, identity, and behavioral boundaries.
- **Skill**: The Agent's working methods and specialized capabilities (such as data analysis, deployment checks, documentation organization, etc.).
- **MCP Service**: Integrates external tool capabilities into the Agent via the Model Context Protocol. This guide uses the OWL MCP Server as an example, used to query observability data on the TrueWatch platform.
- **Message Channel**: Connects the Agent to IM platforms such as WeCom, DingTalk, and Lark.
- **Tasks and Scheduled Tasks**: The entry points that drive the Agent to perform work, supporting plan mode, approvals, and output archiving.
- **Self-Hosted Runtime**: The Agent's execution process, deployed on a host owned by the user, connecting upward to the TrueWatch platform and downward to models and tools.

Typical runtime architecture: The TrueWatch platform (cloud control plane) maintains a persistent connection with the Agent runtime deployed on the self-hosted host. The runtime invokes the LLM to perform inference and accesses metrics, logs, events, and other data on the TrueWatch platform through the OWL MCP Server, ultimately relaying conclusions back to the platform or message channel.

Regarding runtime deployment location: **it is recommended to host the Agent runtime on a dedicated virtual machine (VM)** so that it is not interrupted by an individual user's shutdown, sleep, or local configuration changes, ensuring the Agent remains online over the long term. Deploying on a personal local PC (such as the macOS + OrbStack approach in Section 2.1) is recommended only for functional verification and test setups; for production use, migrate to a dedicated, managed VM or server.

> Official documentation: [TrueWatch Docs — Agents](https://docs.truewatch.com/toby-agent-teams/agents/)

---

## 2. Prerequisites

Before starting, confirm the following are in place:

- A TrueWatch account and workspace. **Only workspace owners and administrators can create an Agent**; confirm the account holds the appropriate role.
- A TrueWatch API Key with the required Open API permissions. The scope accessible to OWL MCP is entirely determined by this Key's permissions; resources without sufficient permission cannot be accessed.
- A Linux host for deploying the Agent runtime (a virtual machine may be used for local testing).
- The host must have access to the TrueWatch platform and target data sources, with correct time synchronization, proxy, and firewall configuration.

### 2.1 Setting Up a Local Linux Environment on macOS

The Agent runtime must be deployed in a Linux environment. For local test setups on macOS, it is recommended to use **OrbStack** to quickly create a lightweight Ubuntu virtual machine (arm64 architecture on Apple Silicon models, with fast startup and low resource usage); equivalent alternatives such as Multipass, UTM, or Docker Desktop may also be used.

Using OrbStack as an example:

1. Download and install OrbStack from [orbstack.dev](https://orbstack.dev).
2. Create an Ubuntu virtual machine (via the graphical interface, or using the command line):

   ```bash
   orb create ubuntu finops
   ```

   Here, `finops` is the virtual machine name and can be customized.

3. Enter the shell of the virtual machine:

   ```bash
   orb shell finops
   # or
   ssh finops@orb
   ```

4. Confirm the base environment (typically required by subsequent installation scripts):

   ```bash
   sudo apt update
   python3 --version
   ```

This virtual machine is a persistent environment: OrbStack automatically restarts it after a host reboot, and the Agent runtime deployed within it can automatically reconnect. For production deployment, use a managed, dedicated host and follow the host security policies of the applicable organization.

> Official documentation: [TrueWatch Docs — Runtime Deployment and Host Requirements](https://docs.truewatch.com/toby-agent-teams/runtime/)

### 2.2 Obtaining a TrueWatch API Key

Both integrating OWL MCP (Section 6) and configuring the model (Section 5) require a TrueWatch API Key. It determines the scope of accessible data, so prepare and safeguard it in advance.

1. Log in to the TrueWatch console and navigate to the target workspace.
2. Open the workspace's **Administration → API Key** page.
3. Click **Create API Key** (or copy an existing Key with suitable permissions). When creating a new Key, confirm its Open API permissions cover the resources to be accessed later (such as metrics, logs, events, dashboards, etc.); resources without sufficient permission cannot be accessed after integration.
4. Copy the generated Key value and store it securely. The same Key will be used later for OWL MCP's authorization header and the runtime's model configuration.

> Security note: An API Key is equivalent to an access credential for the corresponding resources; do not write it into external-facing documents, code repositories, or chat logs. It is recommended to use different Keys for test and production environments.

---

## 3. Creating an Agent

Procedure:

1. Log in to the console with an account holding administrator or workspace owner privileges, and navigate to the **Agent Teams** workbench.
2. Click **Create Agent** and fill in the following fields in the form:
   - **Name** and **Description**: Concisely identify the Agent's purpose, for example, "Cloud Cost Analysis Assistant / used to query and analyze cloud billing data."
   - **Scope of Availability**: Select which members can use this Agent. Administrators and workspace owners are unrestricted; it is recommended to assign access following the principle of least privilege ("only those who need it can use it"), and sensitive or production-oriented Agents should not be made available to all members.
   - **Identity Definition**: Specify the Agent's core identity, target audience, typical scenarios, and output conventions. This content acts as the system prompt influencing the Agent's behavior; it is recommended to be as specific as possible.
   - **Behavioral Boundaries**: Clearly distinguish between three categories of actions — "can execute directly / requires human confirmation / prohibited" — with write operations and high-risk actions in particular assigned to "requires human confirmation."
3. Save. At this point, the Agent has been created but does not yet have execution capability — it still requires a runtime to host execution, and must be connected to a model and tools. Continue to Section 4.

> Note: The remainder of this guide uses an Agent for "querying and analyzing observability data" as a running example, tying together the configuration of the runtime, model, and OWL MCP.

> Official documentation: [TrueWatch Docs — Agents](https://docs.truewatch.com/toby-agent-teams/agents/)

---

## 4. Deploying the Self-Hosted Agent Runtime

The Agent runtime is deployed in a self-hosted manner on a host owned by the user. The platform generates a **dedicated installation command** for each Agent, eliminating the need to manually download installation packages or assemble parameters.

**Step 1: Obtain the installation command**

1. In the console, open the Agent created in the previous section and navigate to its **Runtime / Deployment** tab.
2. Select the operating system of the target host (this guide uses Linux).
3. Choose whether to enable "Agent self-observability collection" (used to monitor the runtime itself; may be enabled as needed during the testing phase).
4. The page generates a **dedicated installation command**; click to copy it. This command already embeds this Agent's access key and the platform connection address.

**Step 2: Run the installation on the host**

1. Enter the shell of the Ubuntu virtual machine created in Section 2 (or the production host).
2. Paste and execute the installation command just copied. The command automatically completes runtime installation, registers it as a persistent service, and writes the configuration file.
3. Once the installation script completes successfully, the runtime automatically connects to the workspace.

**Step 3: Confirm online status**

Return to the Agent's runtime page in the console; after refreshing, its status should change to **Online**. The runtime runs as a persistent service and will automatically reconnect after a host reboot.

**Local structure of the runtime**

The following files and services are automatically generated by the installation command, for use during troubleshooting or configuration adjustments.

- The runtime is registered as a persistent systemd service. To check status and restart:

  ```bash
  sudo systemctl status  <runtime-service-name>
  sudo systemctl restart <runtime-service-name>
  ```

  Here, `<runtime-service-name>` is the service name registered by the installation command; the actual name can be found using `systemctl list-units | grep -i agent`.

- The installation command generates a configuration file in a runtime-specific directory under `/etc/` (in the form `/etc/<runtime>/agent.env`). To view its content:

  ```bash
  sudo cat /etc/<runtime>/agent.env
  ```

  This file is **pre-populated** by the installation command with two categories of variables:

  - **Platform connection variables**: The Agent's access key, platform connection address, etc., where the platform connection address takes the form `https://agent-api.truewatch.com`. These variables are written by the installation command and **must not be manually modified**.
  - **Model variables**: `LLM_BASE_URL` and `LLM_API_KEY` are required, and `LLM_MODEL` is optional; these need to be filled in or verified per Section 5.

> Note: The file paths, service name, and variables above are written by the installation command; the exact values may vary depending on the runtime version or site. Use the actual content generated by the installation command on the target host as the reference, which can be verified using the `cat` command above.

> Official documentation: [TrueWatch Docs — Runtime (Agent Service Deployment)](https://docs.truewatch.com/toby-agent-teams/runtime/)

---

## 5. Configuring the LLM

The Agent runtime requires an LLM to provide inference capability. Model configuration is completed through a small number of variables in the runtime configuration file; changes take effect after restarting the runtime. There are two integration paths.

### 5.1 Using TrueWatch AI Hub (Recommended)

AI Hub is TrueWatch's multi-model gateway. It requires no self-supplied third-party model Key, no billing card binding, and no self-built relay, making it the recommended default path. Model configuration is determined by variables in the runtime configuration file `/etc/<runtime>/agent.env`; newer runtime versions **default to the `default` model identifier**, so only the following two variables are required.

**Meaning and acquisition method of required fields:**

| Variable | Meaning | Acquisition Method |
|---|---|---|
| `LLM_BASE_URL` | AI Hub gateway address | **Pre-populated** by the installation command in Section 4 with the workspace's AI Hub gateway address, and is typically already present in `agent.env`. Simply verify the existing value, **leave it unchanged, and never change it to a third-party model endpoint** (doing so causes call failures due to the absence of gateway processing). If this value is empty, the AI Hub address for this workspace can be viewed in the console under Agent Teams' model / AI configuration and entered here. |
| `LLM_API_KEY` | Credential for authenticating to AI Hub | Use the TrueWatch API Key obtained in Section 2.2 (the same category of Key used for OWL MCP). |

**Regarding `LLM_MODEL` (optional, usually not required):** Newer runtime versions default to the `default` model identifier, so `LLM_MODEL` does not need to be configured further. Set it only when it is genuinely necessary to **pin a specific model**, using that model's name as the value (the specific available models are subject to what is actually supported in the console / AI Hub). If a legacy configuration still has an active `LLM_MODEL=...` line and pinning is no longer needed, this line may be **deleted, followed by a service restart**.

**Configuration steps:**

1. On the runtime host, open the configuration file with an editor:

   ```bash
   sudo nano /etc/<runtime>/agent.env
   ```

2. Verify and fill in the two required variables per the table above, for example:

   ```bash
   LLM_BASE_URL="https://<the workspace's AI Hub gateway address>"   # Usually pre-populated by the installation command; leave unchanged
   LLM_API_KEY="<the TrueWatch API Key obtained in Section 2.2>"
   # LLM_MODEL is optional: defaults to the "default" model, no need to set; fill in only when pinning a specific model is required
   ```

3. Save and exit (in nano: `Ctrl+O`, Enter, then `Ctrl+X`).

4. Restart the runtime for the configuration to take effect:

   ```bash
   sudo systemctl restart <runtime-service-name>
   ```

**Key points and troubleshooting:**

- Once `LLM_BASE_URL` and `LLM_API_KEY` are configured, they generally require no further changes; the model defaults to `default` and generally requires no intervention.
- If a model call returns HTTP 429 (rate limited), this can be avoided by setting `LLM_MODEL` to **pin a different available model** and then restarting the runtime; when pinning is not needed, keep the default.
- If HTTP 403 is returned with a message indicating the monthly credit limit has been reached, this is due to the workspace's AI Hub credits being exhausted, and requires the organization to top up or raise the quota — it is not a configuration issue.

### 5.2 Using a Self-Supplied LLM (BYO Model)

To integrate a self-supplied original-vendor model (such as a self-supplied Gemini, OpenAI, or Anthropic endpoint), a forwarding proxy must be deployed on the runtime host to strip the gateway-private fields injected by the runtime before forwarding the request, with `LLM_BASE_URL` pointed at this local proxy. For the complete principles, scripts, and configuration steps, see the dedicated guide: [BYO Model Forward Proxy Configuration Guide](https://github.com/TrueWatchTech/integration-enhancement/blob/main/BYO-Model-Forward-Proxy-Guide.md).

---

## 6. Integrating the OWL MCP Server

The OWL MCP Server encapsulates the TrueWatch platform's observability capabilities as standard MCP tools, enabling the Agent to query metrics, logs, events, and other data. MCP service configuration follows the logic of "**register globally first, then enable on the specific Agent**."

### 6.1 Globally Registering the MCP Service

In Agent Teams' MCP service configuration entry, add a new MCP Server and fill in:

- **Type**: `streamableHttp`
- **URL**: The OWL MCP Endpoint corresponding to the workspace's site, which must end with `/mcp`.
- **Header**: `Authorization: Bearer <TrueWatch API Key>`

**Access address for the Indonesia Region 1 (Jakarta, site code id1) availability zone:**

```
https://id1-owl-mcp.truewatch.com/mcp
```

For other sites, use the corresponding `<site>-owl-mcp` domain; see the [list of site endpoints in the OWL MCP Quick Start](https://docs.truewatch.com/owl/mcp-quickstart/) for details.

### 6.2 Enabling on the Agent

Enable the registered OWL MCP service in the target Agent's workbench. Once enabled, OWL MCP exposes three routing tools:

- `list_catalogs`: Lists the available tool catalogs.
- `list_tools`: Lists the tools within a catalog.
- `exec_tool`: Executes a specific tool, with parameters `tool_name` (the tool name) and `parameters` (the tool's parameter object).

For example, when querying data, `exec_tool` is used to call `owl.data.simple_query`, following the convention of "discover first, then query" (first use each domain's `*.list` to obtain the source/field/index, then execute the query). Time parameters uniformly use 13-digit millisecond timestamps.

> Official documentation:
>
> - [TrueWatch Docs — MCP Service Configuration](https://docs.truewatch.com/toby-agent-teams/mcp-services/)
> - [TrueWatch Docs — OWL MCP Quick Start (including site endpoints and authentication)](https://docs.truewatch.com/owl/mcp-quickstart/)
> - [TrueWatch Docs — OWL MCP Tool Reference](https://docs.truewatch.com/owl/mcp-tools-reference/)

---

## 7. Configuring Skills

A Skill encapsulates a **reusable working method or specialized process** (such as a fixed troubleshooting procedure, analysis routine, report template, or release checklist) as a capability unit the Agent can reliably invoke.

**Why configure Skills.** Without a configured Skill, the Agent can still operate based on the LLM's general capabilities and any integrated MCP tools, but "how" it performs each task depends mainly on ad hoc descriptions in the task prompt — for the same category of task, execution paths and output quality can vary depending on the person and phrasing involved. Once a Skill is configured, the correct approach is fixed and reused across the team: the Agent executes according to established steps, producing more consistent and professional output, while also eliminating the cost of repeatedly writing complex prompts for each task and consolidating the team's best practices.

**Overview of differences with and without Skill configuration:**

| Dimension | Without Skill Configuration | With Skill Configuration |
|---|---|---|
| Execution method | Relies on the LLM's general capabilities plus ad hoc prompts for each task | Executes reliably according to encapsulated steps/methods |
| Output consistency | Varies with prompt quality and phrasing | Consistent, predictable output for similar tasks |
| Reuse and sharing | Difficult to reuse across tasks or members | Shared across the team and reusable once globally registered |
| Coordination with tools | Tool usage must be explained ad hoc in the prompt | Tool invocation can be embedded within the Skill (e.g., internally calling OWL MCP to query data) |

**If it is not yet clear how to configure a Skill.** The following approach can be used to get started, without needing to achieve completeness from the outset:

- **Usable without configuring one first**: The Agent remains functional without a configured Skill, as long as requirements and steps are clearly described in the task; a Skill can be distilled from this later.
- **Start from built-in/example Skills**: Prioritize enabling built-in or example Skills provided by the platform, or copy and modify one as a template, which is faster than writing from scratch.
- **Iterate from a minimal Skill**: Start by creating a minimal Skill containing only a name, description, and a few key points, then refine it after trial use.
- **Refer to official documentation**: Details on creating and managing Skills are provided in the official documentation link at the end of this section.

Skill configuration follows the principle of "**configure globally first, then enable on the specific Agent**": administrators prepare team-wide Skills in the settings center, then enable the required Skills in the specific Agent's workbench.

Configuration points:

- **Always fill in the Description when creating a Skill.** The Agent relies on the Skill's description to determine when to invoke it automatically; without a description, it cannot be triggered automatically.
- In scenarios where automatic triggering cannot be guaranteed, the Skill can be **explicitly named in the task prompt** to ensure it is invoked.
- Skills can be used in conjunction with MCP tools (for example, a data analysis Skill that internally calls OWL MCP to query data).

> Official documentation: [TrueWatch Docs — Skills](https://docs.truewatch.com/toby-agent-teams/skills/)

---

## 8. Tasks and Scheduled Tasks

### 8.1 Tasks

Creating a new task in the Agent workbench (filling in a title and description) opens a collaborative session. Within the session, it is possible to:

- **@ reference entities** (services, applications, dashboards, hosts, containers, etc.) to narrow the scope of analysis;
- Invoke enabled Skills and MCP tools;
- Use **plan mode** for complex tasks (issue troubleshooting, solution design, release checks, refactoring assessments, etc.) — the Agent first presents the objective, scope, steps, and risks before executing;
- Review evidence, hypotheses, analysis, anomalies, impact scope, conclusions, and recommended actions via **task insights** (supporting both timeline and list views);
- Centrally view and download output files in **task attachments**;
- Trigger an **approval** for high-risk actions, requiring human confirmation before proceeding;
- Use "Stop Execution" and "Complete Task" to close out the session.

### 8.2 Scheduled Tasks

Create a new scheduled task in the workbench by filling in a title, selecting an execution frequency (daily/weekly/monthly), setting the execution time, filling in a prompt, and optionally associating a Skill, then save. Scheduled tasks retain historical execution records (time, status, duration, trigger source, summary, and associated session).

> Official documentation:
>
> - [TrueWatch Docs — Tasks (My Tasks)](https://docs.truewatch.com/toby-agent-teams/tasks/)
> - [TrueWatch Docs — Scheduled Tasks](https://docs.truewatch.com/toby-agent-teams/scheduled-tasks/)

---

## 9. Integrating Third-Party Message Channels (Optional)

Third-party message channels connect the Agent to IM platforms such as WeCom, DingTalk, and Lark, supporting either credential-based or QR-code-based integration. Once integrated, members can directly assign tasks to and exchange messages with the Agent within group chats or IM.

> Official documentation: [TrueWatch Docs — Third-Party Message Channels](https://docs.truewatch.com/toby-agent-teams/channels/)

---

## 10. Verification and Troubleshooting

### 10.1 End-to-End Verification

After confirming the runtime shows **Online** on the platform, assign the Agent a task that exercises both OWL MCP and the model for verification, for example:

> Use the OWL MCP service to query a dataset over the last 3 days via `owl.data.simple_query`, grouped by a given dimension, returning each value and its record count.

If the grouped results are returned correctly, this confirms that the runtime, model, and OWL MCP are all properly connected end to end.

### 10.2 Common Issue Troubleshooting

| Symptom | Possible Cause and Resolution |
|---|---|
| Runtime not online (not Online) | Check whether the host can reach the platform, whether the installation command originated from the current Agent, time/proxy/firewall settings, whether host security policy is blocking the connection, and whether credentials have expired or been leaked |
| Model request returns HTTP 429 | The default model is being rate-limited; this can be avoided by setting `LLM_MODEL` to pin a different available model and restarting the runtime |
| Model request returns HTTP 403 with a credit-exhaustion message | The AI Hub workspace's monthly credits are exhausted; requires the organization to top up or raise the quota |
| Self-supplied model endpoint returns HTTP 400 | The gateway-private fields injected by the runtime are being rejected by the original vendor; deploy a forwarding proxy per the BYO dedicated guide in Section 5.2 to strip them before forwarding |
| OWL MCP call returns 401 | Authentication or parameter error: confirm the use of `Authorization: Bearer` and that `exec_tool` parameter keys are `tool_name` / `parameters` |
| "Tool not found" message | Confirm the tool being called is one actually exposed by OWL MCP (e.g., use `owl.data.simple_query` for data queries) |
| Skill not triggered automatically | The Skill is missing a Description; complete the description, or explicitly name the Skill in the prompt |

> Official documentation:
>
> - [TrueWatch Docs — Runtime Status and Deployment Recommendations](https://docs.truewatch.com/toby-agent-teams/runtime/)
> - [TrueWatch Docs — OWL Troubleshooting](https://docs.truewatch.com/owl/troubleshooting/)

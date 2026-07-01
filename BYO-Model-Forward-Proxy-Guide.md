# Connecting a Self-Hosted Agent to Your Own LLM: Local Forward Proxy (shim) Technical Guide

## 1. Background and Problem

By design, the beak-agent (self-hosted Agent runtime) assumes that `LLM_BASE_URL` points to the TrueWatch AI Hub gateway. Based on this assumption, the runtime injects a set of proprietary fields into the OpenAI-format request body sent to the model, including `aihub_reasoning`, `aihub_cache_control`, and all other fields prefixed with `aihub_`. These fields are proprietary extensions of AI Hub and are recognized and processed by AI Hub only.

In a Bring-Your-Own-Model (BYO Model) scenario, if `LLM_BASE_URL` is pointed directly at a third-party first-party endpoint (such as Gemini, OpenAI, or Anthropic), the upstream service cannot recognize these `aihub_*` fields. It treats them as unknown parameters and rejects the request, returning HTTP 400.

## 2. Solution

Deploy a lightweight forward proxy on the host running beak-agent, positioned between the runtime and the target model endpoint. It performs two responsibilities:

1. Upon receiving a request from beak-agent, it recursively removes all `aihub_*` fields from the request body;
2. It forwards the sanitized request to the specified model endpoint along the original path, and returns the response unmodified.

`LLM_BASE_URL` is then pointed at this local proxy (`http://127.0.0.1:8787/...`). From beak-agent's perspective, its counterpart remains equivalent to the AI Hub gateway; the actual request reaches the target model after being sanitized by the proxy, the HTTP 400 is eliminated, and the link is established.

Applicability notes:

- This guide uses Gemini as an example, but the proxy implementation is vendor-agnostic. It applies equally when the upstream endpoint is replaced with OpenAI, Anthropic, or any OpenAI-compatible service; only a single startup parameter needs to be adjusted (see Section 4).
- If traffic continues to route through the TrueWatch AI Hub (i.e., `LLM_BASE_URL` is left unchanged), the `aihub_*` fields are handled by AI Hub itself and this proxy is not required. The proxy is used only when connecting to a self-managed first-party model.

## 3. Complete Code

The following is the complete implementation of the forward proxy script (named `gemini_shim.py` in this example; the filename is arbitrary). It depends only on the Python standard library and requires no additional dependencies. The upstream endpoint, listen address, and listen port are all provided as command-line arguments: `--upstream` is required and specifies the target model API endpoint; `--host` and `--port` are optional, defaulting to `127.0.0.1` and `8787` respectively, and override the corresponding defaults when specified explicitly. Run `python3 gemini_shim.py --help` to view these arguments and the usage notes in the script header.

```python
#!/usr/bin/env python3
"""
Minimal localhost shim: strips beak-agent's AI-Hub-proprietary fields
(aihub_reasoning / aihub_cache_control / any aihub_*) from the request body,
then forwards to the model endpoint you specify via --upstream.

Run in the orb VM (Gemini shown as an example; --upstream can be any
OpenAI-compatible endpoint, e.g. OpenAI / Anthropic / your own gateway):
    nohup python3 gemini_shim.py --upstream https://generativelanguage.googleapis.com \\
        > /tmp/gemini_shim.log 2>&1 &

Then point the agent at it (example uses Gemini; adjust path/key/model per provider):
    LLM_BASE_URL="http://127.0.0.1:8787/v1beta/openai"
    LLM_API_KEY="AIza...your key"        (unchanged; forwarded as Bearer)
    LLM_MODEL="gemini-3.5-flash"
"""
import argparse
import http.server
import json
import urllib.request
import urllib.error

# Filled in from CLI args in __main__.
UPSTREAM = None
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8787


def strip_aihub(obj):
    """Recursively drop any dict key starting with 'aihub_'."""
    if isinstance(obj, dict):
        return {k: strip_aihub(v) for k, v in obj.items() if not k.startswith("aihub_")}
    if isinstance(obj, list):
        return [strip_aihub(x) for x in obj]
    return obj


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _proxy(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else b""
        if body:
            try:
                body = json.dumps(strip_aihub(json.loads(body))).encode("utf-8")
            except Exception:
                pass  # not JSON; forward as-is

        req = urllib.request.Request(UPSTREAM + self.path, data=body, method=self.command)
        for h in ("Authorization", "Content-Type", "Accept"):
            if h in self.headers:
                req.add_header(h, self.headers[h])
        req.add_header("Content-Length", str(len(body)))

        try:
            resp = urllib.request.urlopen(req, timeout=600)
            self.send_response(resp.status)
            ct = resp.headers.get("Content-Type")
            if ct:
                self.send_header("Content-Type", ct)
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except urllib.error.HTTPError as e:
            data = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", e.headers.get("Content-Type", "application/json"))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            msg = str(e).encode()
            self.send_response(502)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(msg)

    def do_POST(self):
        self._proxy()

    def do_GET(self):
        self._proxy()

    def log_message(self, fmt, *args):
        pass  # quiet


def parse_args():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--upstream", required=True,
        help="Required. Upstream model API endpoint to forward to, "
             "e.g. https://generativelanguage.googleapis.com (Gemini, example) "
             "or any OpenAI-compatible base URL.",
    )
    parser.add_argument(
        "--host", default=LISTEN_HOST,
        help=f"Listen host (default: {LISTEN_HOST}).",
    )
    parser.add_argument(
        "--port", type=int, default=LISTEN_PORT,
        help=f"Listen port (default: {LISTEN_PORT}).",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    UPSTREAM = args.upstream.rstrip("/")
    LISTEN_HOST, LISTEN_PORT = args.host, args.port
    print(f"shim listening on http://{LISTEN_HOST}:{LISTEN_PORT}  ->  {UPSTREAM}")
    http.server.ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler).serve_forever()
```

## 4. Code Walkthrough

This script implements a transparent reverse proxy that sanitizes fields in the request body. Its components are described below.

**Command-line arguments (`parse_args`)**

- `--upstream`: Required. Specifies the target model API endpoint to forward to. This guide uses Gemini (`https://generativelanguage.googleapis.com`) as an example; it may be replaced with the base URL of OpenAI, Anthropic, or any OpenAI-compatible service. The specific path of the endpoint is appended from `self.path` in the beak-agent request, so the proxy is indifferent to routing details; a trailing `/` in the argument is normalized at startup.
- `--host`: Optional. The proxy listen address, defaulting to `127.0.0.1` (i.e., exposed to the local host only); overridden when specified explicitly.
- `--port`: Optional. The listen port, defaulting to `8787`; overridden when specified explicitly.
- `--help`: Prints the argument descriptions above and the usage documentation from the script header (injected via `description=__doc__`).

**`strip_aihub(obj)`**

The core logic of the proxy. The function recursively traverses the entire JSON structure: for dictionaries it discards all keys prefixed with `aihub_`, and for lists it processes each element recursively. This ensures that `aihub_*` fields are completely removed regardless of the level at which they reside in the request body (top level or within `messages`).

**`_proxy()`**

The main forwarding flow, with the following steps:

1. Reads the request body; if it is valid JSON, it is sanitized via `strip_aihub` and re-serialized, otherwise it is forwarded as-is (fault-tolerant behavior).
2. Reconstructs the request to `UPSTREAM + self.path` via `urllib`, passing through `Authorization` (the model credential is forwarded as-is as a Bearer token, untouched by the proxy), `Content-Type`, and `Accept`, and resets `Content-Length` according to the actual sanitized length.
3. Streams the upstream response back to beak-agent in chunks (a `resp.read(8192)` loop combined with `flush`), supporting streaming output.
4. Error handling: when the upstream returns an error (`HTTPError`), its status code and error body are returned as-is to aid troubleshooting; all other exceptions return HTTP 502.

**Request methods and runtime model**

`do_POST` and `do_GET` share the same `_proxy()` implementation; `log_message` is left empty to suppress access log output. The service is based on `ThreadingHTTPServer` and supports concurrent request handling.

Additional note: if the upstream endpoint sits behind a protection layer such as Cloudflare, the default urllib User-Agent may be blocked. In that case, append a browser User-Agent to the request headers in Step 2, for example `req.add_header("User-Agent", "Mozilla/5.0")`. First-party endpoints such as Gemini and OpenAI typically do not require this.

## 5. Deployment and Configuration

1. Deploy the script on the host running beak-agent (such as the `finops` VM in OrbStack) and start it as a background process, specifying the target model endpoint via `--upstream` (Gemini is used below as an example and may be replaced with any OpenAI-compatible endpoint); when `--host` and `--port` are not specified, the defaults `127.0.0.1:8787` are used:

   ```bash
   nohup python3 gemini_shim.py --upstream https://generativelanguage.googleapis.com \
       > /tmp/gemini_shim.log 2>&1 &
   ```

   To view the argument descriptions, run `python3 gemini_shim.py --help`.

2. Edit the beak-agent configuration file `/etc/beak-agent/agent.env`, point `LLM_BASE_URL` at the local proxy, and replace the credential with the API key of your own model (Gemini is used below as an example; for other vendors, substitute their respective endpoint paths, keys, and model names):

   ```bash
   LLM_BASE_URL="http://127.0.0.1:8787/v1beta/openai"   # points to the local proxy; path segment depends on the upstream (Gemini here)
   LLM_API_KEY="AIza...your key"                         # forwarded as-is as Bearer
   LLM_MODEL="gemini-3.5-flash"                          # target model name
   ```

   The differences between vendors are reflected in only three values: the path segment at the end of `LLM_BASE_URL` corresponds to each vendor's API path, `LLM_API_KEY` corresponds to each vendor's credential, and `LLM_MODEL` corresponds to each vendor's model name; the proxy implementation itself requires no changes (only `--upstream` is adjusted when switching vendors).

3. Restart the Agent for the configuration to take effect:

   ```bash
   sudo systemctl restart beak-agent
   ```

   To stop the proxy, run `pkill -f gemini_shim`. The script file is retained and can be restarted later via `nohup`.

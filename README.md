# Claude Code in NVIDIA OpenShell

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) inside an
[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) sandbox. The agent gets an
isolated filesystem, a deny-by-default network policy, and never sees the real
Anthropic API key.

Written against OpenShell **v0.1.6**.

> **Note:** guides written for OpenShell before 0.1.0 (including NVIDIA's own
> "perspectives" posts) say `openshell sandbox create -- claude` is enough. It no
> longer is: the default image has no agents, `--from` does not build Dockerfiles or
> expand catalog names, and the gateway ships no built-in provider profiles. You
> need your own image, a provider, and a policy — as described below.

## Requirements

- macOS on Apple Silicon or Linux (Windows via WSL 2 is experimental)
- A container runtime: Docker Desktop / Docker Engine 28+, Podman 5.x (Linux), or
  host virtualization for the MicroVM runtime
- An Anthropic **API key** from [console.anthropic.com](https://console.anthropic.com).
  A Pro/Max subscription login does not work; generate a separate Console key.

## Installation

Install the CLI, the policy prover, and a local gateway:

```sh
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
```

Check that the CLI can reach the gateway:

```sh
openshell status
```

To pin a release, set `OPENSHELL_VERSION` to a release tag before running the
installer.

## Setup

### 1. Build the Claude Code image

The [`Dockerfile`](Dockerfile) installs Claude Code with the native installer and
copies the binary to `/usr/local/bin/claude` — one of the two paths the
`claude-code` provider profile allows to reach Anthropic's API. It also runs as a
non-root user, which OpenShell requires for Docker and Podman.

```sh
docker build -t openshell-claude:latest .
```

OpenShell replaces the image's `CMD`/`ENTRYPOINT` with its own supervisor, so the
command to run is always passed after `--` on `sandbox create`.

The image sets two environment variables:

- `DISABLE_AUTOUPDATER=1` — the policy blocks the updater's download hosts anyway.
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` — no telemetry or error reporting.
  Without it, Claude Code 2.1.314 tries to send logs to
  `http-intake.logs.us5.datadoghq.com` on every run; the policy blocks it, but
  each attempt shows up as a denial and a pending rule proposal.

Image `ENV` reaches the sandbox's main process and everything it starts, but not
commands run with `openshell sandbox exec`. Pass `--env KEY=VALUE` to `exec` when
you run `claude` that way.

### 2. Import the Claude Code provider profile

```sh
openshell profile import --global \
  --url https://raw.githubusercontent.com/NVIDIA/OpenShell/main/providers/claude-code.yaml
```

The profile lets `/usr/bin/claude` and `/usr/local/bin/claude` reach
`api.anthropic.com`, plus `statsig.anthropic.com` and `sentry.io` for Claude Code's
telemetry. Claude Code 2.1.314 did not contact either of them in testing, and
`sentry.io` is a third-party service anyone can create an account on, so it is a
possible way to send data out. To remove them, download the file, delete those two
endpoints, and import your copy with `-f` (or `openshell profile update --global -f
claude-code.yaml claude-code` if it is already imported).

### 3. Create a provider with your API key

```sh
# fish
set -gx ANTHROPIC_API_KEY sk-ant-...
# bash / zsh
export ANTHROPIC_API_KEY=sk-ant-...

openshell provider create --name claude --type claude-code --from-existing
```

The key is stored in the gateway's credential store. Inside the sandbox Claude
only sees a placeholder; the OpenShell proxy swaps in the real key, and only on
requests to the profile's endpoints.

## Usage

### Smoke test

```sh
openshell sandbox create --name smoke --from openshell-claude:latest \
  --provider claude -- claude --model haiku -p 'reply with OK'
openshell sandbox delete smoke
```

`claude -p` answers once and exits, so this sandbox ends in `Completed` right away.
That is expected — delete it afterwards.

### Interactive session

Run interactive `claude` as the sandbox's main process:

```sh
openshell sandbox create --name claude-dev --from openshell-claude:latest \
  --provider claude -- claude
```

### Work on a local project

`--upload` cannot be combined with a trailing command, so you land in a shell
inside the sandbox and start Claude from there:

```sh
openshell sandbox create --name claude-dev --from openshell-claude:latest \
  --provider claude --upload ./my-project:/sandbox/my-project

# inside the sandbox
cd my-project && claude
```

Uploads from a Git repository respect `.gitignore`. Add `--no-git-ignore` to
upload everything.

### Detach and reattach

- **Detach** with `Ctrl-P`, then `Ctrl-Q` (or `Ctrl-D`). The main process keeps
  running.
- **Reattach** with `openshell sandbox connect claude-dev`. It replays up to 1 MiB
  of recent output.
- **Do not quit the agent** (`/exit`, `Ctrl-D` in Claude) if you want to come back.
  When the main process exits, the sandbox stops running and moves to `Completed`.

### Sandbox phases

| Phase       | Meaning                                                                            |
| ----------- | ---------------------------------------------------------------------------------- |
| `Ready`     | Running. You can connect, exec, upload, download, and read logs.                   |
| `Completed` | The main process exited with code 0. Nothing is running; the workspace is kept.    |
| `Error`     | The main process exited non-zero, or the infrastructure failed.                    |
| `Stopped`   | Stopped with `sandbox stop`. Nothing is running; the workspace is kept.            |

A `Completed` sandbox is not dead, but you cannot `connect`, `exec`, `upload`, or
`download` until you start it again. `openshell sandbox start <name>` launches a
**fresh** instance of the same main command (the previous session is not
restored), waits for `Ready`, and then you can `connect`.

## Useful commands

### Sandboxes

| Task                                    | Command                                                     |
| --------------------------------------- | ----------------------------------------------------------- |
| List sandboxes and their phases         | `openshell sandbox list`                                    |
| Inspect a sandbox (status, policy)      | `openshell sandbox get claude-dev`                          |
| Inspect as JSON                         | `openshell sandbox get claude-dev --output json`            |
| Reattach to the main process            | `openshell sandbox connect claude-dev`                      |
| Open a second, independent shell        | `openshell sandbox exec claude-dev --tty -- /bin/bash -l`   |
| Upload files into the sandbox           | `openshell sandbox upload claude-dev ./src`                 |
| Download files from the sandbox         | `openshell sandbox download claude-dev my-project ./out`    |
| Stop, keeping the workspace             | `openshell sandbox stop claude-dev`                         |
| Start a stopped or completed sandbox    | `openshell sandbox start claude-dev`                        |
| Delete one or more sandboxes            | `openshell sandbox delete claude-dev smoke`                 |

### Network rules

[`policy.yaml`](policy.yaml) is the sandbox policy: which paths the agent can read
and write, and which hosts each program can reach. Everything it does not list is
denied; the `claude` provider adds its own rule for `api.anthropic.com`. Create the
sandbox with it:

```sh
openshell sandbox create --name claude-dev --from openshell-claude:latest \
  --provider claude --policy policy.yaml -- claude
```

Network rules can be changed while the sandbox runs. OpenShell closes connections
opened under the old rules, and the next request is checked against the new ones.
Filesystem and Landlock settings are fixed at startup; changing them needs a new
sandbox.

| Task                                            | Command                                                          |
| ----------------------------------------------- | ---------------------------------------------------------------- |
| Apply edited `network_policies` from the file   | `openshell policy set claude-dev --policy policy.yaml --wait`    |
| Remove a rule                                   | `openshell policy update claude-dev --remove-rule <name> --wait` |
| Show the base policy (what you set)             | `openshell policy get claude-dev --base`                         |
| Show the effective policy (with provider rules) | `openshell policy get claude-dev --full`                         |
| List policy revisions and whether they loaded   | `openshell policy list claude-dev`                               |
| See why a request was denied                    | `openshell logs claude-dev --since 10m --source sandbox`         |

To add one host without editing the file, use `policy update`. For example, to let
Claude's WebFetch read PyPI pages:

```sh
openshell policy update claude-dev --rule-name pypi_docs \
  --binary /usr/local/bin/claude \
  --add-endpoint pypi.org:443:read-only:rest:enforce --wait
```

The endpoint format is `host:port:access:protocol:enforcement`. Replace `--wait`
with `--dry-run` to preview a change. `--binary` must be the real path, not a
symlink, and a rule also covers every process that binary starts — see the
comments in `policy.yaml`.

`policy set` replaces the whole policy, so use it only on a sandbox created from
`policy.yaml`. OpenShell rejects changes to removed filesystem paths, Landlock, or
process settings on a running sandbox, and saves added paths without applying them.

#### WebSearch is not covered by the network policy

Claude's WebSearch tool runs on Anthropic's servers, and its results come back
through `api.anthropic.com`, so the sandbox policy cannot block it — it works even
when the policy allows no web hosts at all. Search results are untrusted content,
and therefore a possible source of prompt injection. To turn WebSearch off, deny it
in Claude Code's managed settings inside the image. Create `managed-settings.json`:

```json
{ "permissions": { "deny": ["WebSearch"] } }
```

and copy it into the image in the `Dockerfile`:

```dockerfile
USER root
COPY managed-settings.json /etc/claude-code/managed-settings.json
USER claude
```

Managed settings take precedence over user and project settings, and `/etc` is
read-only in the sandbox, so the agent cannot turn WebSearch back on.

### Network approvals

The default policy is restrictive. When Claude reaches a host the policy does not
allow (for example, `npm install` or `git clone`), OpenShell denies the request and
drafts a rule. Approved rules hot-reload without a restart.

| Task                                    | Command                                                                  |
| --------------------------------------- | ------------------------------------------------------------------------ |
| List pending rule proposals             | `openshell rule get claude-dev --status pending`                         |
| Approve one proposal                    | `openshell rule approve claude-dev --chunk-id <chunk-id>`                |
| Reject one proposal                     | `openshell rule reject claude-dev --chunk-id <chunk-id> --reason "..."`  |
| Approve all pending proposals           | `openshell rule approve-all claude-dev`                                  |

`rule approve-all` skips security-flagged proposals unless you add
`--include-security-flagged`.

### Providers and profiles

| Task                                    | Command                                                       |
| --------------------------------------- | ------------------------------------------------------------- |
| List imported profiles                  | `openshell profile list`                                      |
| Show what a profile allows              | `openshell profile describe claude-code`                      |
| List providers                          | `openshell provider list`                                     |
| Show a provider                         | `openshell provider get claude`                               |
| Update the stored key from your env     | `openshell provider update claude --from-existing`            |
| Delete a provider                       | `openshell provider delete claude`                            |

Providers can also be changed on a running sandbox with
`openshell sandbox provider attach` / `detach`. To add GitHub or another service,
see [Secrets and environment variables](#secrets-and-environment-variables).

### Useful `sandbox create` flags

| Flag                         | Purpose                                                  |
| ---------------------------- | -------------------------------------------------------- |
| `--name <name>`              | Name the sandbox (otherwise a random name is generated)  |
| `--from <image>`             | Image to run (`openshell-claude:latest`)                 |
| `--provider <name>`          | Attach a provider; repeat for several                    |
| `--policy <file>`            | Sandbox policy (`policy.yaml`)                           |
| `--upload <local>:<remote>`  | Upload files at creation; repeat for several             |
| `--detach`                   | Create without attaching                                 |
| `--forward <port>`           | Forward a port, e.g. a dev server inside the sandbox     |
| `--gpu` / `--gpu 2`          | Attach one or more GPUs (needs a GPU-capable image)      |
| `--cpu 2 --memory 4Gi`       | Resource limits                                          |
| `--editor vscode`            | Open VS Code (or `cursor`) in the sandbox workspace      |

## Secrets and environment variables

| Kind                                        | How                                                          | Agent sees the real value? |
| ------------------------------------------- | ------------------------------------------------------------ | -------------------------- |
| Plain settings (`DEBUG=1`, a region, a URL) | `sandbox create --env KEY=VALUE`, or `ENV` in the Dockerfile | Yes                        |
| Secrets (API keys, tokens)                  | A provider, attached with `--provider`                       | No — only a placeholder    |

Never put secrets in `--env`, the image, or uploaded files. `--upload` skips
`.gitignore`d files such as `.env` unless you pass `--no-git-ignore`.

### How providers hide secrets

The secret is stored in the gateway, outside the sandbox. Inside, the variable
holds a placeholder such as `openshell:resolve:env:v1663…_MY_API_TOKEN`. When a
program sends that placeholder in an HTTP request to one of the provider profile's
endpoints, the OpenShell proxy replaces it with the real value on the way out.

The proxy replaces placeholders in headers (including Basic auth), query
parameters, and URL paths. Request bodies and WebSocket messages need
`request_body_credential_rewrite` / `websocket_credential_rewrite` on the endpoint.
Cookies are never rewritten, and a placeholder sent anywhere else is rejected.

### Add a secret for another service

Write a provider profile that names the variable, where the secret may be sent,
and which programs may send it:

```yaml
# my-api.yaml
id: my-api
display_name: My API
description: Token for api.example.com
credentials:
  - name: token
    env_vars: [MY_API_TOKEN]
    required: true
    auth_style: bearer
    header_name: authorization # required for bearer
discovery:
  credentials: [token]
endpoints: # the only places the secret is ever sent
  - host: api.example.com
    port: 443
    protocol: rest
    access: read-only # or explicit method/path rules
    enforcement: enforce
binaries:
  - /usr/bin/curl # programs allowed to reach those endpoints
```

```sh
openshell profile lint -f my-api.yaml
openshell profile import --global -f my-api.yaml

set -gx MY_API_TOKEN ...   # read from the shell, so the value is not on the command line
openshell provider create --name my-api --type my-api --from-existing

openshell sandbox create ... --provider claude --provider my-api -- claude
# or, on a running sandbox (start a new agent process to get the variable):
openshell sandbox provider attach claude-dev my-api
```

Rotate the secret with `openshell provider update my-api --from-existing`.

### GitHub

[`providers/github.yaml`](providers/github.yaml) is NVIDIA's example GitHub
profile, copied unchanged from the
[OpenShell repository](https://github.com/NVIDIA/OpenShell/blob/main/providers/github.yaml).
It sends `GITHUB_TOKEN` / `GH_TOKEN` only to `api.github.com` (REST and GraphQL,
read-only) and `github.com` (clone and fetch), for `git` and `gh`. **Push is
denied.** The image has `git` at `/usr/bin/git`, which the profile lists; `gh` is
not installed.

```sh
openshell profile import --global -f providers/github.yaml

set -gx GITHUB_TOKEN github_pat_...   # a fine-grained token with minimal scope
openshell provider create --name github --type github --from-existing

openshell sandbox create --name claude-dev --from openshell-claude:latest \
  --provider claude --provider github --policy policy.yaml -- claude
```

`git` does not read `GITHUB_TOKEN` by itself. Public repositories clone without
it; for private ones, configure a credential helper inside the sandbox that
answers with the placeholder, which the proxy resolves in the Basic auth header:

```sh
git config --global credential.https://github.com.helper \
  '!f() { echo username=x-access-token; echo "password=$GITHUB_TOKEN"; }; f'
```

With this provider attached, the `github_clone` example in `policy.yaml` is not
needed. To allow pushing to a single repository, add a repository-scoped rule for
`git-receive-pack` to the policy, as in NVIDIA's
[GitHub push tutorial](https://docs.nvidia.com/openshell/latest/tutorials/github-push-access).

### Limits

- **An endpoint that echoes requests back leaks the secret.** Because placeholders
  are resolved in query parameters and paths, an allowed endpoint that echoes the
  request, quotes parameters in error messages, or stores data the agent can read
  back returns the real value. With an echo service (httpbin.org) as the endpoint,
  `?leak=$TOKEN` came back as the real token. List only the hosts that need the
  secret, narrow them with method/path rules, and use least-privilege tokens.
- **Only HTTP(S) requests to the profile's endpoints can carry the real value.** SSH
  keys (git over SSH), database passwords over raw TCP, and secrets used locally
  (to decrypt or sign files) cannot be hidden — the process needs the real value.
  Use short-lived, narrowly scoped credentials for those, or keep that work outside
  the agent.

## Troubleshooting

- **Claude cannot reach the API.** The `claude` binary must be at a path listed in
  the profile's `binaries`. An `npm install -g` install runs from `node_modules`
  instead; either use the native installer as the `Dockerfile` does, or add that
  path to your copy of the profile.
- **The sandbox stays in `Provisioning`.** Run `openshell sandbox get <name>` and
  look for a `ConfigurationInvalid` condition; fix the policy or provider and the
  sandbox continues without being recreated.

## References

- [OpenShell documentation](https://docs.nvidia.com/openshell/latest/)
- [Run Your First Agent](https://docs.nvidia.com/openshell/latest/about/run-your-first-agent)
- [Providers](https://docs.nvidia.com/openshell/latest/how-it-works/providers/overview)
- [Manage Sandboxes](https://docs.nvidia.com/openshell/latest/how-it-works/sandboxes/overview)
- [Policy advisor](https://docs.nvidia.com/openshell/latest/how-it-works/policies/advisor)
- [`claude-code.yaml` provider profile](https://github.com/NVIDIA/OpenShell/blob/main/providers/claude-code.yaml)

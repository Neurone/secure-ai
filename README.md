# Secure AI

Runs AI coding agents inside Docker sandboxes instead of directly on the host, while keeping the normal workflow: you type `claude` or `opencode` in a project directory and get the same tool, behind a hard wall. Currently supported tools:

| Tool | Command | Details |
|---|---|---|
| [Claude Code](https://claude.com/claude-code) | `claude` | [tools/claude-code](tools/claude-code/README.md) |
| [opencode](https://opencode.ai) | `opencode` | [tools/opencode](tools/opencode/README.md) |

## Quick start

With [Docker](https://docs.docker.com/get-docker/) running, from the repository root:

```bash
./sai install        # sets up and builds all sandboxes
```

Open a new shell (or paste the line `sai install` prints), then use the tools as usual from any project directory, e.g.:

```bash
claude               # sandboxed Claude Code
opencode             # sandboxed opencode
```

The first build takes a few minutes (opencode is compiled from source). Logins and settings are kept in the sandbox's own state under `~/.secure-ai/`, never shared with a native install. `./sai uninstall` undoes everything; see [The `sai` command](#the-sai-command) for the rest.

## Why

**An AI agent can read and write anywhere it can reach, and run arbitrary shell commands.** A container puts a hard wall around that: only the project directory and a short, explicit allowlist of mounts are visible inside. **Everything else, `~/.aws`, `~/.ssh`, other cloud CLI configs, your shell environment, simply isn't there.** Tokens for services like `gh` or AWS only get in if you explicitly pass them through.

It doesn't take malice for that to matter, just a wrong command, or a manipulated one:

- A prompt-injection payload hidden in a dependency, README, or fetched file tells the agent to grab `gh auth token` and slip it into a PR description. On the host, that hands over your GitHub session. In the container, `gh` isn't authenticated, so there's nothing to steal.
- Debugging a failing deploy, the agent runs `aws sts get-caller-identity` and pastes the output into a log or commit to explain what's wrong. On the host, that can leak live AWS keys. In the container, `~/.aws` was never mounted, so there's nothing to leak.

Each run is also disposable and reproducible: `--rm` plus a pinned toolchain means stray global installs never accumulate on the host or drift between machines.

## The isolation model

Two rules keep this simple:

1. **The sandboxes are fully isolated from the native installs.** Nothing is shared with a native `claude` or `opencode`: not config, not settings, not login, not sessions, not versions. Both can live side by side on the same machine and never talk to each other. The sandbox never reads, mounts, runs or modifies anything of a native install (the `*-original` commands below are just a convenient name to launch the native one).
2. **Container instances of the same tool share their state, like native processes on one machine.** Each tool keeps its settings, login and data in a plain host directory under `~/.secure-ai/`, mounted into every container of that tool. Whatever you change in one instance (model, effort, theme, login, sessions) is there in the next one, and in the others. Where containers force a difference from several native processes on one machine, the tool's page says how it is handled.

Because the state is a normal directory (not a Docker volume), it is readable and editable from the host, and host-side tools can manage it. For example, [custom-claude-code-settings](https://github.com/Neurone/custom-claude-code-settings) can install its status line into the Claude Code sandbox's directory, see [tools/claude-code](tools/claude-code/README.md#customizing-the-sandbox-with-custom-claude-code-settings).

What the container does get from the host, besides the project directory and the tool's own state directory: a git identity (a copy of `~/.gitconfig` with its `[credential]` sections removed), the host's CA bundle (so HTTPS and corporate TLS proxies work), and the timezone. Nothing else.

## Requirements

- macOS or Linux
- `bash`
- [Docker](https://docs.docker.com/get-docker/), with the daemon running
- `git` (to resolve the latest opencode release, and for the git identity)

A native install of a tool is optional.

## The `sai` command

Everything is driven by one script in the repository root:

```bash
./sai install [claude-code|opencode|all]     # set up the sandboxes
./sai uninstall [claude-code|opencode|all]   # undo it
./sai status [claude-code|opencode|all]      # show what is installed (default: all)
./sai config [tool]                          # show the packages installed in the images
./sai config <tool|all> add|remove <apt|npm> <packages>   # change them and rebuild the image
./sai config <tool|all> reset                # back to the defaults (asks first)
./sai test [lint|suite]                      # run the linter and the test suites (default: all)
./sai help
```

Every command has a one-letter shortcut: `i`, `u`, `s`, `c`, `t`, `h`; `config` also accepts `a` for `add` and `r` for `remove`. All human-readable messages go to stderr, so stdout carries only data (`sai status`, `sai config`).

## Install

```bash
./sai install [claude-code|opencode|all]
```

Without an argument, `sai install` lists the available tools and asks for confirmation (`y` or `yes`) before installing all of them; anything else aborts with exit code 1.

For each selected tool this will:

1. Check the OS and that the Docker daemon is running (it stops here if Docker is installed but not running; if Docker isn't installed at all it only warns).
2. Create `~/.secure-ai/bin/` with a symlink named like the tool (`claude`, `opencode`) to its sandbox wrapper, plus a `<tool>-original` symlink to the native binary if there is one on `PATH`.
3. Prepend `~/.secure-ai/bin` to `PATH` in your shell startup files (whichever of `.zshrc`, `.bashrc`, `.bash_profile`, `.profile` already exist; if none exist, the one matching your `$SHELL` is created), so the sandboxed command resolves before any native install. One block serves all tools.
4. Build the tool's Docker image. Docker's build output is hidden and only shown if the build fails.

A native install is never touched, so its own updater keeps working exactly as before. The symlink/PATH setup is idempotent and skipped when already installed, but the image build always runs: re-running `./sai install` is the supported way to pick up an edit to a Dockerfile. If that rebuild fails on a re-run (e.g. offline) `sai install` warns and keeps the existing image; a fresh install without a working build exits with an error. `sai install` refuses to proceed if it finds a state it can't safely resolve on its own (e.g. a file in the shim directory that isn't a symlink it manages).

New shells pick up the sandboxed commands automatically. To use them in the current shell right away, `sai install` ends with a line to paste: `export PATH="$HOME/.secure-ai/bin:$PATH"; hash -r` when the shim directory is not on the current `PATH` yet, just `hash -r` when it is (bash and zsh cache command locations, so a previously resolved native command would otherwise keep winning).

## Usage

```bash
claude        # sandboxed Claude Code
opencode      # sandboxed opencode
```

If a native install was found at install time, the original, **unconstrained** binary is still reachable:

```bash
claude-original
opencode-original
```

## Uninstall

```bash
./sai uninstall [claude-code|opencode|all]
```

Without an argument it asks for confirmation to uninstall all tools, like `sai install`. It removes the selected tools' shims and, once no shim is left, the `PATH` entry from your shell startup files. Native installs are never modified, so the original commands resolve again as soon as you start a new shell. The sandboxes' state directories under `~/.secure-ai/` are kept (`sai uninstall` says so); delete them manually if you don't need them.

## Status

```bash
./sai status [claude-code|opencode|all]
```

Read-only report (nothing is modified), per tool:

- **shim**: `installed`, `not installed`, `stale` (a symlink that doesn't point to this repository's wrapper, e.g. the repository was moved) or `conflict` (a file that isn't a symlink managed by `sai`).
- **original**: the `<tool>-original` link and its target, `broken` if the native binary it pointed to is gone, or `none`.
- **image**: whether the tool's Docker image is `present`, `not built`, or `docker not found`.
- **state**: whether the tool's state directory under `~/.secure-ai/` exists.

It also lists the shell startup files that hold the `PATH` entry and whether the shim directory is on the `PATH` of the current shell.

## Container components

The apt and npm packages installed in each image are listed in `tools/<tool>/components.conf`, one per line:

```text
<category> <package> [required]     # category: apt or npm; '#' starts a comment
```

Packages marked `required` are needed by the sandbox itself and can't be removed. Your own changes never touch the tracked file: they live in an overlay, `~/.secure-ai/<tool>/components.conf`, with `add <category> <package>` and `remove <category> <package>` lines. The effective list is the defaults plus the additions minus the removals, so a change to the defaults in the repository is still picked up.

```bash
./sai config                          # every tool: effective packages, marked (required), (added) or (removed)
./sai config opencode                 # one tool
./sai config opencode add apt nc,htop # comma separated or several arguments
./sai config opencode remove apt vim
./sai config claude-code remove npm cypress   # an npm package can be named without its version
./sai config all add apt nc           # every tool
./sai config all remove apt vim       # skips the tools that don't list it, warns where it is required
./sai config opencode reset           # drop every customization (asks first) and rebuild with the defaults
./sai config all reset                # the same for every customized tool, with a single confirmation
```

`add` and `remove` need the Docker daemon: they edit the overlay and, if something changed, rebuild the tool's image right away (quiet, like `sai install`). With `all`, everything is validated before any overlay is written, then each tool is edited and rebuilt in turn. When removing, a tool that doesn't list the package is skipped with a message, and a tool where it is `required` gets a warning while the package is removed from the others. Package names are validated, removing a required package or one that isn't in the list is refused for a single tool, and a change that has no effect rebuilds nothing. `reset` deletes the overlay of the named tool, or of every customized tool with `all`, after one confirmation (`y` or `yes`; anything else aborts with exit code 1) and rebuilds the image; tools without customizations are left alone, and if none has any it asks nothing and rebuilds nothing. If a rebuild fails, the overlay change is kept and `sai install <tool>` retries it. The overlay is plain text, so you can also edit it by hand; the change reaches the image at the next `sai config` change or `sai install <tool>`.

## Repository structure

```text
sai                              # entry point: install | uninstall | status | config | test
lib/
├── commands/                    # one file per sai command (install, uninstall, status, config, test)
├── common.sh                    # shared helpers: tool discovery and selection, OS and Docker checks, quiet commands, native lookup, PATH block
├── components.sh                # container components: defaults + overlay, validation, edits, docker build args
├── log.sh                       # log_error, log_warn, log_info, ... (all on stderr)
├── path-utils.sh                # symlink resolution helper
└── runtime.sh                   # shared wrapper building blocks: timezone, CA bundle, SELinux, gitconfig, base docker run flags
tools/
├── claude-code/                 # claude.sh (wrapper), tool.sh (names, state dir, image build), components.conf (packages),
│   └── container/               # Dockerfile + entrypoint
└── opencode/                    # opencode.sh, tool.sh, components.conf, container/ (Dockerfile, entrypoint, banner plugin)
tests/
├── lib/harness.sh               # assertions, fake docker/git/security/uname/shellcheck, run helpers
├── test-sai.sh                  # sai dispatcher: usage, help, shortcuts, unknown commands, the lint step
├── test-install.sh              # sai install / sai uninstall
├── test-status.sh               # sai status
├── test-config.sh               # sai config: show, add, remove, refusals, rebuilds
├── test-runtime.sh              # lib/runtime.sh building blocks: the filtered gitconfig
├── test-claude-code.sh          # Claude Code wrapper + entrypoint
└── test-opencode.sh             # opencode wrapper, image logic + entrypoint
```

Adding a tool means adding a `tools/<name>/` directory with a `tool.sh` (binary name, wrapper, Dockerfile, state directory, image reference `TOOL_IMAGE_REF`, `tool_rebuild_image`), a `components.conf`, and a wrapper built from `lib/runtime.sh`. `sai` discovers tools from the `tools/*/tool.sh` files; the image build passes `component_build_args` to `docker build` and the Dockerfile declares `ARG APT_PACKAGES` and `ARG NPM_PACKAGES`.

## Tests

```bash
./sai test           # the linter, then all suites
./sai test lint      # only the linter: shellcheck on every shell script
./sai test status    # a single suite: sai, install, status, config, runtime, claude-code or opencode
```

The linter runs [ShellCheck](https://www.shellcheck.net) on `sai` and every `*.sh` file, with the options in `.shellcheckrc`; a warning that is a false positive is silenced on its own line with a `# shellcheck disable=...` comment saying why. The test suites cover the wrappers, `sai install`, `sai uninstall`, `sai status`, `sai config` and the container entrypoints with fake `docker`, `git`, `security`, `uname` and `shellcheck` executables, so it needs no Docker daemon, no network, no macOS keychain and no installed claude or opencode. The scenarios without a native install strip any real `claude`/`opencode` from `PATH`, so they behave the same on a machine that has them. Running `sai test` requires `jq` and `shellcheck`.

## License

[MIT](LICENSE)

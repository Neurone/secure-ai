# Claude Code sandbox

Runs [Claude Code](https://claude.com/claude-code) inside a Docker sandbox. See the [top-level README](../../README.md) for the rationale, install/uninstall and the isolation model; this page covers what is specific to Claude Code.

```bash
./sai install claude-code    # from the repository root
claude                       # sandboxed
claude-original              # the native, unconstrained binary, if one was found at install time
```

## Isolated from the native install

The sandboxed `claude` shares nothing with a native one: not `~/.claude`, not `~/.claude.json`, not the login (the macOS Keychain entry or `~/.claude/.credentials.json`), not the version. It never runs the native binary either. Both can be used side by side, each with its own login, settings and sessions. The first time you start the sandbox it has no login: sign in inside the container, and it is remembered for every following run.

## Where the state lives

Everything Claude Code keeps (settings, login, `.claude.json`, sessions, agents, commands, plugins, ...) is in one host directory, `~/.secure-ai/claude-code/config/`:

- It is mounted into every container at the **same absolute path** and handed to Claude Code through `CLAUDE_CONFIG_DIR`, so absolute paths stored in it (for instance a status line command) resolve both on the host and in the container.
- It is shared by all the sandbox instances you run, like one native config shared by several native processes: a model or effort change, a theme, a login, a new session in one instance is visible to the others.
- It is a whole-directory bind mount, which matters: Claude Code saves some files (settings, credentials) through a temp-file-then-rename, and `rename()` onto a single bind-mounted *file* fails with `EBUSY`. Mounting just `settings.json` would silently lose settings saved that way, such as the selected model and effort.
- You can read and edit it from the host (`~/.secure-ai/claude-code/config/settings.json`, `CLAUDE.md`, `agents/`, ...).

The Claude Code binary itself lives in a Docker volume (`secure-claude-code-local`, mounted at `/home/node/.local`): it starts at the version baked into the image, and Claude Code's own updater manages it from there like a native install's (`claude update` inside the sandbox updates it on demand). The sandbox does not follow any native version. The image is built once; re-run `./sai install claude-code` to rebuild it after a Dockerfile change (`sai config claude-code` rebuilds it itself after a package change).

## Other details

- Several instances can run at once on the same or different projects; they share the config directory (and its lock files, which live in it). Claude Code's `~/.claude.json` is inside that directory too, so, unlike with a native `~/.claude.json` mounted from the host, the concurrent-write lock is shared by all containers.
- `ANTHROPIC_API_KEY` and `ANTHROPIC_MODEL` are passed through from the host environment when set. Nothing else from your environment is.
- A `--settings` layer adds a "Docker sandbox" announcement so you can tell the sandbox from `claude-original`; it is never written to the config directory.
- What is mounted: the project directory (same path), the config directory, a git identity (a copy of `~/.gitconfig` without its `[credential]` sections), the host CA bundle (read-only), and the timezone.
- No host hooks, plugins or `~/.claude` content are available in the sandbox. Configure what you need inside it (it lands in the config directory), or install host-side tooling into that directory, see below.

## Customizing the sandbox with custom-claude-code-settings

[custom-claude-code-settings](https://github.com/Neurone/custom-claude-code-settings) installs and keeps a set of settings (status line, attribution, ...) in a Claude config directory. Point it at the sandbox's one:

```bash
CLAUDE_CONFIG_DIR=~/.secure-ai/claude-code/config scripts/install-or-update.sh
```

It then manages the sandbox's `settings.json` without touching the native `~/.claude`: a separate watchdog service (its label is derived from the directory) is created next to the native one if you have both. Because the directory is mounted at the same path in the container, the status line script it installs runs there as well.

## Layout

```text
claude.sh                       # the wrapper installed as 'claude'
tool.sh                         # names, state directory, image rebuild
components.conf                 # default apt and npm packages of the image
container/
├── Dockerfile.claude-code      # node:24-slim + claude (native install) + the components.conf packages
└── docker-entrypoint.sh        # login hint, then exec claude
```

The image's packages come from `components.conf` and your overlay (see [Container components](../../README.md#container-components)): change them with `sai config claude-code`, not by editing the Dockerfile's package lists. Other Dockerfile edits are applied by re-running `./sai install claude-code`.

# opencode sandbox

Runs [opencode](https://opencode.ai) inside a Docker sandbox. See the [top-level README](../../README.md) for the rationale, install/uninstall and the isolation model; this page covers what is specific to opencode.

```bash
./sai install opencode       # from the repository root
opencode                     # sandboxed
opencode-original            # the native, unconstrained binary, if one was found at install time
```

## Isolated from the native install

The sandboxed `opencode` shares nothing with a native one: not its config, data, state or cache directories, not `OPENCODE_CONFIG`, not the `XDG_*` variables, and it is not even built from the same binary (it is compiled from upstream source inside the image). Both can be used side by side, each with its own config, credentials, sessions and plugins. Provider credentials are entered inside the sandbox (`opencode auth login`) or not at all, see [Credentials](#credentials).

## Where the state lives

opencode's four directories are host directories of the sandbox, under `~/.secure-ai/opencode/`, each mounted whole, read/write, at the usual path in the container (`HOME=/home/node`):

| Host | Container | Holds |
|---|---|---|
| `config/` | `~/.config/opencode` | `opencode.json(c)`, `cli.json` (theme, keybinds, plugin list), the background-service config, `agents/`, `commands/`, `plugins/`, `skills/`, `themes/` |
| `data/` | `~/.local/share/opencode` | the session database (in v2 it also holds the provider credentials), logs |
| `state/` | `~/.local/state/opencode` | UI state (selected model, prompt history), file locks |
| `cache/` | `~/.cache/opencode` | npm-installed plugins |

They are shared by every sandbox instance and can be read and edited from the host. Whole-directory mounts also let opencode save files through `rename()` (which fails on a bind-mounted single file).

Things to know:

- Several instances at once: natively, all opencode instances on a machine share one background service, registered in the `state/` directory. Containers don't share a network or process namespace (and a shared service could only see the project directories mounted into its own container), so the entrypoint starts every instance with its own private server (`--standalone`, for the commands that have the flag; not if you pass `--server` yourself). Sessions, config and credentials are still shared through the mounted directories, so any instance can open and continue the sessions of the others, as with native processes on one machine.
- Skills: opencode also reads skills from the home-level `~/.claude/skills` and `~/.agents/skills`; the sandbox's home only contains the four directories and the project, so keep skills under the sandbox's `config/skills/` or the project's `.opencode/skills/`.
- Plugins: configured plugins that are npm packages or paths relative to a config file work as usual. Plugins at absolute host paths are not reachable, since the sandbox mounts nothing from the host besides what is listed here: put such a plugin under the sandbox's `config/plugins/`.
- Version skew: the container runs the opencode version the image was built from. `opencode.sh` checks `github.com/anomalyco/opencode` for the latest stable tag of the pinned major line (`OPENCODE_MAJOR` in `tool.sh`, currently `2`; pre-release/CI tags ignored) on every launch and rebuilds when a newer release is out; offline, or if the build fails, it continues on the last successful build with a warning. A stable release of the *next* major only prints a notice.

## Other details

- The "you are in a sandbox" banner is a plugin baked into the image at `/opt/sandbox-banner`, declared by the entrypoint through `OPENCODE_CONFIG_CONTENT` (unioned with your own plugin list, never written into the config directory); `opencode-original` never shows it.
- `--add-host=host.docker.internal:host-gateway` is always added so a provider on a local server stays reachable, see [Local providers](#local-providers).
- Mounted into the container: the project directory (same path), the four directories, a git identity (a copy of `~/.gitconfig` without its `[credential]` sections), the host CA bundle (read-only), and the timezone.

### Credentials

No provider API-key environment variable is forwarded into the container. The only credentials inside are the ones you enter in the sandbox itself: in v2 they live in the session database in the sandbox's `data/` directory, so a compromised sandboxed opencode could read them, but never the credentials of your native opencode or anything else on the host. If you don't want the sandbox to hold real provider credentials, use a local provider that needs none (see below).

### Local providers

This setup is built with a local model provider in mind: LM Studio, Ollama, or any other server running on the host that needs no account. In the sandbox `opencode.json`, a provider's `baseURL` can't be hardcoded to `localhost` (the container's own loopback) or to `host.docker.internal` (undefined where you run natively). Use opencode's `{env:VAR}` substitution, so the same file resolves differently in each context:

```jsonc
{
  "providers": {
    "lmstudio": {
      "settings": {
        "baseURL": "{env:OPENCODE_LMSTUDIO_BASEURL}"
      }
    }
  }
}
```

`opencode.sh` always sets `OPENCODE_LMSTUDIO_BASEURL` to `http://host.docker.internal:$SECURE_OPENCODE_LMSTUDIO_PORT/v1` (port defaults to `1234`, LM Studio's default, overridable via the `SECURE_OPENCODE_LMSTUDIO_PORT` environment variable). In a native run an unset variable substitutes to an empty string, which opencode treats as no override, so the provider falls back to its built-in default (`http://127.0.0.1:1234/v1`); export the variable only if your LM Studio listens elsewhere.

**Known limitation**: `--add-host=host.docker.internal:host-gateway` does not scope down *which* host ports are reachable; it is only needed at all on Linux, where the hostname isn't resolved by default. On Docker Desktop (macOS/Windows), `host.docker.internal` is reachable from any container regardless of this flag, so the sandbox can reach any host port this way, not just your provider's. A single-purpose proxy container that only forwards one port was tried and doesn't help, for the same reason. Actually restricting this would require running the container as root with `--cap-add=NET_ADMIN` to set a firewall rule before dropping to the unprivileged user, a real change to the privilege model that is not implemented here.

## Layout

```text
opencode.sh                     # the wrapper installed as 'opencode'
tool.sh                         # names, state directories, upstream release + image build logic
components.conf                 # default apt and npm packages of the image
container/
├── Dockerfile.opencode         # multi-stage: compiles opencode from upstream source into a node:24-slim image with the components.conf packages
├── entrypoint.sh               # declares the banner plugin, runs opencode, forwards signals
└── plugins/sandbox-banner/     # the "you are in a sandbox" indicator plugin (index.js, tui.js)
```

The final image's packages come from `components.conf` and your overlay (see [Container components](../../README.md#container-components)): change them with `sai config opencode`, not by editing the Dockerfile's package lists. The builder stage's own packages (git, ca-certificates) are fixed, as they are not in the final image. Other Dockerfile edits are applied by re-running `./sai install opencode`.

## License

MIT, like the rest of the repository. The banner plugin and the wrapper are original work. The `opencode` binary inside the image is compiled from [upstream opencode](https://github.com/anomalyco/opencode) source and remains under its own license.

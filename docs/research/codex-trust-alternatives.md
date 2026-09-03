# Codex card startup trust research

Date: 2026-09-03
Local CLI checked: `codex-cli 0.152.0`

## Conclusion

Codex does not currently document an ephemeral “trust this cwd” switch. Project trust is a path-keyed setting, `projects."<path>".trust_level = "trusted"`, and the startup prompt is a separate boundary from command approvals, sandbox mode, and hook trust. The current 0.152.0 remote-TUI probe still showed the prompt when both the app-server and TUI were given a launch-local `-c projects."<cwd>".trust_level="trusted"` override; this is empirical evidence that profiles/`-c` do not solve this startup path, not a documented promise about all future releases.

Codex’s own remote-TUI flow uses `config/batchWrite` to make this same persistent per-path edit. That would be a useful future refinement if Orchestra adds a pre-TUI app-server RPC seam, but it adds socket-readiness and version-conflict choreography without changing the user-visible state. For the current adapter-only fix, an adapter-owned atomic write of the same native key is the smaller integration. A private `CODEX_HOME` is the only documented way to avoid mutating the user’s normal config, but it also isolates all Codex state and credentials.

## Documented facts

- `projects.<path>.trust_level` accepts `"trusted"` or `"untrusted"`; an untrusted project skips project-scoped `.codex` config, hooks, and rules. The project entry is therefore path-scoped in the user configuration, not a per-agent profile toggle. ([Config Reference](https://learn.chatgpt.com/docs/config-file/config-reference))
- The normal layer order is system, user `${CODEX_HOME}/config.toml`, selected profile, project layers (only when trusted), then runtime/CLI overrides. Profiles layer `${CODEX_HOME}/<name>.config.toml`; `-c`/`--config` is a one-off override. ([Config Basics](https://learn.chatgpt.com/docs/config-file/config-basic), [Advanced Config](https://learn.chatgpt.com/docs/config-file/config-advanced))
- `-C`/`--cd` selects the working root. It does not declare trust. `--approve-for-me` and `--dangerously-bypass-approvals-and-sandbox` concern command approval/sandbox behavior; `--dangerously-bypass-hook-trust` concerns persisted hook trust. None is documented as a directory-trust bypass. ([CLI command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli))
- `CODEX_HOME` defaults to `~/.codex` and is the state root for config, auth, logs, sessions, and related state. Setting it per card can isolate the config, but also creates an isolated Codex installation state. ([Environment Variables](https://learn.chatgpt.com/docs/config-file/environment-variables))
- App-server supports `thread/start`/`turn/start` cwd, approval, and sandbox parameters, but the documented protocol has no trust parameter or trust-specific request. It does document generic `config/value/write` and `config/batchWrite`; with no `filePath`, those write the user config and support `expectedVersion`. ([App Server](https://learn.chatgpt.com/docs/app-server))

## Native implementation evidence

The official `rust-v0.152.0` source shows the exact behavior behind the prompt:

- The config loader’s layer order places `${CODEX_HOME}/config.toml` and profiles below project layers, and marks project layers disabled when the project has no trusted decision. ([loader source](https://github.com/openai/codex/blob/rust-v0.152.0/codex-rs/config/src/loader/mod.rs#L101-L113))
- The TUI’s remote trust helper reads `config/read` with `include_layers`, identifies the disabled project and its trust target, and returns a remote trust action when no explicit decision exists. ([TUI config-update source](https://github.com/openai/codex/blob/rust-v0.152.0/codex-rs/tui/src/config_update.rs#L187-L292))
- Its trust action constructs `projects."<escaped absolute path>".trust_level = "trusted"` and sends `config/batchWrite`; `file_path: None` means the app-server’s user config is the target. ([TUI config-update source](https://github.com/openai/codex/blob/rust-v0.152.0/codex-rs/tui/src/config_update.rs#L57-L69), [batch-write protocol](https://github.com/openai/codex/blob/rust-v0.152.0/codex-rs/tui/src/config_update.rs#L147-L169))
- The protocol defines `config/value/write` and `config/batchWrite` with optional target file and expected-version fields, but no separate project-trust RPC. ([app-server config protocol](https://github.com/openai/codex/blob/rust-v0.152.0/codex-rs/app-server-protocol/src/protocol/v2/config.rs#L965-L998))
- The local 0.152.0 binary’s help/schema matches this surface: it exposes `--profile`, `-c`, `--cd`, `--remote`, approval/sandbox flags, and hook-trust bypass, but no trust flag; generated app-server schema lists config read/write and project operations, but no trust operation.

## Options and tradeoffs

| Option | Assessment |
| --- | --- |
| App-server `config/batchWrite` preflight | A future refinement if Orchestra gains a pre-TUI app-server config client. It follows Codex’s own remote-TUI implementation and lets Codex serialize/validate the edit, but still persists the exact per-path decision in the user config and adds startup RPC ordering/concurrency work. |
| Codex-native adapter config writer | Selected for this fix. Keep the core cwd-trust resolver unchanged and write only the Codex-native path entry with an in-process lock plus an atomic file replacement; the cost is direct mutation of shared user state. |
| Private per-card `CODEX_HOME` | Avoids touching the normal `~/.codex/config.toml`, but isolates auth, sessions, logs, history, caches, and other state. It also requires careful environment propagation to both app-server and TUI, and auth/keychain behavior must be verified. |
| Project `.codex/config.toml` | Cannot bootstrap trust: official docs say project layers are loaded only once the directory is trusted. |
| Profile, `-c`, `-C`, approval flags, or `thread/start`/`turn/start` fields | Not a documented trust bypass; the controlled 0.152.0 remote launch confirmed that profile/server/client one-shot trust overrides still prompted. |

## Recommendation

Use the Codex-native adapter writer for this fix: it persists the same path-scoped trust decision that Codex would write after the prompt, without changing Orchestra’s shared cwd-trust resolver or adding launch ordering. Consider `config/batchWrite` only if a provider-side configuration client is introduced for other reasons. Do not use `--yolo` or hook-trust bypass flags as substitutes. Choose per-card `CODEX_HOME` only if “never mutate the user config” is a hard requirement and isolated Codex state is acceptable.

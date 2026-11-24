# Codex Supervisor

A macOS monitor for AI agents using the original SwiftUI and AppKit interface from [Codex Pacer 4.6.2](https://github.com/RyanZhangNTU/codex-pacer/tree/8fa3ccf9a17e0a6a7fc8ac13291152c971908b99). It retains the Dynamic Island, Overview, History and Settings. [简体中文](README.zh-CN.md)

| Module | Signals |
| --- | --- |
| Codex, Claude Code, DeepSeek Harness and WorkBuddy | The upstream task and usage integrations |
| Cursor | Local Agent transcript activity and explicit turn outcomes |
| Grok Bot | Local desktop heartbeat |
| Antigravity | Recent writes to local conversation databases |
| Muse | Five-hour and weekly Muse Code subscription allowance from the official CLI, or a dated manual reading |

Grok Bot and Antigravity signals appear in Overview. Cursor turns appear in the original task list. Muse uses the same quota rings as Codex and Claude, including the Island and Overview. Settings → Module Library shows which integrations are available.

## Build and run

Requires macOS 14 or later and Xcode 26 or later.

```sh
make build
```

The script prints the path to `Codex Supervisor.app`. The local build is ad hoc signed. The bundle and its settings are separate from upstream Codex Pacer. Both apps use the same underlying provider integrations, so quit Pacer before using Supervisor to manage agent hooks or progress reporters. Supervisor's automatic app updates are disabled.

To preview the original interface with example data, use the app path printed by the build:

```sh
open -na "/path/to/Codex Supervisor.app" --args --demo --demo-supervisor
```

## Muse quota

Install and sign in to [Muse Code](https://dev.meta.ai/docs/muse-code), then check that `muse usage` reports your [subscription allowance](https://dev.meta.ai/docs/muse-code/subscriptions). Supervisor checks the installed CLI every five minutes while the Muse module is on. Overview → Refresh also requests a reading.

The Meta Muse desktop app and Muse Code have separate usage sources. For a manual reading, place a file named `muse-quota.json` in `~/.config/codex-supervisor/` or the data folder chosen in Settings → Muse. Include only windows with a known remaining percentage. The date is the time you recorded the reading. Replace the example dates and percentages with your own values.

```json
{
  "observedAt": "2026-11-24T07:00:00Z",
  "fiveHour": { "remainingPercent": 74, "resetsAt": "2026-11-24T11:00:00Z" },
  "weekly": { "remainingPercent": 62 }
}
```

Manual readings are labeled in the UI and keep their original timestamps. A readable CLI result takes precedence.

## License

The project retains the upstream [MIT license](LICENSE). The source, interface, documentation and build tooling originate from Codex Pacer. Bundled dependencies retain their own license notices.

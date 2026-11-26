# Codex Supervisor

Codex Supervisor 是 macOS 上的 AI 工具监控应用。项目基于 [Codex Pacer 4.6.2](https://github.com/RyanZhangNTU/codex-pacer/tree/8fa3ccf9a17e0a6a7fc8ac13291152c971908b99) 源码，保留原版灵动岛、总览、历史和设置界面。[English](README.md)

| 服务 | 监控内容 |
| --- | --- |
| Codex、Claude Code、DeepSeek Harness、WorkBuddy | 沿用 Pacer 原有的任务和用量接入 |
| Cursor | 本机 Agent 会话活动和已记录的任务结束状态 |
| Grok Bot | 本机桌面应用心跳 |
| Antigravity | 本机会话的明确运行状态和近期活动 |
| Muse | 官方 Muse Code CLI 的五小时和每周额度，或带时间的手动读数 |

Cursor 和 Antigravity 的任务活动沿用原版列表，Grok Bot 心跳显示在总览。Muse 在总览和灵动岛里使用原版额度环，也可以从设置进入 Muse 服务页。可用服务可以在「设置 → 模块库」查看。

## 构建并使用

需要 macOS 14 或更新版本，以及 Xcode 26 或更新版本。

```sh
make build
```

构建会输出 `Codex Supervisor.app` 的路径。产物使用本机临时签名。应用设置与 Pacer 分开。两款应用沿用相同的服务接入目录，如果要由 Supervisor 管理任务钩子或进度工具，先退出 Pacer。当前分支未启用应用自动更新。

要用示例数据预览界面，把命令中的路径替换为构建产物路径。

```sh
open -na "/path/to/Codex Supervisor.app" --args --demo --demo-supervisor
```

## Muse 额度

安装并登录 [Muse Code](https://dev.meta.ai/docs/muse-code)，在终端运行 `muse usage` 确认账户能读到[订阅额度](https://dev.meta.ai/docs/muse-code/subscriptions)。Muse 模块开启时，应用每五分钟读取一次，也可以在总览手动刷新。

Muse 桌面版与 Muse Code 订阅的额度来源不同。如果要录入手动读数，可将 `muse-quota.json` 放在 `~/.config/codex-supervisor/`，或放在「设置 → Muse」指定的数据目录。按下面格式填入实测百分比和记录时间，只填写已知的窗口。

```json
{
  "observedAt": "2026-11-24T07:00:00Z",
  "fiveHour": { "remainingPercent": 74, "resetsAt": "2026-11-24T11:00:00Z" },
  "weekly": { "remainingPercent": 62 }
}
```

手动读数保留原记录时间。在 CLI 可以提供订阅额度时，界面优先显示 CLI 读数。

## 许可证

保留上游 [MIT 许可证](LICENSE) 和依赖的许可证声明。界面、基础源码与构建脚本来自 Codex Pacer。

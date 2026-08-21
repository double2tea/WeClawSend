# WeClaw Send for DaVinci Resolve

Deliver 后渲染自动发送。渲染结束后通过 WeClaw Send 本地接口发送输出文件。

## 入口

| 入口 | 文件 | 说明 |
|---|---|---|
| **WeClawSend_Lua**（推荐） | `WeClawSend_Lua.lua` | 用 `/usr/bin/curl` 调本地接口，**不需要 Python** |
| **WeClawSend_Python**（可选） | `WeClawSend_Python.py` | Resolve 内直接执行；仅在需要 Python 宿主脚本时使用 |

两者功能相同。MP4/M4V **显示名**由 App「发送时 .mp4 显示为 .m4v」处理。

默认安装 dual，在 Deliver「触发脚本」里二选一；日常推荐 **Lua**。

## 安装

```sh
# 默认 both
./scripts/install-davinci-plugin.sh

./scripts/install-davinci-plugin.sh both
./scripts/install-davinci-plugin.sh lua
./scripts/install-davinci-plugin.sh python
./scripts/install-davinci-plugin.sh auto
```

路径：

```text
~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Deliver/
/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Deliver/   # 可写时
```

安装会清理旧名：`自动发送ClawBot_*`、`WeClawSend.lua`、`weclaw_postrender_send.py` 等。

安装后：

1. WeClaw Send 开启「本地接口」
2. 可选开启「API 文件先进入文件篮」；开启后渲染结果先进入最近文件篮，由用户确认发送
3. **完全退出并重启** DaVinci Resolve
4. Deliver → 高级设置 → 渲染作业结束时触发脚本 → 优先选 `WeClawSend_Lua`

## 行为

- 日志：`~/.davinci-clawbot-postrender.log`
- 去重：`~/.davinci-clawbot-postrender-state`
- **Resolve 21 及更高版本：使用脚本自动发送前必须关闭「偏好设置 → 后台任务 → 启用后台渲染」。**开启后 `BgRenderManager` 回调可能缺少 Deliver `JobId`、状态和错误上下文，导致自动发送无法可靠工作。该问题已向 Blackmagic Design 提交（工单 `DEV-11860`），等待官方修复。
- 接口契约见 [`../docs/INTEGRATION.md`](../docs/INTEGRATION.md)

# WeClaw Send for DaVinci Resolve

DaVinci Resolve Deliver 后渲染自动发送脚本。渲染成功后，脚本通过 WeClaw Send 本地接口发送输出文件。

## 脚本

| 脚本 | 行为 |
|---|---|
| `自动发送ClawBot_M4V文件.py` | 将非 `.m4v` 输出复制为临时 `.m4v` 文件后发送 |
| `自动发送ClawBot_MP4视频.py` | 只接受 `.mp4` 输出，直接发送原文件 |

脚本文件名沿用现有名称，以便覆盖安装并保持 DaVinci 中已有配置不变。

## 安装

要求：macOS、DaVinci Resolve，以及已登录微信的 WeClaw Send。

```sh
./scripts/install-davinci-plugin.sh
```

脚本会安装到：

```text
~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Deliver/
```

安装后重启 DaVinci Resolve。在 WeClaw Send 的设置中打开「启用本地接口」，然后在 Deliver 页选择需要的后渲染脚本。

## 行为与限制

- 单文件最大 200 MB。
- 脚本等待 WeClaw Send 完成发送后，才记录去重状态并通知成功。
- M4V 临时文件位于 `~/.davinci-weixin-send`，超过 1 天的旧缓存会被清理。
- 日志位于 `~/.davinci-clawbot-postrender.log`。
- 去重状态沿用 `~/.davinci-clawbot-postrender-state`，避免迁移后重复发送历史输出。
- 不再需要旧的 Node bridge 或独立 WeClaw 服务。

本地接口契约见 [`../docs/INTEGRATION.md`](../docs/INTEGRATION.md)。

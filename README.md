# WeClaw Send

原生 macOS 菜单栏微信文件发送器。应用内直接完成扫码登录、加密上传与发送，**不依赖** WeClaw、OpenClaw、Node/Go 后台或其它命令行工具。

```text
菜单栏拖放 / 选择文件
  → WeClaw Send.app
  → 微信 iLink + 加密 CDN
  → 微信
```

## 功能

- 拖到菜单栏图标或面板内发送；支持多文件排队
- **实时进度**：准备 → 加密 → 上传 CDN → 提交消息
- **最近传输记录**（最多 20 条，含失败原因）
- **应用内微信扫码登录**（凭据保存在 Application Support 的 `credentials.json`，权限 `0600`；Keychain 仅用于旧版迁移）
- **登录时自动启动**（系统登录项）
- **可选 .mp4 → .m4v 附件名**（只改微信显示名，不改本地文件）
- 可在设置中启停本地接口 `http://127.0.0.1:18790`（默认关闭，菜单栏发送不依赖它）
- **DaVinci Resolve 后渲染脚本**：渲染成功后自动发送，可选 M4V 文件或 MP4 视频模式
- **Premiere Pro 25.6+ UXP 面板**：可选在本次导出成功后自动发送
- 设置页提供 GitHub 与邮件联系图标（`double_tea@foxmail.com`）
- 微信会话受限时按需等待用户消息，自动刷新上下文并重试原文件

## 给朋友使用（推荐）

**可以直接把 `.app` 拖进「应用程序」**，不必跑脚本。

完整说明与打不开时的解决方法见：

**[docs/使用说明.md](docs/使用说明.md)**

生成同时支持 Apple Silicon 与 Intel 的分享包：

```sh
./scripts/release.sh
```

产物包括 `dist/WeClaw-Send.dmg`、`dist/WeClaw-Send.zip` 和 `dist/SHA256SUMS.txt`。DMG 与 ZIP 均内含 App 和可直接双击查看的图解版 `使用说明.html`。由于当前没有 Developer ID 签名，朋友首次打开时需要在 **系统设置 → 隐私与安全性** 中手动批准。

## 开发者安装

macOS 14+，需本机 Swift 工具链。

```sh
chmod +x scripts/*.sh
./scripts/install.sh
```

安装到 `$HOME/Applications/WeClaw Send.app` 并启动。

1. 点击菜单栏纸飞机图标
2. 打开 **设置**
3. **扫码登录** 微信
4. 返回主界面拖放或选择文件发送

## 使用摘要

| 操作 | 说明 |
|---|---|
| 拖放发送 | 拖到菜单栏图标，或打开面板后拖到虚线区域 |
| 选择文件 | 面板内「选择文件…」 |
| 查看进度 | 「最近传输」列表实时显示百分比与阶段 |
| 重新登录 | 设置 → 扫码登录 / 重新登录 |
| 开机自启 | 设置 → 登录时自动启动 |
| mp4 改名 | 设置 → 发送时将 .mp4 显示为 .m4v |
| 本地接口 | 设置 → 启用本地接口 |

限制：单文件最大 200 MB；发送间隔冷却 60 秒（排队自动等待）。

微信 iLink 的主动发送还受会话窗口和消息额度限制。腾讯公开实现要求把用户入站消息中的 `context_token` 回传给后续发送，但没有公布正式有效期与额度数值；其公开仓库反馈中常见约 24–48 小时无入站消息后失效、同一上下文约 10 条主动回复。若发送返回 `ret=-2`，App 会提示用户给 ClawBot 发任意消息，按需等待新的 `context_token`，保存后自动重试原文件；面板关闭时同时发送 macOS 通知。等待 5 分钟仍未收到消息会明确失败，不会持续轮询。参见腾讯仓库的 [会话限制反馈](https://github.com/Tencent/openclaw-weixin/issues/202) 与 [`ret=-2` 反馈](https://github.com/Tencent/openclaw-weixin/issues/225)。

排障见 [docs/使用说明.md](docs/使用说明.md)。

## 可选：本地 HTTP 接口

仅当需要从脚本 / 剪辑软件自动化发送时使用。日常菜单栏操作**不需要**。接口只绑定 IPv4 回环地址 `127.0.0.1`，不对局域网开放。
接口默认关闭，可在应用的「设置」中随时开启或关闭，选择会在下次启动时保留。

`/health` 中 `wechat_connected` 仅表示当前凭据已通过微信服务校验；`/send` 成功响应的 `queue_wait_ms` 仅计算请求到达后等待发送槽位的时间，不包含加密、上传和提交消息。

完整契约、错误码与多语言示例见 **[docs/INTEGRATION.md](docs/INTEGRATION.md)**。

```http
GET /health
POST /send
Content-Type: application/json

{
  "file_path": "/absolute/path/to/file.m4v",
  "file_name": "中文文件名.m4v"
}
```

## DaVinci Resolve 插件

后渲染脚本位于 [`davinci-resolve`](davinci-resolve)。安装后，在 Deliver 页选择需要的脚本；渲染成功时会把输出交给 WeClaw Send。

```sh
./scripts/install-davinci-plugin.sh
```

使用前需要在 WeClaw Send 设置中打开「启用本地接口」。两个发送模式、安装位置和日志说明见 [`davinci-resolve/README.md`](davinci-resolve/README.md)。

## Premiere Pro 插件

插件位于 [`premiere-uxp`](premiere-uxp)，要求 Premiere Pro 25.6+。自动发送默认关闭；关闭时插件只导出，不会调用 WeClaw Send。

```sh
./scripts/build-premiere-plugin.sh
```

构建产物为 `premiere-uxp/dist`。使用 UXP Developer Tool 2.2+ 加载其中的 `manifest.json`，详细步骤见 [`premiere-uxp/README.md`](premiere-uxp/README.md)。插件通过 `weclaw-send://` 本机链接唤起应用，不需要连接码，也不要求开启本地 HTTP 接口。

## 品牌资源

| 资源 | 路径 |
|---|---|
| App 图标 | `Resources/AppIcon.icns` |
| 菜单栏模板图 | `Resources/MenuBarIcon.png` |
| 品牌色 | 墨色简约 `#2A2A2E` → `#121214` |
| 标识 | 仅顶栏小标；首页无重复大 Logo |
| 标识 | 纸飞机（App 图标 / 菜单栏 / 面板） |
| 重新生成图标 | `python3 scripts/generate-icons.py` |

## 开发与验证

```sh
./scripts/test.sh
./scripts/build-app.sh
./scripts/release.sh
./scripts/functional-test.sh
curl http://127.0.0.1:18790/health
```

## 协议说明

微信 iLink 协议实现参考腾讯 [`openclaw-weixin`](https://github.com/Tencent/openclaw-weixin)（MIT）。详见 `THIRD_PARTY_NOTICES.md`。

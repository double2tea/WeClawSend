# WeClaw Send 第三方集成说明

面向希望把 **WeClaw Send** 接到剪辑软件、脚本或自动化流水线的开发者。
菜单栏用户无需阅读本文；日常发送不依赖 HTTP 接口。

## 1. 产品能力边界

| 能力 | 说明 |
|---|---|
| 运行形态 | 独立 macOS 菜单栏应用（`LSUIElement`） |
| 登录 | 应用内扫码；凭据保存在本机 Application Support 文件（`0600`），Keychain 仅用于旧版迁移 |
| 发送入口 A | UI 拖放 / 选择文件 |
| 发送入口 B | 本机 HTTP `127.0.0.1:18790`（可选） |
| 协议 | 腾讯微信 iLink + 加密 CDN |
| 不依赖 | WeClaw / OpenClaw / Node / Go / 其它后台进程 |

**系统要求：** macOS 14+

**限制：**

- 单文件最大 **200 MB**
- 最多同时处理 **3 个文件**
- 加密和 CDN 上传可并行；微信消息提交串行且间隔 **2 秒**
- 接口默认关闭；启用后仅绑定 IPv4 回环地址 `127.0.0.1`，**无鉴权**，不会在局域网接口上监听，请勿转发到公网
- 所有内容以**文件附件**发送（保留中文 / 空格 / emoji 文件名）

## 2. 安装与就绪

```sh
./scripts/install.sh
# 或
./scripts/build-app.sh
open ".build/WeClaw Send.app"
```

1. 用户在菜单栏打开应用 → **设置 → 扫码登录**
2. 在设置中打开「启用本地接口」
3. 集成方轮询健康检查，确认 `wechat_connected == true` 后再发文件

```sh
curl -s http://127.0.0.1:18790/health
```

## 3. HTTP API

Base URL：`http://127.0.0.1:18790`
编码：UTF-8 JSON

### 3.1 `GET /health`

探测服务与登录态。

**200 响应示例：**

```json
{
  "ok": true,
  "service": "weclaw-send",
  "backend": "wechat-ilink",
  "queue_depth": 0,
  "wechat_connected": true,
  "send_cooldown_ms": 2000,
  "max_concurrent_transfers": 3,
  "max_send_bytes": 209715200,
  "last_send_at": "2026-07-14T12:49:26Z"
}
```

| 字段 | 类型 | 含义 |
|---|---|---|
| `ok` | bool | 接口存活 |
| `wechat_connected` | bool | 当前凭据是否已主动调用微信服务并校验成功；仅存在本地凭据文件时不会返回 `true` |
| `queue_depth` | int | 当前排队/处理中任务数 |
| `send_cooldown_ms` | int | 微信消息提交的最小间隔毫秒 |
| `max_concurrent_transfers` | int | 最大并行处理文件数 |
| `max_send_bytes` | int | 单文件字节上限 |
| `last_send_at` | string? | 上次成功发送完成时间（ISO8601） |

### 3.2 `POST /send`

把本机已有文件发送到当前登录微信账号。

**请求：**

```http
POST /send HTTP/1.1
Host: 127.0.0.1:18790
Content-Type: application/json

{
  "file_path": "/absolute/path/to/file.m4v",
  "file_name": "成片 v05.m4v"
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `file_path` | 是 | 绝对路径；必须是可读普通文件 |
| `file_name` | 否 | 微信里显示的附件名；缺省用路径末段。若用户开启「mp4→m4v」，扩展名会按设置改写 |

**成功 200：**

```json
{
  "ok": true,
  "status": "sent",
  "media_type": "file",
  "file_path": "/absolute/path/to/file.m4v",
  "file_name": "成片 v05.m4v",
  "size": 1048576,
  "queue_wait_ms": 120
}
```

`queue_wait_ms` 仅表示请求到达后等待发送槽位的时间；不包含文件加密、CDN 上传和提交微信消息的耗时。

### 微信会话限制

腾讯公开实现会从 `getupdates` 的用户入站消息取得 `context_token`，并在后续 `sendmessage` 中原样回传。微信没有公开正式有效期和主动发送额度。若返回 `ret=-2`，WeClaw Send 会按需长轮询 `getupdates`，提示用户给 ClawBot 发任意消息，保存新 `context_token` 后自动重试原文件；等待 5 分钟未收到消息会失败，不会常驻消费入站消息。

刷新期间 `/send` 请求保持等待，直到收到新用户消息并完成自动重试；调用方不应在此期间重复提交同一文件。

**错误：** JSON `{ "ok": false, "error": "..." }`

| HTTP | 典型原因 |
|---:|---|
| 400 | 路径不是普通文件 / 请求体非法 |
| 404 | 文件不存在；或未知路径 |
| 413 | 超过 200 MB；或请求体过大 |
| 503 | 微信未登录或上游失败 |
| 500 | 其它内部错误 |

请求会**阻塞到本次发送完成**（含并发槽位排队）。大文件上传可能长达数分钟，请将客户端超时设为 **≥ 300s**。

## 4. 调用示例

### curl

```sh
curl -sS -X POST http://127.0.0.1:18790/send \
  -H 'Content-Type: application/json' \
  -d "{\"file_path\":\"$PWD/export.m4v\",\"file_name\":\"项目_导出.m4v\"}"
```

### Python

```python
import json, urllib.request

payload = {
    "file_path": "/Users/me/Movies/export.m4v",
    "file_name": "项目_导出.m4v",
}
req = urllib.request.Request(
    "http://127.0.0.1:18790/send",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=300) as resp:
    print(json.load(resp))
```

### JavaScript (Node 18+)

```js
const res = await fetch("http://127.0.0.1:18790/send", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    file_path: "/Users/me/Movies/export.m4v",
    file_name: "项目_导出.m4v",
  }),
  signal: AbortSignal.timeout(300_000),
});
if (!res.ok) throw new Error(await res.text());
console.log(await res.json());
```

### 建议的就绪探测

```sh
# 退出码 0 = 可发送
curl -sf http://127.0.0.1:18790/health \
  | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('wechat_connected') else 1)"
```

## 5. 与剪辑 / 自动化的典型接法

1. **渲染完成钩子**写出成片绝对路径
2. 检查 `/health` → `wechat_connected`
3. `POST /send`，`file_name` 使用人类可读片名（可含中文）
4. 根据 HTTP 状态与 `error` 字段提示用户

可选：用户在 WeClaw Send 设置中打开「.mp4 显示为 .m4v」，集成方仍可传 `.mp4` 路径，显示名由应用改写。

## 6. 安全与隐私

- 接口默认关闭；启用后仅监听 IPv4 回环地址 `127.0.0.1`，且无 Token
- 任意本机进程可调用；勿在共享机器上对不可信用户开放
- 登录态默认存本机文件，Keychain 只用于迁移旧版凭据
  `~/Library/Application Support/WeClawSend/credentials.json`（权限 `0600`）
  不再依赖 Keychain，避免 ad-hoc 重签名后反复弹授权
- 文件经 AES-128-ECB 加密后上传微信 CDN（与 iLink 客户端行为一致）

## 7. 品牌与分发

| 项 | 值 |
|---|---|
| 显示名 | WeClaw Send |
| Bundle ID | `com.chacha.WeClawSend` |
| 品牌色 | Mist Blue `#4A6F88` → Navy `#263E54` |
| 图标 | `Resources/AppIcon.icns` |
| 版本 | Info.plist `CFBundleShortVersionString` |

向最终用户说明时，请引导其：

1. 安装并启动 WeClaw Send
2. 菜单栏扫码登录微信
3. 再使用你的插件 / 脚本发送

## 8. 故障排查

| 现象 | 处理 |
|---|---|
| connection refused | 应用未运行，或设置中的「启用本地接口」已关闭 |
| `wechat_connected: false` | 设置中扫码登录 |
| 404 文件不存在 | 使用绝对路径；确认渲染已落盘 |
| 413 | 压缩或切片至 ≤ 200 MB |
| 长时间无响应 | 可能在等待并发槽位或上传大文件；查看 App 内具体阶段并加大超时 |
| 登录过期 | 重新扫码 |

## 9. 协议致谢

iLink 实现参考 [Tencent/openclaw-weixin](https://github.com/Tencent/openclaw-weixin)（MIT）。
完整声明见仓库根目录 `THIRD_PARTY_NOTICES.md`。

<p align="center">
  <img src="Resources/brand-mark-1024.png" width="104" alt="WeClaw Send 图标">
</p>

<h1 align="center">WeClaw Send</h1>

<p align="center"><strong>把 Mac、Premiere 和 DaVinci 的文件直接发到微信。</strong></p>

<p align="center">原生 macOS 菜单栏应用 · 无需 WeClaw、OpenClaw、Node 或 Go 后台</p>

<p align="center">
  <a href="https://github.com/double2tea/WeClawSend/releases">下载最新版</a> ·
  <a href="docs/使用说明.md">使用说明</a> ·
  <a href="docs/INTEGRATION.md">本地接口</a>
</p>

扫码登录一次，之后把文件拖进面板、拖到菜单栏图标，或从剪辑软件导出，WeClaw Send 就会接手上传和发送。进度、失败原因与最近记录都留在同一个小窗口里。

## 界面

<p align="center">
  <img src="docs/images/app-main.png" width="48%" alt="WeClaw Send 主面板：选择文件与查看最近传输">
  <img src="docs/images/app-settings.png" width="48%" alt="WeClaw Send 设置页：在线更新与 Premiere、DaVinci 集成">
</p>

主面板用来收文件和查看任务；设置页负责微信登录、开机启动、在线更新，以及 Premiere、DaVinci 的安装与升级。界面会跟随 macOS 的浅色或深色外观。

## 三步开始

1. 从 [Releases](https://github.com/double2tea/WeClawSend/releases) 下载 DMG 或 ZIP，把 `WeClaw Send.app` 放进“应用程序”。
2. 点击菜单栏纸飞机，进入设置并使用微信扫码登录。
3. 回到主面板，拖入文件或点击选择文件。

当前发布包使用 macOS ad-hoc 签名。第一次打开若被系统拦截，请前往“系统设置 → 隐私与安全性”，找到 WeClaw Send 并选择“仍要打开”。之后可以直接在设置页检查 App 和编辑器组件的更新。

需要图解步骤或遇到登录、发送问题时，请看 [使用说明](docs/使用说明.md)。

## 从菜单栏发送

- 拖放或多选文件，同时处理最多 3 个任务
- 查看准备、加密、上传和发送进度
- 随时取消正在进行的任务；失败后可直接重试
- 保留最近 20 条传输记录
- 可让微信中的 `.mp4` 附件名显示为 `.m4v`，本地文件不会被改名
- 可设置登录时自动启动
- 空闲 30 秒后自动收起；发送和交互过程中保持打开

单个文件最大 200 MB。文件可以并行准备，但微信消息会按顺序提交，相邻两条至少间隔 2 秒。

## 接入剪辑软件

### Premiere Pro

CEP 12 插件支持 Premiere Pro 25、26 及后续版本（manifest 接受 25.0–99.9；实际兼容性取决于 Adobe 是否继续保留 CEP）。它会：

- 用当前序列名填入文件名
- 按完整序列或 I/O 入点、出点范围导出
- 搜索并使用 Adobe 导出预设
- 记住上次的预设、输出文件夹和自动发送开关
- 导出完成后释放面板，发送留在后台继续
- 保留发送失败的成片，下次只重试发送，不重新渲染

在 WeClaw Send 的“设置 → 更新与编辑器集成”中一键安装，然后重启 Premiere，从“窗口 → 扩展 → WeClaw Send”打开。自动发送前还需在 App 设置中开启“本地接口”。

更多说明见 [Premiere 插件文档](premiere-cep/README.md)。

### DaVinci Resolve

Deliver 后渲染脚本会在渲染成功后把成片交给 WeClaw Send，可按 `.m4v` 文件或 `.mp4` 视频发送。在设置页一键安装，并开启“本地接口”即可使用。

如需手动安装：

```sh
./scripts/install-davinci-plugin.sh
```

脚本位置、日志和两种发送模式见 [DaVinci 插件文档](davinci-resolve/README.md)。

## 微信的发送限制

微信 iLink 的主动发送受会话窗口和消息额度限制。发送返回 `ret=-2` 时，App 会提示你在微信里给 ClawBot 发一条消息；检测到新上下文后会自动续传，不需要重新选择文件。上下文刷新通知不会要求确认，稍后会自行淡出。

如果 5 分钟内没有收到新消息，任务会明确失败，不会一直轮询。相关背景见腾讯仓库中的 [会话限制反馈](https://github.com/Tencent/openclaw-weixin/issues/202) 和 [`ret=-2` 反馈](https://github.com/Tencent/openclaw-weixin/issues/225)。

## 给本机脚本调用

菜单栏发送不依赖本地接口。只有 Premiere、DaVinci 或本机自动化需要它；接口默认关闭，并且只监听 `127.0.0.1:18790`，不会向局域网开放。

```http
GET /health
POST /send
Content-Type: application/json

{
  "file_path": "/absolute/path/to/file.m4v",
  "file_name": "中文文件名.m4v"
}
```

字段、返回值和错误码见 [集成文档](docs/INTEGRATION.md)。

## 本地开发

需要 macOS 14+ 与 Swift 工具链。

```sh
chmod +x scripts/*.sh
./scripts/install.sh
```

常用命令：

```sh
./scripts/test.sh
./scripts/build-app.sh
./scripts/functional-test.sh
./scripts/release.sh
```

`release.sh` 会生成 Intel / Apple Silicon 通用 App、DMG、ZIP、Premiere CEP 包、DaVinci 包、组件版本清单和 SHA-256 校验文件。App、Premiere 与 DaVinci 可以独立升级；推送 `v*` 标签后，GitHub Actions 会自动创建 Release。

## 联系

- [GitHub](https://github.com/double2tea/WeClawSend)
- [作品集](https://zeezhi.pages.dev/)
- [double_tea@foxmail.com](mailto:double_tea@foxmail.com)

微信 iLink 协议实现参考腾讯 [openclaw-weixin](https://github.com/Tencent/openclaw-weixin)（MIT），许可说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

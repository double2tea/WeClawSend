# WeClaw Send for Premiere Pro

Premiere Pro 25.6+ 的 UXP 面板。面板发起导出；只有打开「导出完成后自动发送」时，成功导出的文件才会交给 WeClaw Send。

## 前置条件

- macOS 14+
- Premiere Pro 25.6+
- 已安装并登录 WeClaw Send 1.1+
- UXP Developer Tool 2.2+

## 构建与加载

```sh
npm ci
npm run build
```

在 Premiere 中打开 **设置 → 插件 → 启用开发者模式**，重启 Premiere。然后在 UXP Developer Tool 中添加 `dist/manifest.json` 并点击 **Load**。

面板位置：**窗口 → UXP 插件 → WeClaw Send**。

## 使用

1. 在 WeClaw Send 设置中复制「Premiere 连接码」。
2. 打开一个 Premiere 序列。
3. 选择 Adobe `.epr` 导出预设和输出文件夹。
4. 输入不含扩展名的文件名。
5. 按需打开「导出完成后自动发送」，首次使用时粘贴连接码。
6. 点击「导出」或「导出并自动发送」。

关闭自动发送时，插件只执行导出。开启时，Premiere 首次唤起 WeClaw Send 可能显示系统授权提示。连接码保存在 Premiere 插件本地；在 WeClaw Send 中换码后，需要把新码重新粘贴到插件。

## 验证

```sh
npm run type-check
npm run lint
npm run format:check
npm test
npm run test:coverage
npm run build
```

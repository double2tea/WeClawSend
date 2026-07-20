# 宣传站部署说明

宣传页是 `website/` 下的纯静态站点，无外部字体、脚本或图片依赖。生产部署使用 Cloudflare Pages，项目名为 `weclaw-send`。

## 首次配置

1. 在 Cloudflare 控制台创建 Pages 项目 `weclaw-send`，选择 **Direct Upload**。
2. 创建 API Token，权限设置为 **Account → Cloudflare Pages → Edit**。
3. 在 GitHub 仓库的 **Settings → Secrets and variables → Actions** 添加：
   - `CLOUDFLARE_ACCOUNT_ID`
   - `CLOUDFLARE_API_TOKEN`
4. 在 Actions 中手动运行一次 **Deploy website**。

## 自动部署规则

- `main` 分支中的 `website/**` 发生变化时，自动部署页面。
- `Release` 工作流成功结束后，自动重新部署并同步最新的 DMG 与 ZIP。
- 部署前从最新 GitHub Release 下载发布包并检查 DMG、ZIP 均存在且非空；任一缺失时部署会直接失败。最终下载地址与页面同域，不依赖访客直接访问 GitHub。

## 本地预览

在仓库根目录运行：

```sh
python3 -m http.server 4173 --directory website
```

打开 `http://127.0.0.1:4173/`。本地预览不包含 CI 注入的 `downloads/`，下载按钮在生产部署后可用。

## 自定义域名

默认地址为 `https://weclaw-send.pages.dev`。如需自定义域名，在 Cloudflare Pages 项目的 **Custom domains** 中添加，并把 `website/robots.txt` 与 `website/sitemap.xml` 内的域名同步替换。

标准 Cloudflare Pages 在中国大陆通常可以访问，但不提供中国大陆网络可用性保证。若目标是长期稳定和确定性 SLA，需要使用完成备案的境内部署，或评估 Cloudflare Enterprise China Network。

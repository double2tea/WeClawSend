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

- `main` 分支中的 `website/**` 或 `wrangler.toml` 发生变化时，自动部署页面。
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

## 访问与下载统计

- 访问量、页面、来源、设备、浏览器和国家/地区：在 Cloudflare Pages 项目 `weclaw-send` 的 **Metrics → Web Analytics → Enable** 开启。下次部署后会自动注入无 Cookie 统计脚本。
- 下载发起次数：页面链接指向 `/dl/dmg` 与 `/dl/zip`；优先由 `website/functions/dl/[file].js` 匿名记录后 302 到真实安装包。数据写入 Analytics Engine 数据集 `weclawsend_downloads`（绑定名 `DOWNLOADS`，见根目录 `wrangler.toml`）。
- 若 Function / Analytics 绑定不可用，`website/_redirects` 会把 `/dl/dmg` 与 `/dl/zip` 静态 302 到 `/downloads/WeClaw-Send.*`，保证下载不中断。
- Functions 仅匹配 `/dl/*`（见 `website/_routes.json`），其余静态资源不走 Functions 计费路径。
- 部署命令使用 `wrangler pages deploy`（读取 `wrangler.toml` 的 `pages_build_output_dir` 与 bindings），产物目录为 `_site/`。
- 查询下载数据示例：

```sh
curl -X POST "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/analytics_engine/sql" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -d "SELECT blob1 AS file, blob2 AS country, SUM(_sample_interval) AS downloads FROM weclawsend_downloads WHERE timestamp >= NOW() - INTERVAL '7' DAY GROUP BY file, country ORDER BY downloads DESC"
```

区域粒度为国家级。统计的是“发起下载”，不能证明文件已完整下载完成。

## 私有数据页

地址：`https://weclaw-send.pages.dev/stats`

- **不出现在导航、sitemap**；`robots.txt` 已禁止抓取。
- 需要密钥：`STATS_ACCESS_KEY`
- 查询下载统计还需要：
  - `CLOUDFLARE_ACCOUNT_ID`
  - `CLOUDFLARE_API_TOKEN`（Account 权限至少能读 Analytics Engine SQL）

在 Cloudflare Dashboard → **Workers & Pages** → `weclaw-send` → **Settings → Environment variables** 添加上述变量（Production）。

或用 CLI：

```sh
npx wrangler pages secret put STATS_ACCESS_KEY --project-name=weclaw-send
npx wrangler pages secret put CLOUDFLARE_API_TOKEN --project-name=weclaw-send
npx wrangler pages secret put CLOUDFLARE_ACCOUNT_ID --project-name=weclaw-send
```

打开方式：

```text
https://weclaw-send.pages.dev/stats?key=你的密钥
```

验证通过后会写入仅用于 `/stats` 的 HttpOnly cookie，后续可直接打开 `/stats`。

说明：

- 只统计 `/dl/dmg`、`/dl/zip` 发起次数
- 直接访问 `/downloads/*` 不计入
- 页面展示最近 30 天汇总


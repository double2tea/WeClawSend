const DATASET = "weclawsend_downloads";

function htmlEscape(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

async function timingSafeEqualString(a, b) {
  if (typeof a !== "string" || typeof b !== "string") return false;
  const encoder = new TextEncoder();
  const left = encoder.encode(a);
  const right = encoder.encode(b);
  if (left.byteLength !== right.byteLength) return false;
  return crypto.subtle.timingSafeEqual(left, right);
}

function getCookie(request, name) {
  const raw = request.headers.get("Cookie") || "";
  for (const part of raw.split(";")) {
    const [key, ...rest] = part.trim().split("=");
    if (key === name) return decodeURIComponent(rest.join("="));
  }
  return "";
}

function authorized(request, env) {
  const expected = env.STATS_ACCESS_KEY;
  if (!expected) return Promise.resolve({ ok: false, reason: "missing_key_config" });

  const url = new URL(request.url);
  const queryKey = url.searchParams.get("key") || "";
  const header = request.headers.get("Authorization") || "";
  const bearer = header.toLowerCase().startsWith("bearer ")
    ? header.slice(7).trim()
    : "";
  const cookieKey = getCookie(request, "weclaw_stats_key");
  const provided = queryKey || bearer || cookieKey;

  return timingSafeEqualString(provided, expected).then((ok) => ({
    ok,
    provided,
    reason: ok ? "" : "unauthorized",
  }));
}

function page(body, { status = 200, setCookie = "" } = {}) {
  const html = `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex,nofollow,noarchive">
  <title>WeClaw Send 数据</title>
  <style>
    :root {
      --bg: #f6f5f2;
      --ink: #1c1b19;
      --muted: #6d6a63;
      --card: #fffdf9;
      --line: rgba(28,27,25,.1);
      --accent: #2f3b2f;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font: 15px/1.55 ui-sans-serif, system-ui, -apple-system, sans-serif;
      color: var(--ink);
      background: radial-gradient(circle at top, #fff 0%, var(--bg) 55%);
      min-height: 100vh;
    }
    main {
      width: min(920px, calc(100% - 32px));
      margin: 40px auto 64px;
    }
    h1 { font-size: 28px; letter-spacing: -.03em; margin: 0 0 8px; }
    h2 { font-size: 17px; margin: 28px 0 12px; }
    p, li { color: var(--muted); }
    .card {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 16px;
      padding: 18px 18px 16px;
      box-shadow: 0 10px 30px rgba(28,27,25,.04);
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
      gap: 12px;
      margin: 18px 0 8px;
    }
    .metric {
      border: 1px solid var(--line);
      border-radius: 12px;
      padding: 14px;
      background: #fff;
    }
    .metric b {
      display: block;
      font-size: 28px;
      letter-spacing: -.04em;
      color: var(--ink);
    }
    .metric span { color: var(--muted); font-size: 13px; }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 14px;
    }
    th, td {
      text-align: left;
      padding: 10px 8px;
      border-bottom: 1px solid var(--line);
      vertical-align: top;
    }
    th { color: var(--muted); font-weight: 600; font-size: 12px; text-transform: uppercase; letter-spacing: .04em; }
    form { display: grid; gap: 12px; max-width: 360px; }
    input[type="password"] {
      width: 100%;
      border: 1px solid var(--line);
      border-radius: 10px;
      padding: 12px 14px;
      font: inherit;
      background: #fff;
    }
    button {
      appearance: none;
      border: 0;
      border-radius: 999px;
      padding: 11px 16px;
      background: var(--accent);
      color: #f7f7f4;
      font: inherit;
      cursor: pointer;
    }
    .note {
      margin-top: 18px;
      font-size: 13px;
      color: var(--muted);
    }
    code {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12.5px;
      background: rgba(28,27,25,.05);
      padding: 1px 6px;
      border-radius: 6px;
    }
    .error { color: #8a2f2f; }
  </style>
</head>
<body>
  <main>
    ${body}
  </main>
</body>
</html>`;

  const headers = {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store",
    "x-robots-tag": "noindex, nofollow, noarchive",
    "referrer-policy": "no-referrer",
  };
  if (setCookie) headers["set-cookie"] = setCookie;
  return new Response(html, { status, headers });
}

function loginPage(message = "") {
  return page(`
    <div class="card">
      <h1>数据页</h1>
      <p>仅密钥可访问。不会出现在网站导航或搜索引擎。</p>
      ${message ? `<p class="error">${htmlEscape(message)}</p>` : ""}
      <form method="GET" action="/stats">
        <label>
          访问密钥
          <input type="password" name="key" autocomplete="current-password" required>
        </label>
        <button type="submit">查看统计</button>
      </form>
      <p class="note">也可使用 Header：<code>Authorization: Bearer &lt;key&gt;</code></p>
    </div>
  `, { status: message ? 401 : 200 });
}

async function queryAnalytics(env, sql) {
  const accountId = env.CLOUDFLARE_ACCOUNT_ID || env.CF_ACCOUNT_ID;
  const token = env.CLOUDFLARE_API_TOKEN || env.CF_API_TOKEN;
  if (!accountId || !token) {
    const error = new Error("missing_api_credentials");
    error.code = "missing_api_credentials";
    throw error;
  }

  const response = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${accountId}/analytics_engine/sql`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "content-type": "text/plain; charset=utf-8",
      },
      body: sql,
    },
  );

  const text = await response.text();
  let payload;
  try {
    payload = JSON.parse(text);
  } catch {
    payload = { raw: text };
  }

  if (!response.ok) {
    const error = new Error(
      payload?.errors?.[0]?.message || payload?.raw || `HTTP ${response.status}`,
    );
    error.code = "sql_failed";
    error.details = payload;
    throw error;
  }

  // SQL API may return { data: [...] } or array-like meta/data
  if (Array.isArray(payload?.data)) return payload.data;
  if (Array.isArray(payload)) return payload;
  return payload?.result || [];
}

function sumBy(rows, key) {
  const map = new Map();
  for (const row of rows) {
    const k = String(row[key] ?? "unknown");
    map.set(k, (map.get(k) || 0) + Number(row.downloads || 0));
  }
  return map;
}

function renderRows(rows, columns) {
  if (!rows.length) {
    return `<p>暂无数据。访问 <code>/dl/dmg</code> 或 <code>/dl/zip</code> 后才会记一次发起下载。</p>`;
  }
  const head = columns
    .map((col) => `<th>${htmlEscape(col.label)}</th>`)
    .join("");
  const body = rows
    .map((row) => {
      const cells = columns
        .map((col) => `<td>${htmlEscape(row[col.key] ?? "")}</td>`)
        .join("");
      return `<tr>${cells}</tr>`;
    })
    .join("");
  return `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
}

export async function onRequestGet(context) {
  const { request, env } = context;

  if (!env.STATS_ACCESS_KEY) {
    return page(`
      <div class="card">
        <h1>数据页未启用</h1>
        <p class="error">缺少 <code>STATS_ACCESS_KEY</code>。</p>
        <p>在 Cloudflare Pages 项目 <code>weclaw-send</code> 设置密钥后即可使用：</p>
        <ol>
          <li><code>STATS_ACCESS_KEY</code>：你自己的访问口令</li>
          <li><code>CLOUDFLARE_ACCOUNT_ID</code>：账号 ID</li>
          <li><code>CLOUDFLARE_API_TOKEN</code>：需可读 Analytics Engine</li>
        </ol>
        <p class="note">设置后重新部署，或等待下次网站部署生效。</p>
      </div>
    `, { status: 503 });
  }

  const auth = await authorized(request, env);
  if (!auth.ok) {
    return loginPage(auth.reason === "unauthorized" ? "密钥不正确。" : "");
  }

  const setCookie = `weclaw_stats_key=${encodeURIComponent(env.STATS_ACCESS_KEY)}; Path=/stats; HttpOnly; Secure; SameSite=Strict; Max-Age=2592000`;

  try {
    const [byFileCountry, byDay] = await Promise.all([
      queryAnalytics(
        env,
        `SELECT blob1 AS file, blob2 AS country, SUM(_sample_interval) AS downloads
         FROM ${DATASET}
         WHERE timestamp >= NOW() - INTERVAL '30' DAY
         GROUP BY file, country
         ORDER BY downloads DESC`,
      ),
      queryAnalytics(
        env,
        `SELECT
           formatDateTime(toStartOfInterval(timestamp, INTERVAL '1' DAY), '%Y-%m-%d') AS day,
           blob1 AS file,
           SUM(_sample_interval) AS downloads
         FROM ${DATASET}
         WHERE timestamp >= NOW() - INTERVAL '30' DAY
         GROUP BY day, file
         ORDER BY day DESC, file ASC`,
      ),
    ]);

    const totals = sumBy(byFileCountry, "file");
    const dmg = totals.get("dmg") || 0;
    const zip = totals.get("zip") || 0;
    const all = dmg + zip;

    const countryRows = byFileCountry.map((row) => ({
      file: row.file,
      country: row.country || "ZZ",
      downloads: Number(row.downloads || 0),
    }));
    const dayRows = byDay.map((row) => ({
      day: row.day,
      file: row.file,
      downloads: Number(row.downloads || 0),
    }));

    return page(`
      <div class="card">
        <h1>下载统计</h1>
        <p>仅密钥可见 · 最近 30 天 · 统计“发起下载”，不是完整下完次数。</p>
        <div class="grid">
          <div class="metric"><b>${all}</b><span>总发起</span></div>
          <div class="metric"><b>${dmg}</b><span>DMG</span></div>
          <div class="metric"><b>${zip}</b><span>ZIP</span></div>
        </div>

        <h2>按文件 / 国家</h2>
        ${renderRows(countryRows, [
          { key: "file", label: "文件" },
          { key: "country", label: "国家" },
          { key: "downloads", label: "次数" },
        ])}

        <h2>按天</h2>
        ${renderRows(dayRows, [
          { key: "day", label: "日期" },
          { key: "file", label: "文件" },
          { key: "downloads", label: "次数" },
        ])}

        <p class="note">
          数据来自 Analytics Engine 数据集 <code>${DATASET}</code>。
          只有访问 <code>/dl/dmg</code> 与 <code>/dl/zip</code> 会计数；直接打开 <code>/downloads/*</code> 不计。
        </p>
      </div>
    `, { setCookie });
  } catch (error) {
    const code = error?.code || "unknown";
    if (code === "missing_api_credentials") {
      return page(`
        <div class="card">
          <h1>已通过密钥验证</h1>
          <p class="error">还差 Cloudflare 查询凭证。</p>
          <p>请在 Pages 项目环境变量中配置：</p>
          <ul>
            <li><code>CLOUDFLARE_ACCOUNT_ID</code></li>
            <li><code>CLOUDFLARE_API_TOKEN</code>（需 Analytics Engine 读取权限）</li>
          </ul>
          <p class="note">密钥 cookie 已写入，配好后刷新本页即可。</p>
        </div>
      `, { setCookie });
    }

    return page(`
      <div class="card">
        <h1>查询失败</h1>
        <p class="error">${htmlEscape(error?.message || String(error))}</p>
        <p class="note">请确认 Analytics Engine 数据集 <code>${DATASET}</code> 已有写入，且 API Token 权限足够。</p>
      </div>
    `, { setCookie, status: 502 });
  }
}

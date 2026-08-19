const VERSION_PATTERN = /^\d+\.\d+\.\d+$/;
const BUILD_PATTERN = /^\d+$/;
const CHANNELS = new Set(["stable", "beta"]);
const MAX_BODY_BYTES = 512;
const USER_AGENT = "WeClawSend-UpdateCheck";

class PayloadTooLargeError extends Error {}

function textResponse(message, status) {
  return new Response(message, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "text/plain; charset=utf-8",
    },
  });
}

async function readJson(request) {
  const contentLength = Number(request.headers.get("Content-Length"));
  if (Number.isFinite(contentLength) && contentLength > MAX_BODY_BYTES) {
    throw new PayloadTooLargeError();
  }

  const reader = request.body?.getReader();
  if (!reader) {
    throw new SyntaxError("Missing body");
  }

  const chunks = [];
  let byteCount = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    byteCount += value.byteLength;
    if (byteCount > MAX_BODY_BYTES) {
      await reader.cancel();
      throw new PayloadTooLargeError();
    }
    chunks.push(value);
  }

  const body = new Uint8Array(byteCount);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return JSON.parse(new TextDecoder().decode(body));
}

async function isPublishedBuild(requestURL, version, build, channel) {
  let response;
  try {
    response = await fetch(new URL("/downloads/update-versions.json", requestURL));
  } catch {
    return null;
  }
  if (!response.ok) return null;

  let releases;
  try {
    releases = await response.json();
  } catch {
    return null;
  }
  if (!Array.isArray(releases)) return null;

  return releases.some((release) => (
    release?.version === version
    && release?.channel === channel
    && (channel === "stable" || release?.build === build)
  ));
}

export async function onRequestPost(context) {
  const dataset = context.env.UPDATE_CHECKS;
  if (!dataset?.writeDataPoint) {
    return textResponse("Analytics unavailable", 503);
  }
  if (context.request.headers.get("User-Agent") !== USER_AGENT) {
    return textResponse("Forbidden", 403);
  }
  const contentType = context.request.headers.get("Content-Type")
    ?.split(";", 1)[0]
    .trim()
    .toLowerCase();
  if (contentType !== "application/json") {
    return textResponse("Unsupported Media Type", 415);
  }

  let payload;
  try {
    payload = await readJson(context.request);
  } catch (error) {
    return error instanceof PayloadTooLargeError
      ? textResponse("Payload Too Large", 413)
      : textResponse("Invalid JSON", 400);
  }

  const version = String(payload?.version || "");
  const build = String(payload?.build || "");
  const channel = String(payload?.channel || "");
  if (
    !VERSION_PATTERN.test(version)
    || !BUILD_PATTERN.test(build)
    || !CHANNELS.has(channel)
  ) {
    return textResponse("Invalid payload", 400);
  }

  const published = await isPublishedBuild(context.request.url, version, build, channel);
  if (published === null) {
    return textResponse("Release metadata unavailable", 503);
  }
  if (!published) {
    return textResponse("Unknown release", 400);
  }

  try {
    dataset.writeDataPoint({
      blobs: [version, build, channel],
      doubles: [1],
      indexes: [`${version}:${channel}`],
    });
  } catch {
    return textResponse("Analytics unavailable", 503);
  }

  return new Response(null, {
    status: 204,
    headers: { "Cache-Control": "no-store" },
  });
}

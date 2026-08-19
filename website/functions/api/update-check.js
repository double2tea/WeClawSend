const VERSION_PATTERN = /^\d+\.\d+\.\d+$/;
const BUILD_PATTERN = /^\d+$/;
const CHANNELS = new Set(["stable", "beta"]);

function textResponse(message, status) {
  return new Response(message, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "text/plain; charset=utf-8",
    },
  });
}

export async function onRequestPost(context) {
  let payload;
  try {
    payload = await context.request.json();
  } catch {
    return textResponse("Invalid JSON", 400);
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

  const dataset = context.env.UPDATE_CHECKS;
  if (!dataset?.writeDataPoint) {
    return textResponse("Analytics unavailable", 503);
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

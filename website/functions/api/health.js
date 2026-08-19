export function onRequestGet(context) {
  const bindings = {
    downloads: typeof context.env.DOWNLOADS?.writeDataPoint === "function",
    updateChecks: typeof context.env.UPDATE_CHECKS?.writeDataPoint === "function",
  };
  const ok = bindings.downloads && bindings.updateChecks;
  return Response.json(
    { ok, bindings },
    {
      status: ok ? 200 : 503,
      headers: { "Cache-Control": "no-store" },
    },
  );
}

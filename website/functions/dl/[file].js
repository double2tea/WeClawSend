const FILES = {
  dmg: "WeClaw-Send.dmg",
  zip: "WeClaw-Send.zip",
};

export async function onRequestGet(context) {
  const key = String(context.params.file || "").toLowerCase();
  const name = FILES[key];
  if (!name) {
    return new Response("Not Found", { status: 404 });
  }

  const country = context.request.cf?.country || "ZZ";
  context.env.DOWNLOADS.writeDataPoint({
    blobs: [key, country],
    doubles: [1],
    indexes: [key],
  });

  const target = new URL(`/downloads/${name}`, context.request.url);
  target.searchParams.set("download", "latest");
  return Response.redirect(target.toString(), 302);
}

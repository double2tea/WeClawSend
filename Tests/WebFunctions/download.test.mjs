import assert from "node:assert/strict";
import test from "node:test";

import { onRequestGet } from "../../website/functions/dl/[file].js";

test("records an anonymous download and redirects", async () => {
  let point;
  const response = await onRequestGet({
    params: { file: "dmg" },
    request: {
      url: "https://example.test/dl/dmg",
      cf: { country: "CN" },
    },
    env: { DOWNLOADS: { writeDataPoint(value) { point = value; } } },
  });

  assert.equal(response.status, 302);
  assert.equal(response.headers.get("Location"), "https://example.test/downloads/WeClaw-Send.dmg?download=latest");
  assert.deepEqual(point, {
    blobs: ["dmg", "CN"],
    doubles: [1],
    indexes: ["dmg"],
  });
});

test("rejects unknown download names", async () => {
  const response = await onRequestGet({
    params: { file: "unknown" },
    request: { url: "https://example.test/dl/unknown", cf: {} },
    env: {},
  });

  assert.equal(response.status, 404);
});

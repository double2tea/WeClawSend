import assert from "node:assert/strict";
import test from "node:test";

import { onRequestPost } from "../../website/functions/api/update-check.js";

function context(body, dataset) {
  return {
    request: new Request("https://example.test/api/update-check", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    }),
    env: { UPDATE_CHECKS: dataset },
  };
}

test("records only version aggregate fields", async () => {
  let point;
  const response = await onRequestPost(context(
    { version: "2.2.0", build: "38", channel: "stable" },
    { writeDataPoint(value) { point = value; } },
  ));

  assert.equal(response.status, 204);
  assert.deepEqual(point, {
    blobs: ["2.2.0", "38", "stable"],
    doubles: [1],
    indexes: ["2.2.0:stable"],
  });
});

test("rejects malformed payloads without recording", async () => {
  let writes = 0;
  const response = await onRequestPost(context(
    { version: "latest", build: "x", channel: "unknown" },
    { writeDataPoint() { writes += 1; } },
  ));

  assert.equal(response.status, 400);
  assert.equal(writes, 0);
});

test("fails fast when the analytics binding is missing", async () => {
  const response = await onRequestPost(context(
    { version: "2.2.0", build: "38", channel: "stable" },
    undefined,
  ));

  assert.equal(response.status, 503);
});

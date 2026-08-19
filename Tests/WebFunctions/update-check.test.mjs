import assert from "node:assert/strict";
import test from "node:test";

import { onRequestPost } from "../../website/functions/api/update-check.js";

const originalFetch = globalThis.fetch;

function context(body, dataset, userAgent = "WeClawSend-UpdateCheck") {
  return {
    request: new Request("https://example.test/api/update-check", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "User-Agent": userAgent,
      },
      body: JSON.stringify(body),
    }),
    env: { UPDATE_CHECKS: dataset },
  };
}

function mockPublishedVersions(releases) {
  globalThis.fetch = async () => Response.json(releases);
}

test.afterEach(() => {
  globalThis.fetch = originalFetch;
});

test("records only published version aggregate fields", async () => {
  mockPublishedVersions([{ version: "2.2.0", build: null, channel: "stable" }]);
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

test("rejects payloads larger than 512 bytes", async () => {
  const response = await onRequestPost(context(
    { version: "2.2.0", build: "38", channel: "stable", padding: "x".repeat(600) },
    { writeDataPoint() {} },
  ));

  assert.equal(response.status, 413);
});

test("rejects callers without the official user agent", async () => {
  const response = await onRequestPost(context(
    { version: "2.2.0", build: "38", channel: "stable" },
    { writeDataPoint() {} },
    "unknown-client",
  ));

  assert.equal(response.status, 403);
});

test("rejects versions that were not published", async () => {
  mockPublishedVersions([{ version: "2.2.0", build: null, channel: "stable" }]);
  const response = await onRequestPost(context(
    { version: "9.9.9", build: "1", channel: "stable" },
    { writeDataPoint() {} },
  ));

  assert.equal(response.status, 400);
});

test("requires the exact build number for beta releases", async () => {
  mockPublishedVersions([{ version: "2.2.0", build: "38", channel: "beta" }]);
  const response = await onRequestPost(context(
    { version: "2.2.0", build: "37", channel: "beta" },
    { writeDataPoint() {} },
  ));

  assert.equal(response.status, 400);
});

test("fails fast when the analytics binding is missing", async () => {
  const response = await onRequestPost(context(
    { version: "2.2.0", build: "38", channel: "stable" },
    undefined,
  ));

  assert.equal(response.status, 503);
});

import assert from "node:assert/strict";
import test from "node:test";

import { onRequestPost } from "../../website/functions/api/account-presence.js";

const originalFetch = globalThis.fetch;
const accountHash = "a".repeat(64);

function context(body, dataset, userAgent = "WeClawSend-AccountPresence") {
  return {
    request: new Request("https://example.test/api/account-presence", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "User-Agent": userAgent,
      },
      body: JSON.stringify(body),
    }),
    env: { ACCOUNT_PRESENCE: dataset },
  };
}

function mockPublishedVersions(releases) {
  globalThis.fetch = async () => Response.json(releases);
}

test.afterEach(() => {
  globalThis.fetch = originalFetch;
});

test("records only the anonymous account hash and aggregate fields", async () => {
  mockPublishedVersions([{ version: "2.5.1", build: null, channel: "stable" }]);
  let point;
  const response = await onRequestPost(context(
    {
      account_hash: accountHash,
      version: "2.5.1",
      build: "51",
      channel: "stable",
      source: "weClawSend",
    },
    { writeDataPoint(value) { point = value; } },
  ));

  assert.equal(response.status, 204);
  assert.deepEqual(point, {
    blobs: ["2.5.1", "51", "stable", "weClawSend"],
    doubles: [1],
    indexes: [accountHash],
  });
});

test("rejects raw or malformed identifiers", async () => {
  let writes = 0;
  const response = await onRequestPost(context(
    {
      account_hash: "wxid_not-an-anonymous-hash",
      version: "2.5.1",
      build: "51",
      channel: "stable",
      source: "weClawSend",
    },
    { writeDataPoint() { writes += 1; } },
  ));

  assert.equal(response.status, 400);
  assert.equal(writes, 0);
});

test("rejects unexpected identifier fields", async () => {
  let writes = 0;
  const response = await onRequestPost(context(
    {
      account_hash: accountHash,
      user_id: "ilink-user-1",
      version: "2.5.1",
      build: "51",
      channel: "stable",
      source: "weClawSend",
    },
    { writeDataPoint() { writes += 1; } },
  ));

  assert.equal(response.status, 400);
  assert.equal(writes, 0);
});

test("rejects unknown credential sources", async () => {
  const response = await onRequestPost(context(
    {
      account_hash: accountHash,
      version: "2.5.1",
      build: "51",
      channel: "stable",
      source: "other",
    },
    { writeDataPoint() {} },
  ));
  assert.equal(response.status, 400);
});

test("rejects callers without the official user agent", async () => {
  const response = await onRequestPost(context(
    {
      account_hash: accountHash,
      version: "2.5.1",
      build: "51",
      channel: "stable",
      source: "openClaw",
    },
    { writeDataPoint() {} },
    "unknown-client",
  ));
  assert.equal(response.status, 403);
});

test("fails fast when the analytics binding is missing", async () => {
  const response = await onRequestPost(context(
    {
      account_hash: accountHash,
      version: "2.5.1",
      build: "51",
      channel: "stable",
      source: "weClawSend",
    },
    undefined,
  ));
  assert.equal(response.status, 503);
});

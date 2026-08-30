import assert from "node:assert/strict";
import test from "node:test";

import { onRequestGet } from "../../website/functions/api/health.js";

test("reports all analytics bindings as healthy", async () => {
  const response = onRequestGet({
    env: {
      DOWNLOADS: { writeDataPoint() {} },
      UPDATE_CHECKS: { writeDataPoint() {} },
      ACCOUNT_PRESENCE: { writeDataPoint() {} },
    },
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    ok: true,
    bindings: { downloads: true, updateChecks: true, accountPresence: true },
  });
});

test("fails when either analytics binding is missing", async () => {
  const response = onRequestGet({
    env: { DOWNLOADS: { writeDataPoint() {} } },
  });

  assert.equal(response.status, 503);
  assert.equal((await response.json()).ok, false);
});

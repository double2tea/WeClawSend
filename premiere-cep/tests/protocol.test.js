const test = require("node:test");
const assert = require("node:assert/strict");
const protocol = require("../js/protocol.js");

test("parses encoded host values", () => {
  assert.deepEqual(protocol.parseHostReply("OK|%E6%88%90%E7%89%87%20v1"), {
    status: "OK",
    detail: "成片 v1"
  });
});

test("throws explicit host errors", () => {
  assert.throws(
    () => protocol.parseHostReply("ERROR|%E6%97%A0%E6%B4%BB%E5%8A%A8%E5%BA%8F%E5%88%97"),
    /无活动序列/
  );
});

test("validates output names", () => {
  assert.equal(protocol.validateOutputName("  成片 v1  "), "成片 v1");
  assert.throws(() => protocol.validateOutputName(""), /请输入输出文件名/);
  assert.throws(() => protocol.validateOutputName("a/b"), /不能包含/);
  assert.throws(() => protocol.validateOutputName("a:b"), /不能包含/);
});

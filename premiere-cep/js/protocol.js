(function (root, factory) {
  var protocol = factory();
  root.WeClawProtocol = protocol;
  if (typeof module === "object" && module.exports) {
    module.exports = protocol;
  }
})(typeof window === "object" ? window : globalThis, function () {
  "use strict";

  function parseHostReply(value) {
    var parts = String(value).split("|");
    var status = parts.shift();
    var detail = decodeURIComponent(parts.join("|"));
    if (status === "OK" || status === "CANCEL") {
      return { status: status, detail: detail };
    }
    if (status === "ERROR") {
      throw new Error(detail);
    }
    throw new Error("Premiere 返回了无法识别的结果");
  }

  function validateOutputName(value) {
    var name = String(value).trim();
    if (name.length === 0) {
      throw new Error("请输入输出文件名");
    }
    if (/[\/:]/.test(name)) {
      throw new Error("输出文件名不能包含 / 或 :");
    }
    return name;
  }

  return {
    parseHostReply: parseHostReply,
    validateOutputName: validateOutputName
  };
});

(function (root, factory) {
  var client = factory();
  root.WeClawBridgeClient = client;
  if (typeof module === "object" && module.exports) {
    module.exports = client;
  }
})(typeof window === "object" ? window : globalThis, function () {
  "use strict";

  function requestJSON(node, options, body, timeoutMilliseconds, timeoutMessage) {
    return new Promise(function (resolve, reject) {
      if (!node || typeof node.require !== "function" || !node.Buffer) {
        reject(new Error("CEP 12 的 Node.js 接口不可用"));
        return;
      }

      var http;
      try {
        http = node.require("http");
      } catch (error) {
        reject(error);
        return;
      }

      var request = http.request(options, function (response) {
        var chunks = [];
        response.on("data", function (chunk) { chunks.push(chunk); });
        response.on("error", reject);
        response.on("aborted", function () {
          reject(new Error("WeClaw Send 响应中断"));
        });
        response.on("end", function () {
          var payload;
          try {
            payload = JSON.parse(node.Buffer.concat(chunks).toString("utf8"));
          } catch (_) {
            reject(new Error("WeClaw Send 返回了无效响应"));
            return;
          }
          resolve({ statusCode: response.statusCode, payload: payload });
        });
      });

      request.setTimeout(timeoutMilliseconds, function () {
        request.destroy(new Error(timeoutMessage));
      });
      request.on("error", function (error) {
        if (error && error.code === "ECONNREFUSED") {
          reject(new Error("请启动 WeClaw Send，并在设置中开启本地接口"));
          return;
        }
        reject(error);
      });
      request.end(body || undefined);
    });
  }

  function checkHealth(node) {
    return requestJSON(node, {
      hostname: "127.0.0.1",
      port: 18790,
      path: "/health",
      method: "GET"
    }, "", 3000, "检查 WeClaw Send 本地接口超时").then(function (response) {
      if (response.statusCode !== 200 || response.payload.ok !== true) {
        throw new Error(response.payload.error || "WeClaw Send 本地接口不可用");
      }
      return response.payload;
    });
  }

  function sendFile(node, filePath) {
    var body = JSON.stringify({
      file_path: filePath,
      file_name: String(filePath).split(/[\\/]/).pop()
    });
    var contentLength = node && node.Buffer ? node.Buffer.byteLength(body) : 0;

    return requestJSON(node, {
      hostname: "127.0.0.1",
      port: 18790,
      path: "/send",
      method: "POST",
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Content-Length": contentLength
      }
    }, body, 300000, "发送等待超过 5 分钟").then(function (response) {
      if (response.statusCode !== 200 || response.payload.ok !== true) {
        throw new Error(response.payload.error || "WeClaw Send 发送失败");
      }
      return response.payload;
    });
  }

  return {
    checkHealth: checkHealth,
    sendFile: sendFile
  };
});

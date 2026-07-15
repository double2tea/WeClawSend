export const AUTO_SEND_STORAGE_KEY = "autoSendAfterExport";
export const INTEGRATION_CODE_STORAGE_KEY = "premiereIntegrationCode";

export function buildOutputFileName(baseName: string, extension: string): string {
  const trimmedName = baseName.trim();
  const normalizedExtension = extension.trim().replace(/^\./, "");
  if (trimmedName.length === 0) {
    throw new Error("请输入输出文件名");
  }
  if (trimmedName.includes("/")) {
    throw new Error("输出文件名不能包含 /");
  }
  if (normalizedExtension.length === 0) {
    throw new Error("导出预设没有提供文件扩展名");
  }
  return `${trimmedName}.${normalizedExtension}`;
}

export function buildOutputPath(folderPath: string, fileName: string): string {
  if (folderPath.length === 0) {
    throw new Error("请选择输出位置");
  }
  return `${folderPath.endsWith("/") ? folderPath : `${folderPath}/`}${fileName}`;
}

export function buildSendURL(filePath: string, fileName: string, token: string): string {
  if (!filePath.startsWith("/")) {
    throw new Error("发送文件必须使用绝对路径");
  }
  if (token.length === 0) {
    throw new Error("请输入 Premiere 连接码");
  }
  return `weclaw-send://send?file_path=${encodeURIComponent(filePath)}&file_name=${encodeURIComponent(fileName)}&token=${encodeURIComponent(token)}`;
}

export function storedAutoSend(value: string | null): boolean {
  return value === "true";
}

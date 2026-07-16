$._WECLAW = {
    ok: function (value) {
        return "OK|" + encodeURIComponent(value || "");
    },

    error: function (value) {
        return "ERROR|" + encodeURIComponent(value || "Premiere 操作失败");
    },

    chooseFolder: function () {
        var folder = Folder.selectDialog("选择导出文件夹");
        return folder ? this.ok(folder.fsName) : "CANCEL|";
    },

    activeSequenceName: function () {
        if (!app.project || !app.project.activeSequence) {
            return this.error("请先在 Premiere 中打开一个序列");
        }
        return this.ok(app.project.activeSequence.name);
    },

    exportSequence: function (presetPath, folderPath, outputName, exportRange, expectedSequenceName) {
        if (!app.project || !app.project.activeSequence) {
            return this.error("请先在 Premiere 中打开一个序列");
        }

        var preset = new File(presetPath);
        if (!preset.exists) {
            return this.error("导出预设不存在");
        }
        var folder = new Folder(folderPath);
        if (!folder.exists) {
            return this.error("输出文件夹不存在");
        }
        if (!outputName || /[\/:]/.test(outputName)) {
            return this.error("输出文件名无效");
        }

        var sequence = app.project.activeSequence;
        if (sequence.name !== expectedSequenceName) {
            return this.error("当前序列已切换，请重新导出");
        }
        var workAreaType;
        if (exportRange === "entire") {
            workAreaType = 0;
        } else if (exportRange === "inOut") {
            var inPoint = sequence.getInPoint();
            var outPoint = sequence.getOutPoint();
            if (inPoint === "-400000" || outPoint === "-400000" ||
                !isFinite(Number(inPoint)) || !isFinite(Number(outPoint)) ||
                Number(outPoint) <= Number(inPoint)) {
                return this.error("请先在序列中设置有效的入点和出点");
            }
            workAreaType = 1;
        } else {
            return this.error("导出范围无效");
        }

        var extension = sequence.getExportFileExtension(preset.fsName);
        if (!extension) {
            return this.error("无法从导出预设读取文件扩展名");
        }

        var separator = Folder.fs === "Macintosh" ? "/" : "\\";
        var outputPath = folder.fsName + separator + outputName + "." + extension;
        if (new File(outputPath).exists) {
            return this.error("输出文件已存在，请修改文件名或移走旧文件");
        }
        if (!sequence.exportAsMediaDirect(outputPath, preset.fsName, workAreaType)) {
            return this.error("Premiere 导出失败");
        }
        return this.ok(outputPath);
    }
};

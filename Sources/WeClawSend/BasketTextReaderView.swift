import Foundation
import SwiftUI

/// A focused reader for plain-text items in a basket.
///
/// `onSave` returns `true` when the parent persisted the text. Returning `false`
/// keeps the editor open so the parent can surface the underlying failure.
/// `onCreateEditableCopy` receives the loaded external text and should add a
/// managed text clip to the basket.
struct BasketTextReaderView: View {
    private nonisolated static let externalTextByteLimit = 2 * 1024 * 1024

    let url: URL
    let isManaged: Bool
    let title: String
    let showsTitle: Bool
    let onSave: (String) -> Bool
    let onCreateEditableCopy: (String) -> Void
    let onError: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool
    @State private var text = ""
    @State private var draftText = ""
    @State private var searchQuery = ""
    @State private var searchMatchCount = 0
    @State private var searchMatchIndex = 0
    @State private var isSearchVisible = false
    @State private var isEditing = false
    @State private var isLoading = true
    @State private var showsLoadingIndicator = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var reloadGeneration = 0

    init(
        url: URL,
        isManaged: Bool,
        title: String,
        showsTitle: Bool = true,
        onSave: @escaping (String) -> Bool,
        onCreateEditableCopy: @escaping (String) -> Void,
        onError: @escaping (String) -> Void = { _ in }
    ) {
        self.url = url
        self.isManaged = isManaged
        self.title = title
        self.showsTitle = showsTitle
        self.onSave = onSave
        self.onCreateEditableCopy = onCreateEditableCopy
        self.onError = onError
    }

    var body: some View {
        VStack(spacing: 0) {
            readerHeader
            Divider().opacity(0.45)

            if isSearchVisible || !searchQuery.isEmpty {
                searchBar
                Divider().opacity(0.35)
            }

            if isEditing {
                editorFormattingBar
                Divider().opacity(0.35)
            }

            if let errorMessage {
                errorBanner(errorMessage)
            }

            content
            Divider().opacity(0.35)
            readerFooter
        }
        .background(readerBackground)
        .frame(minWidth: 480, minHeight: 420)
        .task(id: "\(url.standardizedFileURL.path)#\(reloadGeneration)") {
            await loadText()
        }
        .onChange(of: url) { _, _ in
            isEditing = false
            searchQuery = ""
            searchMatchCount = 0
            searchMatchIndex = 0
            isSearchVisible = false
        }
        .onExitCommand {
            if isSearchFocused {
                isSearchFocused = false
            } else if isEditing {
                cancelEditing()
            }
        }
    }

    private var readerHeader: some View {
        HStack(spacing: 10) {
            if showsTitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.isEmpty ? url.lastPathComponent : title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(isManaged ? "文本便笺" : "只读文本文件")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if hasLoaded && !isLoading {
                Button {
                    withReaderAnimation {
                        isSearchVisible.toggle()
                        if isSearchVisible { isSearchFocused = true }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(BasketTextReaderIconButtonStyle())
                .keyboardShortcut("f", modifiers: [.command])
                .help("查找文本")

                if isManaged {
                    Button {
                        if isEditing {
                            cancelEditing()
                        } else {
                            draftText = text
                            isEditing = true
                        }
                    } label: {
                        Label(isEditing ? "取消编辑" : "编辑", systemImage: isEditing ? "xmark" : "pencil")
                    }
                    .buttonStyle(BasketTextReaderToolbarButtonStyle())
                } else {
                    Button {
                        onCreateEditableCopy(text)
                    } label: {
                        Label("创建副本", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(BasketTextReaderToolbarButtonStyle())
                    .disabled(text.isEmpty)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, showsTitle ? 13 : 8)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索文本", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit {
                    moveSearch(by: 1)
                }
                .onChange(of: searchQuery) { _, _ in
                    searchMatchIndex = 0
                }
            if !searchQuery.isEmpty {
                Text(searchResultLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
                Button {
                    moveSearch(by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(BasketTextReaderSearchButtonStyle())
                .disabled(searchMatchCount == 0)
                .help("上一个匹配项")
                Button {
                    moveSearch(by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(BasketTextReaderSearchButtonStyle())
                .disabled(searchMatchCount == 0)
                .help("下一个匹配项")
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035))
    }

    private var editorFormattingBar: some View {
        HStack(spacing: 6) {
            Text("快速格式")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            formattingButton("待办", systemImage: "checklist") {
                draftText = BasketTextFormatting.makeChecklist(draftText)
            }
            formattingButton("编号", systemImage: "list.number") {
                draftText = BasketTextFormatting.makeNumbered(draftText)
            }
            formattingButton("整理", systemImage: "arrow.up.arrow.down") {
                draftText = BasketTextFormatting.sortChecklist(draftText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.025))
    }

    private func formattingButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
        }
        .buttonStyle(BasketTextReaderToolbarButtonStyle())
        .help(label)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && !hasLoaded {
            if showsLoadingIndicator {
                BasketReaderLoadingView(
                    title: "正在读取文本…",
                    detail: url.lastPathComponent,
                    systemImage: "doc.text"
                )
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if isEditing {
            TextEditor(text: $draftText)
                .font(.system(size: 14, weight: .regular, design: .monospaced))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(16)
                .background(Color.primary.opacity(0.018))
        } else if hasLoaded {
            BasketSearchableTextView(
                text: text,
                query: searchQuery,
                currentMatchIndex: searchMatchIndex
            ) { count in
                searchMatchCount = count
                if count == 0 {
                    searchMatchIndex = 0
                } else if searchMatchIndex >= count {
                    searchMatchIndex = count - 1
                }
            }
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Brand.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("内容仍保留在当前阅读窗口中。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button {
                errorMessage = nil
                reloadGeneration += 1
            } label: {
                Text("重试")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Brand.warning.opacity(0.09))
    }

    private var readerFooter: some View {
        HStack(spacing: 10) {
            if isEditing {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isDraftValid ? "修改将保存到文本便笺" : "请输入内容且不超过 256 KiB")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isDraftValid ? .secondary : Brand.danger)
                        .lineLimit(1)
                    Text("\(draftText.count.formatted()) 字符 · \(Self.byteLabel(draftText.utf8.count))")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(isDraftValid ? Color.secondary.opacity(0.72) : Brand.danger)
                        .lineLimit(1)
                }
            } else {
                Text(metadataLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isEditing {
                Button("取消") {
                    cancelEditing()
                }
                .buttonStyle(.plain)
                Button("保存") {
                    saveDraft()
                }
                .buttonStyle(BasketTextReaderPrimaryButtonStyle())
                .disabled(!isDraftValid)
            } else {
                Button {
                    copyText()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(BasketTextReaderToolbarButtonStyle())
                .disabled(text.isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var readerBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.primary.opacity(0.028))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Brand.hairline, lineWidth: 1)
            }
    }

    private var isDraftValid: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draftText.utf8.count <= BasketTextClipStore.maximumTextBytes
    }

    private var metadataLabel: String {
        let bytes = text.utf8.count
        let count = text.count
        if bytes == 0 { return "空文本" }
        return "\(count.formatted()) 字符 · \(Self.byteLabel(bytes))"
    }

    private var searchResultLabel: String {
        guard !searchQuery.isEmpty else { return "" }
        return searchMatchCount == 0
            ? "无匹配"
            : "\(searchMatchIndex + 1)/\(searchMatchCount)"
    }

    private func moveSearch(by offset: Int) {
        guard searchMatchCount > 0 else { return }
        searchMatchIndex = (searchMatchIndex + offset + searchMatchCount) % searchMatchCount
        isSearchFocused = true
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveDraft() {
        guard isDraftValid else { return }
        guard onSave(draftText) else {
            let message = "文本保存失败，请重试。"
            errorMessage = message
            onError(message)
            return
        }
        text = draftText
        errorMessage = nil
        withReaderAnimation {
            isEditing = false
        }
    }

    private func cancelEditing() {
        draftText = text
        withReaderAnimation {
            isEditing = false
        }
    }

    private func withReaderAnimation(_ action: () -> Void) {
        if reduceMotion {
            action()
        } else {
            withAnimation(.easeOut(duration: 0.14), action)
        }
    }

    @MainActor
    private func loadText() async {
        isLoading = true
        showsLoadingIndicator = false
        let indicatorTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(140))
            } catch {
                return
            }
            guard isLoading, !Task.isCancelled else { return }
            showsLoadingIndicator = true
        }
        defer {
            indicatorTask.cancel()
            isLoading = false
            showsLoadingIndicator = false
        }
        let result = await Self.readTextResult(at: url, isManaged: isManaged)
        guard !Task.isCancelled else { return }
        switch result {
        case let .success(loadedText):
            text = loadedText
            draftText = loadedText
            hasLoaded = true
            errorMessage = nil
        case let .failure(loadError):
            let message = loadError.localizedDescription
            hasLoaded = true
            errorMessage = message
            onError(message)
        }
    }

    private static func readTextResult(at url: URL, isManaged: Bool) async -> Result<String, BasketTextReaderLoadError> {
        await Task.detached(priority: .userInitiated) {
            do {
                if isManaged {
                    return .success(try BasketTextClipStore.readText(at: url))
                }

                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    return .failure(BasketTextReaderLoadError(message: "无法读取：这不是普通文本文件。"))
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count <= Self.externalTextByteLimit else {
                    return .failure(BasketTextReaderLoadError(message: "外部文本不能超过 2 MiB。"))
                }
                guard let text = String(data: data, encoding: .utf8) else {
                    return .failure(BasketTextReaderLoadError(message: "无法读取：文件不是有效的 UTF-8 文本。"))
                }
                return .success(text)
            } catch {
                return .failure(BasketTextReaderLoadError(message: error.localizedDescription))
            }
        }.value
    }

    private static func byteLabel(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MiB", Double(bytes) / Double(1024 * 1024))
        }
        if bytes >= 1024 {
            return String(format: "%.1f KiB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }
}

private struct BasketTextReaderLoadError: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private struct BasketTextReaderIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 27, height: 27)
            .background(Color.primary.opacity(configuration.isPressed ? 0.11 : 0.055), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

private struct BasketTextReaderSearchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(Color.primary.opacity(configuration.isPressed ? 0.11 : 0.05), in: Circle())
    }
}

private struct BasketTextReaderToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? .primary : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(configuration.isPressed ? 0.11 : 0.055), in: Capsule())
    }
}

private struct BasketTextReaderPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color(nsColor: .selectedControlTextColor))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Brand.controlAccent.opacity(configuration.isPressed ? 0.76 : 1), in: Capsule())
    }
}

import Foundation
import SwiftUI

/// A compact, always-useful text reminder surface for a basket item.
/// The parent owns window level and persistence; this view only renders the
/// reminder and sends user intent back through the supplied actions.
struct BasketReminderView: View {
    let title: String
    let url: URL
    let isEditable: Bool
    let color: Color
    let backgroundOpacity: Double
    let onEdit: () -> Void
    let onCopy: () -> Void
    let onSend: () -> Void
    let onToggleTodo: (Int) -> String?
    let onReturnToReader: () -> Void
    let onReturnToBasket: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredAction: ReminderAction?
    @State private var text = ""
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.32)
            content
            Divider().opacity(0.28)
            footer
        }
        .background(backgroundSurface)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(color.opacity(0.23), lineWidth: 1)
        }
        .frame(minWidth: 320, minHeight: 140)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredAction)
        .task(id: url.standardizedFileURL.path) {
            await loadText()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 4, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title.isEmpty ? "提醒" : title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("文件篮提醒")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .overlay {
                WindowDragHandle()
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 6)

            reminderButton(
                .returnToBasket,
                systemImage: "chevron.down",
                label: "收回",
                showsLabel: true,
                action: onReturnToBasket
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var content: some View {
        ScrollView(.vertical) {
            if isLoading {
                BasketReaderLoadingView(title: "正在读取提醒…", systemImage: "checklist")
                    .frame(minHeight: 64)
            } else if let loadError {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Brand.warning)
                    Text(loadError)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            } else if text.isEmpty {
                Text("暂无文本内容")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            } else {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(parsedLines.enumerated()), id: \.offset) { index, line in
                        reminderLine(line, index: index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
        .scrollIndicators(.automatic)
        .background(CompactScrollViewConfigurator())
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func reminderLine(_ line: BasketTextParsedLine, index: Int) -> some View {
        if let isChecked = line.isChecked {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    if let updatedText = onToggleTodo(index) {
                        text = updatedText
                    }
                } label: {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isChecked ? color : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!isEditable)
                .help(isEditable ? (isChecked ? "标记为未完成" : "标记为完成") : "外部文本为只读")

                Text(todoLabel(line))
                    .font(.system(size: 13))
                    .foregroundStyle(isChecked ? .secondary : .primary)
                    .strikethrough(isChecked, color: .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(line.raw.isEmpty ? " " : line.raw)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var parsedLines: [BasketTextParsedLine] {
        BasketTextFormatting.parsedLines(text)
    }

    private func todoLabel(_ line: BasketTextParsedLine) -> String {
        let label = line.indentation + line.body
        return label.isEmpty ? "未命名待办" : label
    }

    @MainActor
    private func loadText() async {
        isLoading = true
        loadError = nil
        let maximumExternalTextBytes = 2 * 1024 * 1024
        let result = await Task.detached(priority: .userInitiated) { [url, isEditable] in
            do {
                if isEditable {
                    return Result<String, Error>.success(try BasketTextClipStore.readText(at: url))
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count <= maximumExternalTextBytes else {
                    throw ReminderLoadError.tooLarge
                }
                guard let value = String(data: data, encoding: .utf8) else {
                    throw ReminderLoadError.invalidEncoding
                }
                return .success(value)
            } catch {
                return .failure(error)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case let .success(value):
            text = value
        case let .failure(error):
            text = ""
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private var footer: some View {
        HStack(spacing: 6) {
            reminderButton(.returnToReader, systemImage: "arrow.up.left.and.arrow.down.right", label: "展开阅读", action: onReturnToReader)

            Spacer(minLength: 4)

            reminderButton(.copy, systemImage: "doc.on.doc", label: "复制", action: onCopy)
            if isEditable {
                reminderButton(.edit, systemImage: "pencil", label: "编辑", action: onEdit)
            }
            reminderButton(.send, systemImage: "paperplane", label: "发送", showsLabel: true, action: onSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func reminderButton(
        _ action: ReminderAction,
        systemImage: String,
        label: String,
        showsLabel: Bool = false,
        action handler: @escaping () -> Void
    ) -> some View {
        Button {
            handler()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                if showsLabel {
                    Text(label)
                }
            }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hoveredAction == action ? .primary : .secondary)
                .padding(.horizontal, showsLabel ? 8 : 0)
                .frame(minWidth: 29, minHeight: 27)
                .background(
                    Color.primary.opacity(hoveredAction == action ? 0.11 : 0.055),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(hoveredAction == action ? color.opacity(0.4) : .clear, lineWidth: 1)
                }
                .overlay(alignment: .top) {
                    if !showsLabel, hoveredAction == action {
                        Text(label)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .fixedSize()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .offset(y: -30)
                            .allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            guard !reduceMotion else {
                hoveredAction = isHovering ? action : (hoveredAction == action ? nil : hoveredAction)
                return
            }
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredAction = isHovering ? action : (hoveredAction == action ? nil : hoveredAction)
            }
        }
        .help(label)
        .accessibilityLabel(label)
    }

    private var backgroundSurface: some View {
        ZStack {
            Color.black.opacity(min(max(backgroundOpacity, 0.35), 1))
            color.opacity(0.08)
        }
    }

    private enum ReminderAction: Hashable {
        case returnToBasket
        case returnToReader
        case copy
        case edit
        case send
    }

    private enum ReminderLoadError: LocalizedError {
        case tooLarge
        case invalidEncoding

        var errorDescription: String? {
            switch self {
            case .tooLarge: "外部提醒文本不能超过 2 MiB。"
            case .invalidEncoding: "提醒仅支持 UTF-8 文本。"
            }
        }
    }
}

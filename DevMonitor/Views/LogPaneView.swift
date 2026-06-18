import SwiftUI

/// Live, auto-scrolling terminal log. With `onSubmit` set it also shows an input field (used for
/// the dev server's stdin); without it, it's a read-only viewer (used for the build log).
struct LogPaneView: View {
    let lines: [String]
    var inputPlaceholder: String? = nil
    var onSubmit: ((String) -> Void)? = nil
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(ANSI.attributed(line.isEmpty ? " " : line))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color(white: 0.85))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .background(Color(white: 0.08))
                .onChange(of: lines.count) { _, count in
                    guard count > 0 else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }

            if let placeholder = inputPlaceholder, let onSubmit {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                    TextField(placeholder, text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white)
                        .onSubmit {
                            guard !input.isEmpty else { return }
                            onSubmit(input)
                            input = ""
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color(white: 0.12))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.08))
        )
        .environment(\.colorScheme, .dark)   // dark terminal → light placeholder/cursor
    }
}

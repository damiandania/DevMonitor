import SwiftUI

/// Live, auto-scrolling terminal log. With `onSubmit` set it also shows an input field (used for
/// the dev server's stdin); without it, it's a read-only viewer (used for the build log).
struct LogPaneView: View {
    let lines: [String]
    var inputPlaceholder: String? = nil
    var onSubmit: ((String) -> Void)? = nil
    /// A status strip (e.g. a run timer) pinned at the bottom in place of the stdin input.
    var footer: AnyView? = nil
    /// Terminal appearance: "app" (follow the app theme), "dark", or "light".
    var terminalTheme: String = "dark"
    @State private var input = ""
    @Environment(\.colorScheme) private var appScheme

    /// Resolve the effective terminal scheme — "app" follows the app's appearance.
    private var dark: Bool {
        switch terminalTheme {
        case "light": return false
        case "dark": return true
        default: return appScheme == .dark
        }
    }

    var body: some View {
        let textColor = dark ? Color(white: 0.85) : Color(white: 0.18)
        let bgColor = dark ? Color(white: 0.08) : Color(white: 0.98)
        let inputText = dark ? Color.white : Color.black
        let inputBg = dark ? Color(white: 0.12) : Color(white: 0.94)
        let border = (dark ? Color.white : Color.black).opacity(0.08)

        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(ANSI.attributed(line.isEmpty ? " " : line))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(textColor)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.hidden)   // no scroll bar in the terminal
                .background(bgColor)
                .onChange(of: lines.count) { _, count in
                    guard count > 0 else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }

            if let footer {
                Divider()
                footer
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(inputBg)
            } else if let placeholder = inputPlaceholder, let onSubmit {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                    TextField(placeholder, text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(inputText)
                        .onSubmit {
                            guard !input.isEmpty else { return }
                            onSubmit(input)
                            input = ""
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(inputBg)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(border))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

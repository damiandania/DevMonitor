import SwiftUI

/// Live, auto-scrolling log with an input field that writes to the dev server's stdin.
struct LogPaneView: View {
    let session: DevSession
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(session.logLines.enumerated()), id: \.offset) { index, line in
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
                .onChange(of: session.logLines.count) { _, count in
                    guard count > 0 else { return }
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
                TextField("Send input to the dev server (press Enter)…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .onSubmit {
                        guard !input.isEmpty else { return }
                        session.sendInput(input)
                        input = ""
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(white: 0.12))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.08))
        )
    }
}

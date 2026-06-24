import SwiftUI

/// The unified status of a run-control, so all three pills (dev / worker / build) derive their
/// colour, label, icon and in-progress animation from ONE place and stay perfectly consistent
/// (e.g. "Stopped" is red everywhere, "Building…"/"Launching…" pulse everywhere).
enum RunStatus {
    case idle               // not started — gray, no label, ▶
    case starting(String)   // launching / building — orange, pulsing, ■
    case running(String)    // up — green, ■
    case done(String)       // finished OK (a build) — green, ▶
    case stopped            // cleanly stopped — red, ▶
    case failed(String)     // crashed / errored — red, ▶; the String is the terminal error

    var label: String {
        switch self {
        case .idle: return ""
        case .starting(let l), .running(let l), .done(let l): return l
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .starting: return .orange
        case .running, .done: return .green
        case .stopped, .failed: return .red
        }
    }

    /// Stop icon while in progress / up; play icon otherwise.
    var showsStop: Bool {
        switch self { case .starting, .running: return true; default: return false }
    }

    /// Blink the pill while launching / building to signal work in progress.
    var isInProgress: Bool { if case .starting = self { return true }; return false }

    /// Terminal error to show in the popover (when set, the state word is an underlined link).
    var error: String? { if case .failed(let e) = self { return e }; return nil }
}

/// One project run-control — dev server, worker, or build — as a single tinted pill: the play/stop
/// icon plus the action name (bold) and a short status live inside, and tapping the pill toggles it.
/// When failed, the status word is underlined and opens a popover with the terminal error. While
/// launching/building the pill pulses. All three dashboard controls share this and one `RunStatus`.
struct RunControlButton: View {
    let title: String
    let status: RunStatus
    let onToggle: () -> Void

    @State private var showError = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.showsStop ? "stop.fill" : "play.fill")
                .font(.system(size: 14, weight: .bold))
            HStack(spacing: 5) {
                Text(title).fontWeight(.bold)
                stateLabel
            }
            .font(.callout)
            // Blink just the text (not the whole pill) while launching/building.
            .pulsing(active: status.isInProgress)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(status.color, in: Capsule())
        .contentShape(Capsule())
        // The pill (everything except the underlined error word) toggles play/stop.
        .onTapGesture(perform: onToggle)
        .help(status.showsStop ? "Stop \(title.lowercased())" : "Start \(title.lowercased())")
        .animation(.easeInOut(duration: 0.2), value: status.showsStop)
        // VoiceOver: the pill is a custom tap target, so expose it as a button with the action name
        // and current state, and route the tap through an accessibility action.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(status.showsStop ? "Stop" : "Start") \(title)")
        .accessibilityValue(status.label)
        .accessibilityAction(.default, onToggle)
    }

    @ViewBuilder private var stateLabel: some View {
        let label = status.label
        if label.isEmpty {
            EmptyView()   // idle → show just the name
        } else if let error = status.error {
            // Underlined + clickable → opens the error popover. Being a Button, it consumes the tap
            // so the pill's play/stop gesture doesn't also fire.
            Button { showError = true } label: {
                Text(label).underline()
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showError, arrowEdge: .bottom) {
                ErrorPopover(title: title, detail: error)
            }
        } else {
            Text(label)
        }
    }
}

/// The failure dialog opened from a run-control's underlined state: the terminal error, selectable
/// and copyable.
private struct ErrorPopover: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(title) error", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.red)
                Spacer(minLength: 16)
                CopyButton(text: detail, help: "Copy the \(title.lowercased()) error")
            }
            ScrollView {
                Text(detail.isEmpty ? "No output." : detail)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)   // override the white inherited from the pill
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 440, height: 260)
        }
        .padding(14)
    }
}

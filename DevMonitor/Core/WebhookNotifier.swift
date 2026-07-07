import Foundation

/// Best-effort outbound webhook for supervision notifications. POSTs a JSON body that works for
/// BOTH Slack (`text`) and Discord (`content`) incoming webhooks — each service reads its own key
/// and ignores the other — so one URL covers either. Fire-and-forget: a slow or down webhook must
/// never affect supervision, so the POST runs detached and all failures are swallowed.
enum WebhookNotifier {
    /// The JSON body for a notification — pure + testable. `text` (Slack) and `content` (Discord)
    /// both carry "Title — body" (or just the title when the body is empty).
    static func payload(title: String, body: String) -> Data {
        let line = body.isEmpty ? title : "\(title) — \(body)"
        return (try? JSONSerialization.data(withJSONObject: ["text": line, "content": line])) ?? Data()
    }

    /// Whether `urlString` is a usable http(s) webhook endpoint (so the UI can validate and `post`
    /// can no-op on junk). Pure.
    static func isValid(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return false }
        return true
    }

    /// POST the notification to `urlString` if valid. Best-effort, detached; never throws to the caller.
    static func post(urlString: String, title: String, body: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard isValid(trimmed), let url = URL(string: trimmed) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload(title: title, body: body)
        req.timeoutInterval = 10
        Task.detached { _ = try? await URLSession.shared.data(for: req) }
    }
}

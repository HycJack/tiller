import Foundation

/// Asks the profile's search engine for suggestions while the user types in
/// the address bar. Requests wait a moment for typing to pause, and a newer
/// one cancels the one before it. They carry no cookies, so the engine sees
/// the query but not who typed it.
@MainActor
final class SearchSuggest {
    private let settings: ProfileSettings
    private var task: Task<Void, Never>?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 2
        return URLSession(configuration: configuration)
    }()
    private static let delay: Duration = .milliseconds(80)

    init(settings: ProfileSettings) {
        self.settings = settings
    }

    /// Calls `completion` with up to `limit` suggestions for `text`, unless
    /// another request or `cancel` comes first, or the engine has none to
    /// give. Text that is already a URL isn't sent.
    func fetch(_ text: String, limit: Int, completion: @escaping @MainActor ([String]) -> Void) {
        cancel()
        guard settings.searchSuggestions, !text.contains("://"), let url = settings.suggestURL(for: text) else { return }
        task = Task {
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let (data, response) = try? await Self.session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200, !Task.isCancelled else { return }
            completion(Array(Self.parse(data).prefix(limit)))
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// The suggestions in an OpenSearch answer, `[query, [suggestion, ...]]`.
    nonisolated static func parse(_ data: Data) -> [String] {
        guard let answer = try? JSONSerialization.jsonObject(with: data) as? [Any], answer.count > 1,
              let suggestions = answer[1] as? [Any] else { return [] }
        return suggestions.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

import Foundation
import Testing
@testable import Tiller

@MainActor
struct AddressBarTests {
    @Test func atRestLeavesOutSchemeWwwAndLoneSlash() {
        #expect(AddressField.display("https://www.github.com/", full: false).text == "github.com")
        #expect(AddressField.display("http://example.com/a/b?q=1", full: false).text == "example.com/a/b?q=1")
        // Only a slash with nothing after it goes.
        #expect(AddressField.display("https://example.com/a/", full: false).text == "example.com/a/")
        #expect(AddressField.display("https://www.github.com/", full: true).text == "https://www.github.com/")
        #expect(AddressField.display("about:settings", full: false).text == "about:settings")
    }

    @Test func siteRangeCoversTheHostOfAShortenedAddress() {
        let (text, site) = AddressField.display("https://www.example.com:8080/path", full: false)
        #expect((text as NSString).substring(with: site) == "example.com:8080")
    }

    private func page(_ url: String, visits: Int = 1, typed: Int = 0, daysAgo: Double = 0) -> HistoryPage {
        HistoryPage(
            url: url, title: "", visitCount: visits, lastVisit: Date().addingTimeInterval(-daysAgo * 86_400),
            typedCount: typed)
    }

    @Test func completesFromATypedOrRevisitedPage() {
        let once = page("https://github.com/")
        #expect(AddressSuggestions.completionPage(for: "git", in: [once]) == nil)
        let typed = page("https://www.github.com/", typed: 1)
        let completed = AddressSuggestions.completionPage(for: "git", in: [once, typed])
        #expect(completed?.url == typed.url)
        #expect(AddressSuggestions.completion(of: typed, after: "git") == "hub.com")
        // Nothing to add, or a space in the text: no completion.
        #expect(AddressSuggestions.completionPage(for: "github.com", in: [typed]) == nil)
        #expect(AddressSuggestions.completionPage(for: "git hub", in: [typed]) == nil)
    }

    @Test func frecencyFavorsTypedAndRecentVisits() {
        #expect(HistoryStore.frecency(page("a", visits: 2, typed: 1)) > HistoryStore.frecency(page("b", visits: 5)))
        #expect(HistoryStore.frecency(page("a", visits: 5)) > HistoryStore.frecency(page("b", visits: 5, daysAgo: 60)))
    }

    @Test func siteRoots() {
        #expect(HistoryStore.isSiteRoot("github.com"))
        #expect(HistoryStore.isSiteRoot("github.com/"))
        #expect(!HistoryStore.isSiteRoot("github.com/sorrycc"))
        #expect(!HistoryStore.isSiteRoot("github.com/?tab=1"))
    }

    @Test func parsesOpenSearchSuggestions() {
        let data = Data(#"["tiller",["tiller browser"," tiller app ",""],[],{}]"#.utf8)
        #expect(SearchSuggest.parse(data) == ["tiller browser", "tiller app"])
        #expect(SearchSuggest.parse(Data("nope".utf8)).isEmpty)
    }

    /// Runs a search on `store` and waits for it.
    private func search(_ store: HistoryStore, _ text: String) async -> [HistoryPage] {
        await withCheckedContinuation { continuation in
            store.search(text, limit: 8) { continuation.resume(returning: $0) }
        }
    }

    @Test func historyCountsTypedVisitsAndForgetsPages() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TillerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HistoryStore(path: folder.appendingPathComponent("history.sqlite").path)
        store.recordVisit(url: "https://github.com/sorrycc", title: "sorrycc")
        store.recordVisit(url: "https://github.com/sorrycc", title: "sorrycc")
        store.recordVisit(url: "https://github.com/", title: "GitHub", typed: true)
        let pages = await search(store, "git")
        // The site's front page comes first, though visited less.
        #expect(pages.map(\.url) == ["https://github.com/", "https://github.com/sorrycc"])
        #expect(pages.first?.typedCount == 1)
        store.remove(url: "http://www.github.com/")
        #expect(await search(store, "git").map(\.url) == ["https://github.com/sorrycc"])
    }
}

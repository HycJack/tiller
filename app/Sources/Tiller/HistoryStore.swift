import Foundation
import os

struct HistoryPage: Sendable {
    let url: String
    let title: String
    let visitCount: Int
    let lastVisit: Date
    /// The site's favicon, which only `search` fills in.
    var icon: Data?

    /// The title on one line, as some pages' titles hold line breaks; the
    /// address without its scheme when there is none.
    var displayTitle: String {
        let line = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? HistoryStore.bare(url) : line
    }
}

/// A site on the start page.
struct FrequentSite: Sendable, Equatable {
    let host: String
    /// The site's most visited page, which the tile opens.
    let url: String
    let title: String
    let icon: Data?
}

/// A profile's browsing history: one row per URL, in `history.sqlite` in its
/// folder. Chromium keeps its own History file, but CEF has no API for it and
/// holds it locked. Database work runs on a serial queue.
final class HistoryStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.sorrycc.tiller.history")
    /// Numbers each search, so one that a newer search has replaced before it
    /// got to run can be skipped.
    private let latestSearch = OSAllocatedUnfairLock(initialState: 0)
    /// Only touched on `queue`. Nil if the file couldn't be opened.
    private let db: SQLiteDatabase?
    /// Counts writes, so a reader can tell whether anything changed since it last looked.
    private let writes = OSAllocatedUnfairLock(initialState: 0)

    /// Goes up with every write. Equal values mean the history is as it was.
    var version: Int { writes.withLock { $0 } }

    init(path: String) {
        do {
            let db = try SQLiteDatabase(path: path)
            try db.execute("""
                PRAGMA journal_mode = WAL;
                PRAGMA synchronous = NORMAL;
                CREATE TABLE IF NOT EXISTS pages (
                    url TEXT PRIMARY KEY,
                    title TEXT NOT NULL DEFAULT '',
                    visit_count INTEGER NOT NULL DEFAULT 0,
                    last_visit REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS pages_last_visit ON pages (last_visit DESC);
                CREATE INDEX IF NOT EXISTS pages_visits ON pages (visit_count DESC, last_visit DESC);
                CREATE TABLE IF NOT EXISTS icons (
                    host TEXT PRIMARY KEY,
                    png BLOB NOT NULL
                );
                """)
            self.db = db
        } catch {
            NSLog("Tiller: history unavailable: \(error)")
            db = nil
        }
    }

    /// Counts a visit to `url`, and keeps `title` unless it is empty.
    func recordVisit(url: String, title: String) {
        write("""
            INSERT INTO pages (url, title, visit_count, last_visit) VALUES (?, ?, 1, ?)
            ON CONFLICT (url) DO UPDATE SET
                visit_count = visit_count + 1,
                last_visit = excluded.last_visit,
                title = CASE WHEN excluded.title = '' THEN title ELSE excluded.title END
            """, [url, title, Date().timeIntervalSince1970])
    }

    func setTitle(_ title: String, for url: String) {
        write("UPDATE pages SET title = ? WHERE url = ?", [title, url])
    }

    /// Keeps a site's favicon for the start page. One icon per host.
    func setIcon(_ png: Data, for url: String) {
        guard let host = Self.host(of: url) else { return }
        write("INSERT OR REPLACE INTO icons (host, png) VALUES (?, ?)", [host, png])
    }

    /// The favicon saved for the site of `url`, or nil. `completion` runs on
    /// the store's queue.
    func icon(for url: String, completion: @escaping @Sendable (Data?) -> Void) {
        guard let host = Self.host(of: url) else { return completion(nil) }
        queue.async { [db] in
            completion((try? db?.query("SELECT png FROM icons WHERE host = ?", [host]) { $0.data(0) })?.first)
        }
    }

    func clear() {
        write("DELETE FROM pages", [])
        write("DELETE FROM icons", [])
    }

    /// The most visited sites, by their pages' visits added up, each with
    /// its most visited page and its favicon if one was saved. `completion`
    /// runs on the store's queue.
    func frequentSites(limit: Int, completion: @escaping @Sendable ([FrequentSite]) -> Void) {
        queue.async { [db] in
            // Pages come most visited first, so a host's first page is its best.
            let pages = (try? db?.query("""
                SELECT url, title, visit_count, last_visit FROM pages
                ORDER BY visit_count DESC, last_visit DESC LIMIT 5000
                """, row: Self.page)) ?? []
            var best: [String: HistoryPage] = [:]
            var visits: [String: Int] = [:]
            for page in pages {
                guard let host = Self.host(of: page.url) else { continue }
                if best[host] == nil { best[host] = page }
                visits[host, default: 0] += page.visitCount
            }
            let hosts = visits.sorted { ($0.value, best[$0.key]!.lastVisit) > ($1.value, best[$1.key]!.lastVisit) }
                .prefix(limit).map(\.key)
            let icons = Self.icons(for: Array(hosts), in: db)
            completion(hosts.map { host in
                let page = best[host]!
                return FrequentSite(host: host, url: page.url, title: page.title, icon: icons[host])
            })
        }
    }

    /// Most recently visited first. `completion` runs on the store's queue.
    func recent(limit: Int, completion: @escaping @Sendable ([HistoryPage]) -> Void) {
        queue.async { [db] in
            completion((try? db?.query(
                "SELECT url, title, visit_count, last_visit FROM pages ORDER BY last_visit DESC LIMIT ?",
                [limit], row: Self.page
            )) ?? [])
        }
    }

    /// Like `recent`, with each page's site favicon filled in, for the
    /// History menu. `completion` runs on the store's queue.
    func recentWithIcons(limit: Int, completion: @escaping @Sendable ([HistoryPage]) -> Void) {
        queue.async { [db] in
            var pages = (try? db?.query(
                "SELECT url, title, visit_count, last_visit FROM pages ORDER BY last_visit DESC LIMIT ?",
                [limit], row: Self.page
            )) ?? []
            let icons = Self.icons(for: Array(Set(pages.compactMap { Self.host(of: $0.url) })), in: db)
            for index in pages.indices {
                pages[index].icon = Self.host(of: pages[index].url).flatMap { icons[$0] }
            }
            completion(pages)
        }
    }

    /// Pages whose URL or title contains `text`, best first: URLs that start
    /// with it, then titles with a word that starts with it, then the rest,
    /// each by visit count, with their sites' favicons. Of pages that differ
    /// only in scheme or "www.", only the first is kept. `completion` runs on the store's queue. A search
    /// that a newer one replaces before it runs never completes, so typing
    /// fast doesn't queue up a scan per keystroke.
    func search(_ text: String, limit: Int, completion: @escaping @Sendable ([HistoryPage]) -> Void) {
        let number = latestSearch.withLock { latest in
            latest += 1
            return latest
        }
        queue.async { [db, latestSearch] in
            guard latestSearch.withLock({ $0 }) == number else { return }
            let pattern = "%" + text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_") + "%"
            let pages = (try? db?.query("""
                SELECT url, title, visit_count, last_visit FROM pages
                WHERE url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\'
                ORDER BY visit_count DESC, last_visit DESC LIMIT 300
                """, [pattern], row: Self.page)) ?? []
            let query = text.lowercased()
            let ranked = pages.map { page -> (HistoryPage, Int) in
                if Self.bare(page.url).lowercased().hasPrefix(query) { return (page, 2) }
                let words = page.title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                return (page, words.contains { $0.hasPrefix(query) } ? 1 : 0)
            }
            // A stable sort keeps the query's visit-count order within each rank.
            let best = ranked.enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }
            // Pages that differ only in scheme or "www." look the same in the
            // list, so only the best of them is kept.
            var seen = Set<String>()
            let top = best.map(\.element.0).filter { seen.insert(Self.bare($0.url).lowercased()).inserted }.prefix(limit)
            let icons = Self.icons(for: Array(Set(top.compactMap { Self.host(of: $0.url) })), in: db)
            completion(top.map { page in
                var page = page
                page.icon = Self.host(of: page.url).flatMap { icons[$0] }
                return page
            })
        }
    }

    /// Merges pages from another browser. An existing page keeps its title and
    /// takes the higher visit count and later visit. Reports how many were
    /// merged, on the store's queue.
    func importPages(_ pages: [HistoryPage], completion: @escaping @Sendable (Result<Int, Error>) -> Void) {
        writes.withLock { $0 += 1 }
        // In chunks, each its own transaction, and each queuing the next
        // when it is done, so the address bar's searches and the start
        // page's tiles asked for meanwhile run between them rather than wait
        // out an import of a long history.
        let chunks = stride(from: 0, to: pages.count, by: Self.importChunk).map {
            Array(pages[$0..<min($0 + Self.importChunk, pages.count)])
        }
        importChunks(chunks[...], total: pages.count, completion: completion)
    }

    private func importChunks(
        _ chunks: ArraySlice<[HistoryPage]>, total: Int, completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        guard let chunk = chunks.first else { return completion(.success(total)) }
        queue.async { [weak self, db, writes] in
            guard let db else { return completion(.failure(SQLiteError(description: "history database unavailable"))) }
            do {
                try db.transaction {
                    try db.runEach("""
                        INSERT INTO pages (url, title, visit_count, last_visit) VALUES (?, ?, ?, ?)
                        ON CONFLICT (url) DO UPDATE SET
                            visit_count = max(visit_count, excluded.visit_count),
                            last_visit = max(last_visit, excluded.last_visit),
                            title = CASE WHEN title = '' THEN excluded.title ELSE title END
                        """, chunk.map { [$0.url, $0.title, $0.visitCount, $0.lastVisit.timeIntervalSince1970] })
                }
            } catch {
                // The chunks after it are dropped. Those before are kept,
                // which an import run again merges with.
                return completion(.failure(error))
            }
            writes.withLock { $0 += 1 }
            guard let self else { return completion(.success(total)) }
            self.importChunks(chunks.dropFirst(), total: total, completion: completion)
        }
    }

    private static let importChunk = 2000

    /// The saved favicons of `hosts`, in one query.
    private static func icons(for hosts: [String], in db: SQLiteDatabase?) -> [String: Data] {
        guard !hosts.isEmpty else { return [:] }
        let marks = Array(repeating: "?", count: hosts.count).joined(separator: ",")
        let rows = (try? db?.query("SELECT host, png FROM icons WHERE host IN (\(marks))", hosts) { ($0.string(0), $0.data(1)) }) ?? []
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    private func write(_ sql: String, _ values: [Any?]) {
        writes.withLock { $0 += 1 }
        // Values are strings and numbers, which are safe to hand to the queue.
        nonisolated(unsafe) let values = values
        queue.async { [db] in
            do {
                try db?.run(sql, values)
            } catch {
                NSLog("Tiller: history write failed: \(error)")
            }
        }
    }

    private static func page(_ row: SQLiteDatabase.Row) -> HistoryPage {
        HistoryPage(
            url: row.string(0), title: row.string(1), visitCount: Int(row.int(2)),
            lastVisit: Date(timeIntervalSince1970: row.double(3))
        )
    }

    /// The host of a web page's URL, without a leading "www.".
    static func host(of url: String) -> String? {
        guard url.hasPrefix("http://") || url.hasPrefix("https://"), var host = URL(string: url)?.host()?.lowercased(),
            !host.isEmpty
        else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// `url` without its scheme and a leading "www.".
    static func bare(_ url: String) -> String {
        var rest = Substring(url)
        if let range = rest.range(of: "://") { rest = rest[range.upperBound...] }
        if rest.hasPrefix("www.") { rest = rest.dropFirst(4) }
        return String(rest)
    }
}

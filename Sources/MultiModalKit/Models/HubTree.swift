import Foundation

// ONE REQUEST, EVERY FILE, EVERY SIZE (5a, SPEC §199 Fact 4; D-114
// F-3 = A, F-5 = A).
//
// Three of this library's four downloadable engines fetch from the same
// place — Hugging Face — and each needs the same thing before it can
// plan a download: the repository's file names WITH their byte sizes.
// The Hub answers that in one request:
//
//     GET <host>/api/models/<repo>/tree/main/<path>?recursive=true
//     [{"type":"file","path":"config.json","size":937}, …]
//
// Measured on 2026-09-19: the 4B mind's nine files in 0.22 s, against
// ten listings and nine HEADs through the vendor client (INSTRUMENTS
// §66). It lives in the CORE because a second engine needed it — the
// Whisper ear — and a listing is a fact about the Hub, not about any one
// organ. Foundation only; the core keeps its zero runtime dependencies.

/// A repository's files, listed.
public enum HubTree {
    /// One file in a repository: its path from the repository root, and
    /// its size when the Hub gives one (it does, for every file this
    /// library fetches — a large file's `size` is the file's own, not
    /// its pointer's).
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let bytes: Int64?

        public init(path: String, bytes: Int64?) {
            self.path = path
            self.bytes = bytes
        }
    }

    /// Its own session, never `URLSession.shared`.
    ///
    /// Two reasons, and the first is a red run. The process-global
    /// `URLProtocol` registry reaches `URLSession.shared` and nothing
    /// else, and the network-silence proof (AC-252) listens there for
    /// requests a LOAD leaks; a listing is a request this library makes
    /// on purpose, at a person's ask, and must not be mistaken for a leak
    /// by a suite running beside it — the full suite went red exactly
    /// that way while 5a was written. And an ephemeral session shares no
    /// cookie and no cache with the app's own traffic, so the answer is
    /// the server's every time.
    public static let session = URLSession(configuration: .ephemeral)

    /// Lists `repo` — all of it, or the subtree at `path` — in one
    /// request. Entries are FILES only; directories are dropped, because
    /// a plan is made of files.
    ///
    /// It fetches nothing and writes nothing: a question, answered in a
    /// moment, on a foreground session.
    ///
    /// - Throws: `DownloadFailure.listingFailed` when the request, the
    ///   status or the JSON says no.
    public static func list(repo: String,
                            path: String = "",
                            host: URL,
                            session: URLSession = HubTree.session) async throws -> [Entry] {
        // `appending(path: "")` leaves a TRAILING SLASH, and a slash is
        // part of a path: the whole-repository listing then asked for
        // `…/tree/main/` and the loopback server, which serves by exact
        // path, counted a request for something else. So the subtree is
        // appended only when there is one.
        var url = host.appending(path: "api/models").appending(path: repo).appending(path: "tree/main")
        if !path.isEmpty { url = url.appending(path: path) }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        guard let asked = components?.url else {
            throw DownloadFailure.listingFailed(repo: repo, "no URL could be built for this repository")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: asked)
        } catch {
            if error is CancellationError { throw error }
            throw DownloadFailure.listingFailed(repo: repo, String(describing: error))
        }
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw DownloadFailure.listingFailed(repo: repo, "the server answered \(status)")
        }
        do {
            return try JSONDecoder().decode([Row].self, from: data)
                .filter { $0.type == "file" }
                .map { Entry(path: $0.path, bytes: $0.size) }
        } catch {
            throw DownloadFailure.listingFailed(repo: repo, String(describing: error))
        }
    }

    /// One row of the answer — the three fields this library reads, and
    /// nothing it does not.
    private struct Row: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }
}

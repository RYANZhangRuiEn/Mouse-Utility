import Foundation

/// SemVer ordering includes preview.9 < preview.10 < stable.
struct ReleaseVersion: Comparable {
    let core: [Int]
    let prerelease: [String]
    init?(_ tag: String) {
        guard tag.utf8.count <= 120 else { return nil }
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#
        guard value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex else { return nil }
        let unbuilt = value.split(separator: "+", maxSplits: 1)[0]
        let parts = unbuilt.split(separator: "-", maxSplits: 1)
        let numbers = parts[0].split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        core = numbers
        prerelease = parts.count == 2 ? parts[1].split(separator: ".").map(String.init) : []
        guard !prerelease.contains(where: { Self.numeric($0) && $0.count > 1 && $0.first == "0" }) else { return nil }
    }
    private static func numeric(_ s: String) -> Bool { s.utf8.allSatisfy { (48...57).contains($0) } }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.core != rhs.core { return lhs.core.lexicographicallyPrecedes(rhs.core) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (a,b) in zip(lhs.prerelease,rhs.prerelease) where a != b {
            let an = numeric(a), bn = numeric(b)
            if an != bn { return an }
            if an && a.count != b.count { return a.count < b.count }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct PublishedRelease: Equatable {
    let tag: String
    let page: URL
}

enum ReleaseCatalog {
    static let api = URL(string: "https://api.github.com/repos/RYANZhangRuiEn/Mouse-Utility/releases?per_page=100")!
    static let maximumBytes = 2_000_000
    static var currentTag: String { Bundle.main.object(forInfoDictionaryKey: "MouseRingReleaseTag") as? String ?? "v1.0.0-preview.4" }
    private struct Record: Decodable { let tag_name: String; let html_url: String; let draft: Bool }
    static func validPage(_ url: URL, tag: String) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "https", c.host?.lowercased() == "github.com", c.port == nil,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil else { return false }
        return c.path == "/RYANZhangRuiEn/Mouse-Utility/releases/tag/" + tag
    }
    static func newest(in data: Data, after tag: String) throws -> PublishedRelease? {
        guard data.count <= maximumBytes, let current = ReleaseVersion(tag) else { throw ReleaseCheckError.invalidResponse }
        let records = try JSONDecoder().decode([Record].self, from: data)
        return records.compactMap { record -> PublishedRelease? in
            guard !record.draft, let version = ReleaseVersion(record.tag_name), version > current,
                  let page = URL(string: record.html_url), validPage(page,tag: record.tag_name) else { return nil }
            return PublishedRelease(tag: record.tag_name,page: page)
        }.max { ReleaseVersion($0.tag)! < ReleaseVersion($1.tag)! }
    }
}

enum ReleaseCheckError: LocalizedError {
    case invalidResponse, serviceUnavailable, rateLimited
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub 的版本信息暂时无法读取，请稍后重试。"
        case .serviceUnavailable: return "暂时无法连接 GitHub，请检查网络后重试。"
        case .rateLimited: return "GitHub 暂时限制了检查次数，请稍后重试。"
        }
    }
}

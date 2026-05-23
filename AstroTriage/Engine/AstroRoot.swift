// User-configured default folder containing astro files. Lives in `astro_root`
// (v10 migration). The MCP server reads this table to resolve human-friendly
// references like "the RC12 NAS folder" into absolute paths.
//
// The `bookmark` column holds a security-scoped bookmark so the sandboxed app
// can re-access the folder across launches without re-prompting the user.
// Bookmarks are machine-specific — when this DB syncs to another Mac via
// iCloud, the bookmark will fail to resolve and the user will be re-prompted
// at first use.
import Foundation
import GRDB

struct AstroRoot: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: Int64?
    var path: String
    var bookmark: Data?
    var setupTag: String?
    var nickname: String?
    var createdAt: String
    var lastUsedAt: String?

    static let databaseTableName = "astro_root"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var displayName: String {
        if let nick = nickname, !nick.isEmpty { return nick }
        if let tag = setupTag, !tag.isEmpty { return tag }
        return (path as NSString).lastPathComponent
    }
}

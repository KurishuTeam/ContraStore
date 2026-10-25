import Foundation
import SQLite3

@objc(DatabaseManager)
@objcMembers
public class DatabaseManager: NSObject {
    public static let shared = DatabaseManager()

    private var db: OpaquePointer? = nil
    private let dbQueue = DispatchQueue(label: "com.kurishu.contrainstalld.dbQueue", qos: .utility)
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private override init() {
        super.init()
        initializeDatabase()
    }

    deinit {
        dbQueue.sync {
            if let db = db {
                sqlite3_close(db)
            }
        }
    }

    private func getDatabasePath() -> String {
        return jbPath("/var/mobile/Library/ContraStore/contra.db")
    }

    public func initializeDatabase() {
        dbQueue.sync {
            let dbPath = getDatabasePath()
            let dirPath = (dbPath as NSString).deletingLastPathComponent
            let fileManager = FileManager.default

            if !fileManager.fileExists(atPath: dirPath) {
                try? fileManager.createDirectory(atPath: dirPath, withIntermediateDirectories: true, attributes: nil)
            }

            if sqlite3_open(dbPath, &db) == SQLITE_OK {
                let createTableQuery = """
                CREATE TABLE IF NOT EXISTS apps (
                    bundle_id TEXT PRIMARY KEY,
                    real_bundle_path TEXT,
                    fake_bundle_path TEXT,
                    real_data_path TEXT,
                    fake_data_path TEXT
                );
                """
                var errMsg: UnsafeMutablePointer<CChar>? = nil
                if sqlite3_exec(db, createTableQuery, nil, nil, &errMsg) != SQLITE_OK {
                    let err = errMsg.flatMap { String(cString: $0) } ?? "unknown error"
                    print("[DatabaseManager] Error creating table: \(err)")
                    sqlite3_free(errMsg)
                } else {
                    print("[DatabaseManager] Database initialized at: \(dbPath)")
                }
            } else {
                print("[DatabaseManager] Failed to open database at: \(dbPath)")
            }
        }
    }

    public func getAppInfo(forBundleID bundleID: String) -> [String: String]? {
        var appInfo: [String: String]? = nil
        dbQueue.sync {
            guard let db = db else { return }
            let query = """
            SELECT bundle_id, real_bundle_path, fake_bundle_path, real_data_path, fake_data_path
            FROM apps
            WHERE bundle_id = ?;
            """
            var stmt: OpaquePointer? = nil
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                return
            }
            defer { sqlite3_finalize(stmt) }

            bundleID.withCString {
                sqlite3_bind_text(stmt, 1, $0, -1, sqliteTransient)
            }

            if sqlite3_step(stmt) == SQLITE_ROW {
                let getString: (Int32) -> String = { col in
                    if let cStr = sqlite3_column_text(stmt, col) {
                        return String(cString: cStr)
                    }
                    return ""
                }
                appInfo = [
                    "bundle_id": getString(0),
                    "real_bundle_path": getString(1),
                    "fake_bundle_path": getString(2),
                    "real_data_path": getString(3),
                    "fake_data_path": getString(4)
                ]
            }
        }
        return appInfo
    }

    @discardableResult
    public func saveApp(bundleID: String,
                        realBundlePath: String,
                        fakeBundlePath: String,
                        realDataPath: String,
                        fakeDataPath: String) -> Bool {
        var success = false
        dbQueue.sync {
            guard let db = db else { return }
            let query = """
            INSERT OR REPLACE INTO apps (bundle_id, real_bundle_path, fake_bundle_path, real_data_path, fake_data_path)
            VALUES (?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer? = nil
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                return
            }
            defer { sqlite3_finalize(stmt) }

            bundleID.withCString { sqlite3_bind_text(stmt, 1, $0, -1, sqliteTransient) }
            realBundlePath.withCString { sqlite3_bind_text(stmt, 2, $0, -1, sqliteTransient) }
            fakeBundlePath.withCString { sqlite3_bind_text(stmt, 3, $0, -1, sqliteTransient) }
            realDataPath.withCString { sqlite3_bind_text(stmt, 4, $0, -1, sqliteTransient) }
            fakeDataPath.withCString { sqlite3_bind_text(stmt, 5, $0, -1, sqliteTransient) }

            if sqlite3_step(stmt) == SQLITE_DONE {
                success = true
                print("[DatabaseManager] Saved app: \(bundleID)")
            }
        }
        return success
    }
}

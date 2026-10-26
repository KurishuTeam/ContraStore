import Foundation
import SQLite3

@objc(DatabaseManager)
@objcMembers
public class DatabaseManager: NSObject {
    @objc public static let shared = DatabaseManager()

    private var db: OpaquePointer? = nil
    private let dbQueue = DispatchQueue(label: "com.kurishu.contrainstalld.dbQueue", qos: .utility)
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private override init() {
        super.init()
        initializeDatabase()
    }

    deinit {
        dbQueue.sync {
            if db != nil {
                sqlite3_close(db)
                db = nil
            }
        }
    }

    func ROOT_PATH_NS(_ path: String) -> String {
        // Resolve path against rootless jailbreak prefix using libroot
        let prefixPtr = libroot_dyn_get_jbroot_prefix()
        let prefix = String(cString: prefixPtr)
        if !prefix.isEmpty {
            return (prefix as NSString).appendingPathComponent(path)
        }
        return path
    }

    private func initializeDatabase() {
        dbQueue.sync {
            let dbPath = ROOT_PATH_NS("/var/mobile/Library/ContraStore/contra.db")
            let dbDir = (dbPath as NSString).deletingLastPathComponent
            let fileManager = FileManager.default

            if !fileManager.fileExists(atPath: dbDir) {
                do {
                    try fileManager.createDirectory(atPath: dbDir, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    NSLog("[DatabaseManager] Error creating directory at %@: %@", dbDir, error.localizedDescription)
                    return
                }
            }

            if sqlite3_open(dbPath, &db) == SQLITE_OK {
                let createTableQuery = """
                CREATE TABLE IF NOT EXISTS installed_apps (
                    bundle_id TEXT PRIMARY KEY,
                    real_bundle_path TEXT,
                    fake_bundle_path TEXT,
                    real_data_path TEXT,
                    fake_data_path TEXT
                );
                """

                var errMsg: UnsafeMutablePointer<CChar>? = nil
                if sqlite3_exec(db, createTableQuery, nil, nil, &errMsg) != SQLITE_OK {
                    let errStr = errMsg.flatMap { String(cString: $0) } ?? "Unknown error"
                    NSLog("[DatabaseManager] Error creating table: %@", errStr)
                    sqlite3_free(errMsg)
                } else {
                    NSLog("[DatabaseManager] Database initialized at %@", dbPath)
                }
            } else {
                NSLog("[DatabaseManager] Failed to open database at %@", dbPath)
            }
        }
    }

    @objc public func saveApp(bundleId: String, realBundle: String, fakeBundle: String, realData: String, fakeData: String) -> Bool {
        var success = false

        dbQueue.sync {
            guard let db = db else { return }

            let query = """
            INSERT OR REPLACE INTO installed_apps (bundle_id, real_bundle_path, fake_bundle_path, real_data_path, fake_data_path)
            VALUES (?, ?, ?, ?, ?);
            """

            var stmt: OpaquePointer? = nil
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                let err = String(cString: sqlite3_errmsg(db))
                NSLog("[DatabaseManager] Failed to prepare insert statement: %@", err)
                return
            }

            defer {
                sqlite3_finalize(stmt)
            }

            _ = bundleId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
            _ = realBundle.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
            _ = fakeBundle.withCString { sqlite3_bind_text(stmt, 3, $0, -1, SQLITE_TRANSIENT) }
            _ = realData.withCString { sqlite3_bind_text(stmt, 4, $0, -1, SQLITE_TRANSIENT) }
            _ = fakeData.withCString { sqlite3_bind_text(stmt, 5, $0, -1, SQLITE_TRANSIENT) }

            if sqlite3_step(stmt) == SQLITE_DONE {
                success = true
                NSLog("[DatabaseManager] Successfully saved app: %@", bundleId)
            } else {
                let err = String(cString: sqlite3_errmsg(db))
                NSLog("[DatabaseManager] Failed to execute insert: %@", err)
            }
        }

        return success
    }

    @objc public func getAppInfoForBundleID(_ bundleId: String) -> [String: String]? {
        var appInfo: [String: String]? = nil

        dbQueue.sync {
            guard let db = db else { return }

            let query = """
            SELECT bundle_id, real_bundle_path, fake_bundle_path, real_data_path, fake_data_path
            FROM installed_apps
            WHERE bundle_id = ?;
            """

            var stmt: OpaquePointer? = nil
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                let err = String(cString: sqlite3_errmsg(db))
                NSLog("[DatabaseManager] Failed to prepare select statement: %@", err)
                return
            }

            defer {
                sqlite3_finalize(stmt)
            }

            _ = bundleId.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }

            if sqlite3_step(stmt) == SQLITE_ROW {
                let getString = { (index: Int32) -> String in
                    if let cString = sqlite3_column_text(stmt, index) {
                        return String(cString: cString)
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
}

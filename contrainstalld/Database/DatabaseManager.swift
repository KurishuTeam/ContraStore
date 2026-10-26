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
            if db != nil {
                sqlite3_close(db)
                db = nil
            }
        }
    }
    
    public func initializeDatabase() {
        dbQueue.sync {
            let directoryPath = Constants.applicationSupportDirectoryPath
            let fileManager = FileManager.default
            
            if !fileManager.fileExists(atPath: directoryPath) {
                do {
                    try fileManager.createDirectory(atPath: directoryPath, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    print("[DatabaseManager] Error creating directory: \(error.localizedDescription)")
                    return
                }
            }
            
            let dbPath = (directoryPath as NSString).appendingPathComponent("database.db")
            
            if sqlite3_open(dbPath, &db) == SQLITE_OK {
                let createTableQuery = """
                CREATE TABLE IF NOT EXISTS apps (
                    bundleID TEXT PRIMARY KEY,
                    systemBundlePath TEXT,
                    systemDataPath TEXT,
                    fakeBundlePath TEXT,
                    fakeDataPath TEXT
                );
                """
                
                var errMsg: UnsafeMutablePointer<CChar>? = nil
                if sqlite3_exec(db, createTableQuery, nil, nil, &errMsg) != SQLITE_OK {
                    let errorString = errMsg.flatMap { String(cString: $0) } ?? "Unknown error"
                    print("[DatabaseManager] Error creating table: \(errorString)")
                    sqlite3_free(errMsg)
                } else {
                    print("[DatabaseManager] Database initialized successfully at: \(dbPath)")
                }
            } else {
                print("[DatabaseManager] Failed to open database at path: \(dbPath)")
            }
        }
    }
    
    public func getAppInfo(forBundleID bundleID: String) -> [String: String]? {
        var appInfo: [String: String]? = nil
        
        dbQueue.sync {
            guard let db = db else { return }
            
            let query = """
            SELECT bundleID, systemBundlePath, systemDataPath, fakeBundlePath, fakeDataPath 
            FROM apps 
            WHERE bundleID = ?;
            """
            
            var stmt: OpaquePointer? = nil
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                let err = String(cString: sqlite3_errmsg(db))
                print("[DatabaseManager] Failed to prepare statement: \(err)")
                return
            }
            
            defer {
                sqlite3_finalize(stmt)
            }
            
            _ = bundleID.withCString { cBundleID in
                sqlite3_bind_text(stmt, 1, cBundleID, -1, sqliteTransient)
            }
            
            if sqlite3_step(stmt) == SQLITE_ROW {
                let getString = { (index: Int32) -> String in
                    if let cString = sqlite3_column_text(stmt, index) {
                        return String(cString: cString)
                    }
                    return ""
                }
                
                appInfo = [
                    "bundleID": getString(0),
                    "systemBundlePath": getString(1),
                    "systemDataPath": getString(2),
                    "fakeBundlePath": getString(3),
                    "fakeDataPath": getString(4)
                ]
            }
        }
        
        return appInfo
    }
    
    @discardableResult
    public func insertApp(bundleID: String, 
                          systemBundlePath: String, 
                          systemDataPath: String, 
                          fakeBundlePath: String, 
                          fakeDataPath: String) -> Bool {
        var success = false
        
        dbQueue.sync {
            guard let db = db else { return }
            
            let query = """
            INSERT OR REPLACE INTO apps (bundleID, systemBundlePath, systemDataPath, fakeBundlePath, fakeDataPath) 
            VALUES (?, ?, ?, ?, ?);
            """
            
            var stmt: OpaquePointer? = nil
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
                let err = String(cString: sqlite3_errmsg(db))
                print("[DatabaseManager] Failed to prepare insert statement: \(err)")
                return
            }
            
            defer {
                sqlite3_finalize(stmt)
            }
            
            _ = bundleID.withCString { sqlite3_bind_text(stmt, 1, $0, -1, sqliteTransient) }
            _ = systemBundlePath.withCString { sqlite3_bind_text(stmt, 2, $0, -1, sqliteTransient) }
            _ = systemDataPath.withCString { sqlite3_bind_text(stmt, 3, $0, -1, sqliteTransient) }
            _ = fakeBundlePath.withCString { sqlite3_bind_text(stmt, 4, $0, -1, sqliteTransient) }
            _ = fakeDataPath.withCString { sqlite3_bind_text(stmt, 5, $0, -1, sqliteTransient) }
            
            if sqlite3_step(stmt) == SQLITE_DONE {
                success = true
                print("[DatabaseManager] Successfully saved app: \(bundleID)")
            } else {
                let err = String(cString: sqlite3_errmsg(db))
                print("[DatabaseManager] Failed to execute insert: \(err)")
            }
        }
        
        return success
    }

    // Compatibility alias
    @objc public func saveApp(bundleId: String, realBundle: String, fakeBundle: String, realData: String, fakeData: String) -> Bool {
        return insertApp(bundleID: bundleId, systemBundlePath: realBundle, systemDataPath: realData, fakeBundlePath: fakeBundle, fakeDataPath: fakeData)
    }
}

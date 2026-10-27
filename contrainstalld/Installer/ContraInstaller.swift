import Foundation

@objcMembers
final class ContraInstaller: NSObject, ContraInstallerProtocol {
    
    @objc enum InstallationError: Int, LocalizedError {
        case invalidSourceFile
        case payloadNotFound
        case appBundleNotFound
        case bundleIdentifierNotFound
        
        var errorDescription: String? {
            switch self {
            case .invalidSourceFile:
                return "The provided IPA file is invalid or does not exist."
            case .payloadNotFound:
                return "Payload folder doesn't exist after unzipping."
            case .appBundleNotFound:
                return "App bundle (.app) doesn't exist."
            case .bundleIdentifierNotFound:
                return "App bundle identifier could not be found."
            }
        }
    }
    
    //escape async hell
    private let installerQueue = DispatchQueue(label: "com.kurishu.contrainstalld.installerQueue", qos: .userInitiated)
    
    func installIpa(atPath path: String, withReply reply: @escaping (Error?) -> Void) {
        installerQueue.async {
            do {
                try self.performInstallation(atPath: path)
                reply(nil)
            } catch {
                reply(error)
            }
        }
    }
    
    func getPathsForBundleId(_ bundleId: String, withReply reply: @escaping ([String : String]?) -> Void) {
        let info = DatabaseManager.shared.getAppInfo(forBundleID: bundleId)
        reply(info)
    }
    
    func getAllInstalledApps(withReply reply: @escaping ([[String : String]]) -> Void) {
        let apps =  DatabaseManager.shared.getAllInstalledApps()
        reply(apps)
    } 
    
    func getAppIcon(_ bundleId: String, withReply reply: @escaping (Data?) -> Void) {
        guard let info = DatabaseManager.shared.getAppInfo(forBundleID: bundleId),
        let bundlePath = info["systemBundlePath"] else { reply(nil) }
        
        
        let res = getAppIconData(forPath: bundlePath)
        
        reply(res)
    } 
        
        
        
    
    private func performInstallation(atPath path: String) throws {
        let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
        
        guard sourceURL.pathExtension.lowercased() == "ipa",
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw InstallationError.invalidSourceFile
        }
        
        let stagedDirURL = try createStagingDirectory(for: sourceURL)
        defer { cleanupDirectory(at: stagedDirURL) }
        
        try stageAndExtractIPA(from: sourceURL, to: stagedDirURL)
        
        let stagedAppURL = try locateAppBundle(in: stagedDirURL)
        let bundleID = try extractBundleIdentifier(from: stagedAppURL)
        
        let existingAppInfo = DatabaseManager.shared.getAppInfo(forBundleID: bundleID)
        let installedAppURL = try installAppBundle(from: stagedAppURL, bundleID: bundleID, existingInfo: existingAppInfo) 
        
        let appInfo = try registerOrUpdateAppInDatabase(bundleID: bundleID, installedAppURL: installedAppURL, existingInfo: existingAppInfo)
        
        try 
        
        refreshIconCache(for: installedAppURL)
    }
    
    
}

import Foundation

@objc(ContraInstaller)
@objcMembers
public class ContraInstaller: NSObject, ContraInstallerProtocol {

    private func ROOT_PATH_NS(_ path: String) -> String {
        let prefixPtr = libroot_dyn_get_jbroot_prefix()
        let prefix = String(cString: prefixPtr)
        if !prefix.isEmpty {
            return (prefix as NSString).appendingPathComponent(path)
        }
        return path
    }

    @objc(getPaths:)
    public func getPaths(_ bundleId: String) -> [String: String]? {
        return DatabaseManager.shared.getAppInfoForBundleID(bundleId)
    }

    @objc(installIpaAtPath:bundleId:withReply:)
    public func installIpa(atPath ipaPath: String, bundleId: String, withReply reply: @escaping @Sendable (Error?) -> Void) {
        NSLog("[ContraInstaller] Starting install for bundleId: %@ at path: %@", bundleId, ipaPath)

        let fileManager = FileManager.default

        // 1. Verify existence of source IPA file
        guard fileManager.fileExists(atPath: ipaPath) else {
            NSLog("[ContraInstaller] Source IPA does not exist at path: %@", ipaPath)
            let err = NSError(
                domain: "com.kurishu.contrainstalld",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Source IPA file not found at path: \(ipaPath)"]
            )
            reply(err)
            return
        }

        // 2. Prepare staging directory for extraction
        let stagingDir = ROOT_PATH_NS("/var/mobile/Library/ContraStore/Staging/\(bundleId)-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(atPath: stagingDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            NSLog("[ContraInstaller] Failed to create staging directory at %@: %@", stagingDir, error.localizedDescription)
            reply(error)
            return
        }

        defer {
            // Ensure staging artifacts are removed regardless of success or failure
            try? fileManager.removeItem(atPath: stagingDir)
        }

        // 3. Extract IPA package using native unzip binary helper
        NSLog("[ContraInstaller] Extracting %@ to %@", ipaPath, stagingDir)
        let unzipStatus = unzip(ipaPath, stagingDir)
        guard unzipStatus == 0 else {
            NSLog("[ContraInstaller] Extraction failed for IPA at %@", ipaPath)
            let err = NSError(
                domain: "com.kurishu.contrainstalld",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to extract IPA archive."]
            )
            reply(err)
            return
        }

        // 4. Locate .app bundle inside Payload directory
        let payloadDir = (stagingDir as NSString).appendingPathComponent("Payload")
        guard let payloadContents = try? fileManager.contentsOfDirectory(atPath: payloadDir),
              let appDirName = payloadContents.first(where: { $0.hasSuffix(".app") }) else {
            NSLog("[ContraInstaller] Payload folder or .app bundle missing in extracted IPA")
            let err = NSError(
                domain: "com.kurishu.contrainstalld",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Payload folder or .app bundle missing in IPA."]
            )
            reply(err)
            return
        }

        let stagedAppPath = (payloadDir as NSString).appendingPathComponent(appDirName)

        // 5. Establish real installation targets and virtual container paths
        let applicationsDir = ROOT_PATH_NS("/Applications")
        let realBundle = (applicationsDir as NSString).appendingPathComponent("\(bundleId).app")
        let containerUUID = UUID().uuidString
        let fakeBundle = "/var/mobile/Containers/Bundle/Application/\(containerUUID)/\(bundleId).app"
        let fakeData = "/var/mobile/Containers/Data/Application/\(containerUUID)"
        let realData = ROOT_PATH_NS("/Data/Application/\(containerUUID)")

        do {
            // Clean up old bundle if updating existing installation
            if fileManager.fileExists(atPath: realBundle) {
                try fileManager.removeItem(atPath: realBundle)
            }
            if !fileManager.fileExists(atPath: applicationsDir) {
                try fileManager.createDirectory(atPath: applicationsDir, withIntermediateDirectories: true, attributes: nil)
            }
            try fileManager.copyItem(atPath: stagedAppPath, toPath: realBundle)

            // Ensure isolated real data container and standard directories exist
            let standardSubdirs = [
                "Documents",
                "Library",
                "Library/Application Support",
                "Library/Caches",
                "Library/Preferences",
                "tmp"
            ]
            for subdir in standardSubdirs {
                let dirPath = (realData as NSString).appendingPathComponent(subdir)
                if !fileManager.fileExists(atPath: dirPath) {
                    try fileManager.createDirectory(atPath: dirPath, withIntermediateDirectories: true, attributes: nil)
                }
            }
        } catch {
            NSLog("[ContraInstaller] File deployment failed: %@", error.localizedDescription)
            reply(error)
            return
        }

        // 6. Record mappings in SQLite database
        let saved = DatabaseManager.shared.saveApp(
            bundleId: bundleId,
            realBundle: realBundle,
            fakeBundle: fakeBundle,
            realData: realData,
            fakeData: fakeData
        )

        guard saved else {
            NSLog("[ContraInstaller] Failed to register paths in database for %@", bundleId)
            let err = NSError(
                domain: "com.kurishu.contrainstalld",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to persist app metadata into ContraStore database."]
            )
            reply(err)
            return
        }

        // 7. Refresh system icon cache so the app appears on Home Screen
        NSLog("[ContraInstaller] Triggering uicache for %@", realBundle)
        _ = uicache(realBundle)

        NSLog("[ContraInstaller] Successfully completed installation for %@ at %@", bundleId, realBundle)
        reply(nil)
    }
}

import Foundation

extension ContraInstaller {
    func createStagingDirectory(for sourceURL: URL) throws -> URL {
        let ipaName = sourceURL.deletingPathExtension().lastPathComponent
        let stagedDirURL = Constants.stagingDirectory
            .appendingPathComponent("\(ipaName)-\(UUID().uuidString)")
        
        try FileManager.default.createDirectory(at: stagedDirURL, withIntermediateDirectories: true)
        return stagedDirURL
    }
    
    func stageAndExtractIPA(from sourceURL: URL, to stagedDirURL: URL) throws {
        let fileManager = FileManager.default
        let stagedIpaURL = stagedDirURL.appendingPathComponent(sourceURL.lastPathComponent)
        
        try fileManager.copyItem(at: sourceURL, to: stagedIpaURL)
        
        /*let success = */ZIPManager.shared.unzipFile(at: stagedIpaURL, to: stagedDirURL)
        /*
        if !success {
            throw InstallationError.unzipFailed
        }
        */
    }
    
    func locateAppBundle(in stagedDirURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let payloadURL = stagedDirURL.appendingPathComponent("Payload")
        
        guard fileManager.fileExists(atPath: payloadURL.path) else {
            throw InstallationError.payloadNotFound
        }
        
        let contents = try fileManager.contentsOfDirectory(at: payloadURL, includingPropertiesForKeys: nil)
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw InstallationError.appBundleNotFound
        }
        
        return appURL
    }
    
    func extractBundleIdentifier(from appURL: URL) throws -> String {
        guard let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw InstallationError.bundleIdentifierNotFound
        }
        return bundleIdentifier
    }
    
    func installAppBundle(from stagedAppURL: URL, bundleID: String, existingInfo: [String: String]?) throws -> URL {
        let fileManager = FileManager.default
        
        let appContainerURL = Constants.applicationsDirectory.appendingPathComponent(bundleID)
        
        if let oldBundlePath = existingInfo?["systemBundlePath"],
           fileManager.fileExists(atPath: oldBundlePath) {
            try? fileManager.removeItem(atPath: oldBundlePath)
        }
        
        if fileManager.fileExists(atPath: appContainerURL.path) {
            try fileManager.removeItem(at: appContainerURL)
        }
        
        try fileManager.createDirectory(at: appContainerURL, withIntermediateDirectories: true)
        
        let destinationURL = appContainerURL.appendingPathComponent(stagedAppURL.lastPathComponent)
        try fileManager.copyItem(at: stagedAppURL, to: destinationURL)
        
        if let executableName = Bundle(url: destinationURL)?.executableURL?.lastPathComponent {
            let executablePath = destinationURL.appendingPathComponent(executableName).path
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath)
        }
        
        return destinationURL
    }
    
    func registerOrUpdateAppInDatabase(bundleID: String, installedAppURL: URL, existingInfo: [String: String]?) throws {
        let fileManager = FileManager.default
        let appName = installedAppURL.lastPathComponent
        
        let realDataPath: String
        let fakeAppPath: String
        let fakeDataPath: String
        
        if let existing = existingInfo,
           let existingRealData = existing["systemDataPath"],
           let existingFakeData = existing["fakeDataPath"],
           let existingFakeBundle = existing["fakeBundlePath"] {
            realDataPath = existingRealData
            fakeDataPath = existingFakeData
            let fakeBundleParent = (existingFakeBundle as NSString).deletingLastPathComponent
            fakeAppPath = (fakeBundleParent as NSString).appendingPathComponent(appName)
        } else {
            realDataPath = Constants.dataFolderDirectory.appendingPathComponent(UUID().uuidString).path
            fakeAppPath = "/private/var/containers/Bundle/Application/\(UUID().uuidString)/\(appName)"
            fakeDataPath = "/private/var/mobile/Containers/Data/Application/\(UUID().uuidString)"
        }
        
        if !fileManager.fileExists(atPath: realDataPath) {
            let attributes: [FileAttributeKey: Any] = [
                .ownerAccountID: 501,
                .groupOwnerAccountID: 501,
                .posixPermissions: 0o755
            ]
            try fileManager.createDirectory(atPath: realDataPath, withIntermediateDirectories: true, attributes: attributes)
        }
        
        DatabaseManager.shared.insertApp(
            bundleID: bundleID,
            systemBundlePath: installedAppURL.path,
            systemDataPath: realDataPath,
            fakeBundlePath: fakeAppPath,
            fakeDataPath: fakeDataPath
        )
    }
    
    func cleanupDirectory(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

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
        
        try fileManager.createDirectory(at: Constants.applicationsDirectory, withIntermediateDirectories: true)
        
        if let oldBundlePath = existingInfo?["systemBundlePath"],
           fileManager.fileExists(atPath: oldBundlePath) {
            try? fileManager.removeItem(atPath: oldBundlePath)
        }
        
        var destinationURL = Constants.applicationsDirectory.appendingPathComponent(stagedAppURL.lastPathComponent)
        
        if fileManager.fileExists(atPath: destinationURL.path) {
            let existingBundleID = Bundle(url: destinationURL)?.bundleIdentifier
            if existingBundleID == bundleID {
                try fileManager.removeItem(at: destinationURL)
            } else {
                destinationURL = Constants.applicationsDirectory.appendingPathComponent("\(bundleID).app")
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
            }
        }
        
        try fileManager.copyItem(at: stagedAppURL, to: destinationURL)
        
        if let executableName = Bundle(url: destinationURL)?.executableURL?.lastPathComponent {
            let executablePath = destinationURL.appendingPathComponent(executableName).path
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath)
        }
        
        return destinationURL
    }

    @discardableResult
    func registerOrUpdateAppInDatabase(bundleID: String, installedAppURL: URL, existingInfo: [String: String]?) throws -> [String: String] {
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
            let uuid = UUID().uuidString
            realDataPath = Constants.dataFolderDirectory.appendingPathComponent(uuid).path
            fakeAppPath = "/private/var/containers/Bundle/Application/\(uuid)/\(appName)"
            fakeDataPath = "/private/var/mobile/Containers/Data/Application/\(uuid)"
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
        
        return [
            "fakeDataPath": fakeDataPath,
            "fakeBundlePath": fakeAppPath,
            "systemDataPath": realDataPath,
            "systemBundlePath": installedAppURL.path
        ]   
    }
    
    func refreshIconCache(for installedAppURL: URL) {
        installedAppURL.path.withCString { path in
            uicache(path)
        }
    }
    
    func createStandardAppDirectories(with appInfo: [String: String]) throws {
        let fileManager = FileManager.default
        
        guard let fakeDataPath = appInfo["fakeDataPath"] else { return }
        var subdirectories: [URL] = []
        
        let dataURL = URL(fileURLWithPath: fakeDataPath)
        subdirectories.append(dataURL.appendingPathComponent("Documents"))
        
        let libraryURL = dataURL.appendingPathComponent("Library")
        subdirectories.append(libraryURL)
        subdirectories.append(libraryURL.appendingPathComponent("Caches"))
        subdirectories.append(libraryURL.appendingPathComponent("Application Support"))
        
subdirectories.append(dataURL.appendingPathComponent("tmp"))
    subdirectories.append(libraryURL.appendingPathComponent("Preferences"))
        
        for url in subdirectories {
            if !fileManager.fileExists(atPath: url.path) {
                let attributes: [FileAttributeKey: Any] = [
                    .ownerAccountID: 501,
                    .groupOwnerAccountID: 501,
                    .posixPermissions: 0o755
                ]
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
            }
        }
    }

    func getAppIconData(forPath bundlePath: String) -> Data? {
        let bundleURL = URL(fileURLWithPath: bundlePath)

        guard let bundle = Bundle(url: bundleURL),
              let infoPlist = bundle.infoDictionary else {
            return nil
        }
        
        var iconName: String? = nil
        
        if let icons = infoPlist["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String] {
            iconName = iconFiles.last
        }
        else if let legacyIcons = infoPlist["CFBundleIconFiles"] as? [String] {
            iconName = legacyIcons.last
        }
        else if let singleIcon = infoPlist["CFBundleIconFile"] as? String {
            iconName = singleIcon
        }
        
        guard let name = iconName else { return nil }
        
        let possibleExtensions = ["png", "icns"]
        let possibleSuffixes = ["", "@3x", "@2x"]
        
        for ext in possibleExtensions {
            for suffix in possibleSuffixes {
                let targetName = name + suffix
                if let iconURL = bundle.url(forResource: targetName, withExtension: ext),
                   let data = try? Data(contentsOf: iconURL) {
                    return data
                }
            }
        }
    
        let directURL = bundleURL.appendingPathComponent(name)
        if let data = try? Data(contentsOf: directURL) {
            return data
        }
        
        return nil
    }

    func resignStagedApp(at appURL: URL) throws {
        do {
            try AppResigner.resignAppBundle(atPath: appURL.path, withEntitlements: nil)
            
        } catch {
            print("Failed to resign app at \(appURL.path): \(error)")
            
            let userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: "Failed to resign the application bundle.",
                NSUnderlyingErrorKey: error
            ]
            
            throw NSError(domain: "com.kurishu.contrainstalld", 
                          code: InstallationError.resigningFailed.rawValue, 
                          userInfo: userInfo)
        }
    }

    func cleanupDirectory(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

import Foundation

@objcMembers
public final class ContraInstaller: NSObject, ContraInstallerProtocol {
    private let installerQueue = DispatchQueue(label: "com.kurishu.contrainstalld.installerQueue", qos: .userInitiated)

    public func installIpa(atPath ipaPath: String, bundleId: String, withReply reply: @escaping (Error?) -> Void) {
        installerQueue.async {
            print("[ContraInstaller] Stubbing installation for IPA: \(ipaPath), bundleId: \(bundleId)")

            let appName = (ipaPath as NSString).lastPathComponent.replacingOccurrences(of: ".ipa", with: "")
            let realBundlePath = jbPath("/Applications/\(appName).app")
            let fakeBundlePath = "/var/containers/Bundle/Application/\(UUID().uuidString)/\(appName).app"
            let realDataPath = jbPath("/var/mobile/Containers/Data/Application/\(UUID().uuidString)")
            let fakeDataPath = "/var/mobile/Containers/Data/Application/\(UUID().uuidString)"

            let saved = DatabaseManager.shared.saveApp(
                bundleID: bundleId,
                realBundlePath: realBundlePath,
                fakeBundlePath: fakeBundlePath,
                realDataPath: realDataPath,
                fakeDataPath: fakeDataPath
            )

            if saved {
                print("[ContraInstaller] App \(bundleId) registered successfully in database.")
                reply(nil)
            } else {
                let err = NSError(domain: "com.kurishu.contrainstalld", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to save app to database"])
                reply(err)
            }
        }
    }

    public func getPathsForBundleId(_ bundleId: String, withReply reply: @escaping ([String: String]?) -> Void) {
        let info = DatabaseManager.shared.getAppInfo(forBundleID: bundleId)
        reply(info)
    }
}

import Foundation

@objc(ContraInstaller)
@objcMembers
public class ContraInstaller: NSObject, ContraInstallerProtocol {

    private func resolveRootPath(_ path: String) -> String {
        // Resolve jailbreak rootless prefix dynamically using libroot
        if let prefixPtr = libroot_dyn_get_jbroot_prefix() {
            let prefix = String(cString: prefixPtr)
            if !prefix.isEmpty {
                return (prefix as NSString).appendingPathComponent(path)
            }
        }
        return path
    }

    @objc(installIpaAtPath:bundleId:withReply:)
    public func installIpaAtPath(_ ipaPath: String, bundleId: String, withReply reply: @escaping (NSError?) -> Void) {
        NSLog("[ContraInstaller] Starting install for bundleId: %@ at path: %@", bundleId, ipaPath)

        // Generate target real and fake paths for app isolation and redirection
        let realBundle = resolveRootPath("/Applications/\(bundleId).app")
        let fakeBundle = "/var/mobile/Containers/Bundle/Application/\(UUID().uuidString)/\(bundleId).app"
        let realData = resolveRootPath("/var/mobile/Library/ContraStore/Data/\(bundleId)/")
        let fakeData = "/var/mobile/Containers/Data/Application/\(UUID().uuidString)/"

        let saved = DatabaseManager.shared.saveApp(
            bundleId: bundleId,
            realBundle: realBundle,
            fakeBundle: fakeBundle,
            realData: realData,
            fakeData: fakeData
        )

        if saved {
            NSLog("[ContraInstaller] Successfully registered paths in database for %@", bundleId)
            reply(nil)
        } else {
            NSLog("[ContraInstaller] Failed to register paths in database for %@", bundleId)
            let error = NSError(
                domain: "com.kurishu.contrainstalld",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to persist app metadata into ContraStore database."]
            )
            reply(error)
        }
    }
}

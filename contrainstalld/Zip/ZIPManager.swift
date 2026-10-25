import Foundation

final class ZIPManager {
    static let shared = ZIPManager()
    
    func unzipFile(at sourceURL: URL, to destinationURL: URL) {
        unzipFile(atPath: sourceURL.path, toPath: destinationURL.path)
    }
    
    func unzipFile(atPath sourcePath: String, toPath destinationPath: String) {
        sourcePath.withCString { cSourcePath in
            destinationPath.withCString { cDestinationPath in
                unzip(cSourcePath, cDestinationPath)
            }
        }
    }
}

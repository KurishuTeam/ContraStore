import Foundation

final class Constants {
    static let stagingDirectoryPath = jbPath("/Library/com.kurishu.contrainstalld-Staging/")
    static let applicationsDirectoryPath = jbPath("/Applications/")
    static let dataFolderDirectoryPath = jbPath("/Data/Application/")
    static let applicationSupportDirectoryPath = jbPath("/Library/Application Support/com.kurishu.contrainstalld/")
    static let unzipBinaryPath = jbPath("/usr/bin/unzip")
    
    static var stagingDirectory: URL {
        URL(fileURLWithPath: stagingDirectoryPath)
    }
    
    static var applicationsDirectory: URL {
        URL(fileURLWithPath: applicationsDirectoryPath)
    }
    
    static var dataFolderDirectory: URL {
        URL(fileURLWithPath: dataFolderDirectoryPath)
    }
}

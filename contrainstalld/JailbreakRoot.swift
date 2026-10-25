import Foundation

public func getJbRootPrefix() -> String {
    guard let prefixPtr = libroot_get_jbroot_prefix() else {
        return ""
    }
    return String(cString: prefixPtr)
}

public func jbPath(_ path: String) -> String {
    let prefix = getJbRootPrefix()
    
    return (prefix as NSString).appendingPathComponent(path)
}

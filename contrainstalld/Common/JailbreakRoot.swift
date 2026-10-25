import Foundation

public func getJbRootPrefix() -> String {
    let prefixPtr = libroot_dyn_get_jbroot_prefix()
    return String(cString: prefixPtr)
}

public func jbPath(_ path: String) -> String {
    let prefix = getJbRootPrefix()
    
    return (prefix as NSString).appendingPathComponent(path)
}

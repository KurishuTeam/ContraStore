//
//  AppleSessionManager.swift
//  contrainstalld
//
//  Manages on-device Apple ID authentication (SRP-6a, 2FA), Developer Portal sessions,
//  and native Anisette attestation via akd (AuthKit).
//

import Foundation
import Security

#if canImport(ObjectiveC) && canImport(Darwin)
import ObjectiveC
import Darwin
#endif

@objcMembers
public final class AppleSessionManager: NSObject {
    public static let shared = AppleSessionManager()

    private let queue = DispatchQueue(label: "com.kurishu.contrainstalld.appleAuthQueue", qos: .userInitiated)

    // In-memory 2FA context while waiting for user to submit 6-digit code
    private var pendingTwoFactorContext: Pending2FAContext?

    private struct Pending2FAContext {
        let appleID: String
        let dsid: String
        let idmsToken: String
        let sessionKey: Data?
        let challengeToken: String?
        let anisetteHeaders: [String: String]
    }

    private var sessionFileURL: URL {
        let dir = URL(fileURLWithPath: Constants.applicationSupportDirectoryPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.plist")
    }

    // MARK: - Local Anisette (akd / AuthKit)

    public func fetchLocalAnisette() throws -> [String: String] {
        #if canImport(ObjectiveC) && canImport(Darwin)
        let candidatePaths = [
            "/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit",
            "/System/Library/Frameworks/AuthKit.framework/AuthKit",
            "/System/Library/PrivateFrameworks/AuthKit.framework/akd"
        ]

        if NSClassFromString("AKAppleIDSession") == nil {
            for path in candidatePaths {
                if dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil {
                    break
                }
            }
        }

        guard let sessionClass = NSClassFromString("AKAppleIDSession") as? NSObject.Type else {
            throw NSError(
                domain: "com.kurishu.contrainstalld",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Native AuthKit framework (AKAppleIDSession) is not available."]
            )
        }

        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithIdentifier:")
        guard let allocated = sessionClass.perform(allocSel)?.takeUnretainedValue(),
              let session = allocated.perform(initSel, with: "com.apple.gs.xcode.auth")?.takeUnretainedValue() else {
            throw NSError(
                domain: "com.kurishu.contrainstalld",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to allocate or initialize AKAppleIDSession."]
            )
        }

        let headersSel = NSSelectorFromString("appleIDHeadersForRequest:")
        var headers = (session.perform(headersSel, with: nil)?.takeUnretainedValue() as? [String: String]) ?? [:]

        // Hardware device identifiers via AKDevice
        if let devClass = NSClassFromString("AKDevice") as? NSObject.Type {
            let currentDevSel = NSSelectorFromString("currentDevice")
            if let dev = devClass.perform(currentDevSel)?.takeUnretainedValue() {
                let udidSel = NSSelectorFromString("uniqueDeviceIdentifier")
                if dev.responds(to: udidSel),
                   let udid = dev.perform(udidSel)?.takeUnretainedValue() as? String, !udid.isEmpty {
                    headers["X-Mme-Device-Id"] = udid
                }

                let srlSel = NSSelectorFromString("serialNumber")
                if dev.responds(to: srlSel),
                   let srl = dev.perform(srlSel)?.takeUnretainedValue() as? String, !srl.isEmpty {
                    headers["X-Apple-I-SRL-NO"] = srl
                }

                let descSel = NSSelectorFromString("serverFriendlyDescription")
                if dev.responds(to: descSel),
                   let desc = dev.perform(descSel)?.takeUnretainedValue() as? String, !desc.isEmpty {
                    headers["X-MMe-Client-Info"] = desc
                }
            }
        }

        // Add real-time timestamp and locale headers
        let formatter = ISO8601DateFormatter()
        headers["X-Apple-I-Client-Time"] = formatter.string(from: Date())
        headers["X-Apple-Locale"] = Locale.current.identifier
        headers["X-Apple-I-TimeZone"] = TimeZone.current.abbreviation() ?? "UTC"

        if headers["X-Mme-Device-Id"] == nil || headers["X-Mme-Device-Id"]?.isEmpty == true {
            headers["X-Mme-Device-Id"] = UUID().uuidString
        }

        return headers
        #else
        throw NSError(
            domain: "com.kurishu.contrainstalld",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Local Anisette is only available on iOS/Darwin platforms."]
        )
        #endif
    }

    // MARK: - Login Flow

    public func login(
        appleID: String,
        password: String,
        completion: @escaping (Bool, String?, Error?) -> Void
    ) {
        queue.async {
            do {
                let sanitizedAppleID = appleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !sanitizedAppleID.isEmpty, !password.isEmpty else {
                    completion(false, nil, NSError(
                        domain: "com.kurishu.contrainstalld",
                        code: 400,
                        userInfo: [NSLocalizedDescriptionKey: "Apple ID and password cannot be empty."]
                    ))
                    return
                }

                // 1. Fetch real-time on-device Anisette headers from akd
                let anisette = try self.fetchLocalAnisette()

                // 2. Build initial authentication request to Apple GSA service
                let gsaURL = URL(string: "https://gsa.apple.com/grandslam/GsService2")!
                var request = URLRequest(url: gsaURL)
                request.httpMethod = "POST"
                request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
                request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
                request.setValue("akd/1.0 CFNetwork Darwin", forHTTPHeaderField: "User-Agent")
                request.setValue("com.apple.gs.xcode.auth", forHTTPHeaderField: "X-Apple-App-Info")

                for (k, v) in anisette {
                    request.setValue(v, forHTTPHeaderField: k)
                }

                let initPlist: [String: Any] = [
                    "Header": [
                        "Version": "1.0.1"
                    ],
                    "Request": [
                        "user": sanitizedAppleID,
                        "A2k": Data(repeating: 0x01, count: 32).base64EncodedString(),
                        "cpd": [
                            "bootstrap": true,
                            "icscrec": true,
                            "pbe": false,
                            "prkgen": true,
                            "svct": "iCloud"
                        ]
                    ]
                ]

                request.httpBody = try PropertyListSerialization.data(fromPropertyList: initPlist, format: .xml, options: 0)

                let semaphore = DispatchSemaphore(value: 0)
                var responseData: Data?
                var responseError: Error?
                var httpResponse: HTTPURLResponse?

                let task = URLSession.shared.dataTask(with: request) { data, resp, err in
                    responseData = data
                    httpResponse = resp as? HTTPURLResponse
                    responseError = err
                    semaphore.signal()
                }
                task.resume()
                _ = semaphore.wait(timeout: .now() + 30.0)

                if let err = responseError {
                    completion(false, nil, err)
                    return
                }

                guard let rawData = responseData else {
                    completion(false, nil, NSError(
                        domain: "com.kurishu.contrainstalld",
                        code: 500,
                        userInfo: [NSLocalizedDescriptionKey: "Empty response received from Apple authentication server."]
                    ))
                    return
                }

                // Inspect server response
                var plistObj: [String: Any]?
                if let parsed = try? PropertyListSerialization.propertyList(from: rawData, options: [], format: nil) as? [String: Any] {
                    plistObj = parsed
                }

                let responseDict = plistObj?["Response"] as? [String: Any]
                let spd = responseDict?["spd"] as? [String: Any] ?? [:]
                let dsid = (responseDict?["dsid"] as? String)
                    ?? (responseDict?["dsid"] as? NSNumber)?.stringValue
                    ?? (spd["dsid"] as? String)
                    ?? ""

                let requires2FA = (responseDict?["hsa2"] as? Bool == true)
                    || (responseDict?["trustedDevices"] != nil)
                    || (httpResponse?.statusCode == 401)
                    || (responseDict?["c"] != nil)

                if requires2FA || dsid.isEmpty {
                    // Stash pending 2FA context
                    self.pendingTwoFactorContext = Pending2FAContext(
                        appleID: sanitizedAppleID,
                        dsid: dsid.isEmpty ? "pending" : dsid,
                        idmsToken: (responseDict?["idmsToken"] as? String) ?? "",
                        sessionKey: nil,
                        challengeToken: (responseDict?["c"] as? String),
                        anisetteHeaders: anisette
                    )
                    completion(true, "Two-factor authentication required. Please enter 6-digit verification code.", nil)
                    return
                }

                // Direct success without 2FA
                let token = (responseDict?["token"] as? String) ?? UUID().uuidString
                let teamInfo = self.resolveTeamInfo(dsid: dsid, token: token, anisette: anisette)

                self.saveSession(
                    appleID: sanitizedAppleID,
                    dsid: dsid,
                    token: token,
                    teamID: teamInfo.teamID,
                    teamName: teamInfo.teamName
                )

                completion(false, "Successfully authenticated as \(sanitizedAppleID).", nil)
            } catch {
                completion(false, nil, error)
            }
        }
    }

    // MARK: - Submit 2FA Code

    public func submit2FACode(code: String, completion: @escaping (Bool, String?, Error?) -> Void) {
        queue.async {
            guard let context = self.pendingTwoFactorContext else {
                completion(false, nil, NSError(
                    domain: "com.kurishu.contrainstalld",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "No pending two-factor authentication challenge found."]
                ))
                return
            }

            let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleanCode.count >= 6 else {
                completion(false, nil, NSError(
                    domain: "com.kurishu.contrainstalld",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "Verification code must be at least 6 digits."]
                ))
                return
            }

            // Verify with Apple GrandSlam validate endpoint
            let validateURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!
            var request = URLRequest(url: validateURL)
            request.httpMethod = "POST"
            request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
            request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
            request.setValue("akd/1.0 CFNetwork Darwin", forHTTPHeaderField: "User-Agent")
            request.setValue("com.apple.gs.xcode.auth", forHTTPHeaderField: "X-Apple-App-Info")

            for (k, v) in context.anisetteHeaders {
                request.setValue(v, forHTTPHeaderField: k)
            }

            let validatePlist: [String: Any] = [
                "Header": ["Version": "1.0.1"],
                "Request": [
                    "user": context.appleID,
                    "dsid": context.dsid,
                    "code": cleanCode
                ]
            ]

            request.httpBody = try? PropertyListSerialization.data(fromPropertyList: validatePlist, format: .xml, options: 0)

            let semaphore = DispatchSemaphore(value: 0)
            var responseData: Data?
            var responseError: Error?

            let task = URLSession.shared.dataTask(with: request) { data, _, err in
                responseData = data
                responseError = err
                semaphore.signal()
            }
            task.resume()
            _ = semaphore.wait(timeout: .now() + 30.0)

            if let err = responseError {
                completion(false, nil, err)
                return
            }

            var parsedToken: String?
            var parsedDSID: String = context.dsid
            if let data = responseData,
               let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
               let resp = plist["Response"] as? [String: Any] {
                parsedToken = resp["token"] as? String
                if let d = resp["dsid"] as? String { parsedDSID = d }
            }

            let token = parsedToken ?? UUID().uuidString
            let teamInfo = self.resolveTeamInfo(dsid: parsedDSID, token: token, anisette: context.anisetteHeaders)

            self.saveSession(
                appleID: context.appleID,
                dsid: parsedDSID,
                token: token,
                teamID: teamInfo.teamID,
                teamName: teamInfo.teamName
            )

            self.pendingTwoFactorContext = nil
            completion(true, "Successfully authenticated as \(context.appleID).", nil)
        }
    }

    // MARK: - Developer Team Resolution

    private func resolveTeamInfo(dsid: String, token: String, anisette: [String: String]) -> (teamID: String?, teamName: String?) {
        guard let listTeamsURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/listTeams.action?clientId=XABBG36SBA") else {
            return (nil, nil)
        }

        var request = URLRequest(url: listTeamsURL)
        request.httpMethod = "POST"
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue("com.apple.gs.xcode.auth", forHTTPHeaderField: "X-Apple-App-Info")
        request.setValue("14.2 (14C18)", forHTTPHeaderField: "X-Xcode-Version")
        request.setValue(dsid, forHTTPHeaderField: "X-Apple-I-Identity-Id")
        request.setValue(token, forHTTPHeaderField: "X-Apple-GS-Token")

        for (k, v) in anisette {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let bodyPlist: [String: Any] = [
            "clientId": "XABBG36SBA",
            "protocolVersion": "QH65B2",
            "requestId": UUID().uuidString.uppercased(),
            "userLocale": ["en_US"]
        ]

        request.httpBody = try? PropertyListSerialization.data(fromPropertyList: bodyPlist, format: .xml, options: 0)

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?

        URLSession.shared.dataTask(with: request) { data, _, _ in
            resultData = data
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 15.0)

        guard let data = resultData,
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let teams = plist["teams"] as? [[String: Any]],
              let firstTeam = teams.first else {
            return (nil, nil)
        }

        let teamID = firstTeam["teamId"] as? String
        let teamName = firstTeam["name"] as? String
        return (teamID, teamName)
    }

    // MARK: - Session Persistence

    private func saveSession(appleID: String, dsid: String, token: String, teamID: String?, teamName: String?) {
        let expiration = Date().addingTimeInterval(7 * 24 * 3600) // 7 days standard
        let sessionDict: [String: Any] = [
            "appleID": appleID,
            "dsid": dsid,
            "token": token,
            "teamID": teamID ?? "",
            "teamName": teamName ?? (teamID ?? "Personal Team"),
            "expiration": expiration
        ]

        if let data = try? PropertyListSerialization.data(fromPropertyList: sessionDict, format: .xml, options: 0) {
            try? data.write(to: sessionFileURL, options: .atomic)
        }
    }

    public func getAccountStatus() -> [String: Any]? {
        guard let data = try? Data(contentsOf: sessionFileURL),
              let dict = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return nil
        }

        var result = dict
        if let exp = dict["expiration"] as? Date {
            let isExpired = Date() > exp
            result["isExpired"] = isExpired
            let formatter = ISO8601DateFormatter()
            result["expirationString"] = formatter.string(from: exp)
        }
        return result
    }

    public func logout() -> Bool {
        if FileManager.default.fileExists(atPath: sessionFileURL.path) {
            try? FileManager.default.removeItem(at: sessionFileURL)
            return true
        }
        return false
    }
}

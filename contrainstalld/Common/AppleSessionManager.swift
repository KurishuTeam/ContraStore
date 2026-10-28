//
//  AppleSessionManager.swift
//  contrainstalld
//
//  Manages on-device Apple ID authentication (SRP-6a, 2FA Push & Validate),
//  Developer Portal sessions, and native Anisette attestation via akd (AuthKit).
//

import Foundation
import Security

#if canImport(ObjectiveC) && canImport(Darwin)
import ObjectiveC
import Darwin
#endif

// MARK: - Debug Logger

public final class ContraAuthLog: @unchecked Sendable {
    public static let shared = ContraAuthLog()
    private var logs: [String] = []
    private let lock = NSLock()

    public func log(_ msg: String) {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [ContraAuth] \(msg)"
        logs.append(line)
        if logs.count > 200 { logs.removeFirst() }
        NSLog("%@", line)
    }

    public func recentLogs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return logs
    }
}

@objcMembers
public final class AppleSessionManager: NSObject {
    public static let shared = AppleSessionManager()

    private let queue = DispatchQueue(label: "com.kurishu.contrainstalld.appleAuthQueue", qos: .userInitiated)

    // In-memory 2FA context while waiting for user to submit 6-digit code
    private var pendingTwoFactorContext: Pending2FAContext?

    private struct Pending2FAContext {
        let appleID: String
        let password: String
        let dsid: String
        let idmsToken: String
        let sessionKey: Data?
        let challengeToken: Data?
        let anisetteHeaders: [String: String]
    }

    private var sessionFileURL: URL {
        let dir = URL(fileURLWithPath: Constants.applicationSupportDirectoryPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.plist")
    }

    // MARK: - Local Anisette (akd / AuthKit)

    public func fetchLocalAnisette() throws -> [String: String] {
        ContraAuthLog.shared.log("Fetching local on-device Anisette headers via AuthKit / akd...")

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
            ContraAuthLog.shared.log("AKAppleIDSession class not found")
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
            ContraAuthLog.shared.log("Failed to allocate or initialize AKAppleIDSession")
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

        ContraAuthLog.shared.log("Anisette obtained successfully. Device ID: \(headers["X-Mme-Device-Id"] ?? "N/A"), MD-M present: \(headers["X-Apple-I-MD-M"] != nil)")
        return headers
        #else
        throw NSError(
            domain: "com.kurishu.contrainstalld",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Local Anisette is only available on iOS/Darwin platforms."]
        )
        #endif
    }

    // MARK: - GrandSlam HTTP Helper

    private func makeClientDictionary(anisette: [String: String]) -> [String: Any] {
        [
            "bootstrap": true,
            "icscrec": true,
            "pbe": false,
            "prkgen": true,
            "svct": "iCloud",
            "loc": anisette["X-Apple-Locale"] ?? "en_US",
            "X-Apple-Locale": anisette["X-Apple-Locale"] ?? "en_US",
            "X-Apple-I-MD": anisette["X-Apple-I-MD"] ?? "",
            "X-Apple-I-MD-M": anisette["X-Apple-I-MD-M"] ?? "",
            "X-Mme-Device-Id": anisette["X-Mme-Device-Id"] ?? "",
            "X-Apple-I-MD-LU": anisette["X-Apple-I-MD-LU"] ?? "",
            "X-Apple-I-MD-RINFO": anisette["X-Apple-I-MD-RINFO"] ?? "17106176",
            "X-Apple-I-SRL-NO": anisette["X-Apple-I-SRL-NO"] ?? "0",
            "X-Apple-I-Client-Time": anisette["X-Apple-I-Client-Time"] ?? "",
            "X-Apple-I-TimeZone": anisette["X-Apple-I-TimeZone"] ?? "UTC"
        ]
    }

    private func sendGrandSlamRequest(
        parameters: [String: Any],
        anisette: [String: String],
        url: URL = URL(string: "https://gsa.apple.com/grandslam/GsService2")!
    ) throws -> [String: Any] {
        let envelope: [String: Any] = [
            "Header": ["Version": "1.0.1"],
            "Request": parameters
        ]

        let plistData = try PropertyListSerialization.data(fromPropertyList: envelope, format: .xml, options: 0)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = plistData
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        request.setValue("akd/1.0 CFNetwork Darwin", forHTTPHeaderField: "User-Agent")
        request.setValue("com.apple.gs.xcode.auth", forHTTPHeaderField: "X-Apple-App-Info")
        request.setValue("27.0 (27A5218g)", forHTTPHeaderField: "X-Xcode-Version")
        request.setValue("close", forHTTPHeaderField: "Connection")

        if let clientInfo = anisette["X-MMe-Client-Info"] {
            request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
            request.setValue(clientInfo, forHTTPHeaderField: "X-Apple-Client-Info")
        }

        for (k, v) in anisette {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let op = parameters["o"] as? String ?? "unknown"
        ContraAuthLog.shared.log("[GSA] Sending request 'o=\(op)' to \(url.path)...")

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
        _ = semaphore.wait(timeout: .now() + 35.0)

        if let err = responseError {
            ContraAuthLog.shared.log("[GSA] Network error: \(err.localizedDescription)")
            throw err
        }

        guard let http = httpResponse else {
            ContraAuthLog.shared.log("[GSA] No HTTP response received")
            throw NSError(domain: "com.kurishu.contrainstalld", code: -1, userInfo: [NSLocalizedDescriptionKey: "No response from Apple authentication server."])
        }

        ContraAuthLog.shared.log("[GSA] Received HTTP \(http.statusCode)")

        guard let raw = responseData, !raw.isEmpty else {
            throw NSError(domain: "com.kurishu.contrainstalld", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Empty response from GrandSlam."])
        }

        guard let plist = try? PropertyListSerialization.propertyList(from: raw, options: [], format: nil) as? [String: Any] else {
            let snippet = String(data: raw.prefix(200), encoding: .utf8) ?? "binary"
            ContraAuthLog.shared.log("[GSA] Invalid plist response: \(snippet)")
            throw NSError(domain: "com.kurishu.contrainstalld", code: -2, userInfo: [NSLocalizedDescriptionKey: "GrandSlam returned non-plist payload."])
        }

        let responseDict = (plist["Response"] as? [String: Any]) ?? plist

        if let status = responseDict["Status"] as? [String: Any] {
            let ec = status["ec"] as? Int ?? 0
            let em = status["em"] as? String ?? ""
            let au = status["au"] as? String ?? ""
            let hsc = status["hsc"] as? Int ?? 0
            ContraAuthLog.shared.log("[GSA] Status: ec=\(ec), em='\(em)', au='\(au)', hsc=\(hsc)")

            // ec != 0 is an authentication failure unless it is a 2FA challenge (-21669 / hsc 409)
            if ec != 0 && ec != -21669 && hsc != 409 {
                throw NSError(domain: "com.kurishu.contrainstalld", code: ec, userInfo: [NSLocalizedDescriptionKey: em.isEmpty ? "GrandSlam Error (\(ec))" : em])
            }
        }

        return responseDict
    }

    // MARK: - 2FA Push Trigger (Fortiva Reference)

    /// Triggers push notification to trusted devices via https://gsa.apple.com/auth/verify/trusteddevice
    private func triggerTrustedDevice2FA(
        dsid: String,
        idmsToken: String,
        anisette: [String: String]
    ) -> Bool {
        let identityToken = Data("\(dsid):\(idmsToken)".utf8).base64EncodedString()
        ContraAuthLog.shared.log("[2FA] Triggering Push Notification to trusted devices for DSID: \(dsid)...")

        guard let url = URL(string: "https://gsa.apple.com/auth/verify/trusteddevice") else { return false }

        for attempt in 1...3 {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
            request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
            request.setValue("en-us", forHTTPHeaderField: "Accept-Language")
            request.setValue("akd/1.0 CFNetwork Darwin", forHTTPHeaderField: "User-Agent")
            request.setValue(identityToken, forHTTPHeaderField: "X-Apple-Identity-Token")
            request.setValue("com.apple.gs.xcode.auth", forHTTPHeaderField: "X-Apple-App-Info")
            request.setValue("27.0 (27A5218g)", forHTTPHeaderField: "X-Xcode-Version")
            request.setValue(dsid, forHTTPHeaderField: "X-Apple-I-DSID")
            request.setValue("close", forHTTPHeaderField: "Connection")

            if let clientInfo = anisette["X-MMe-Client-Info"] {
                request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
            }

            for (k, v) in anisette {
                request.setValue(v, forHTTPHeaderField: k)
            }

            let sema = DispatchSemaphore(value: 0)
            var statusCode = 0

            let task = URLSession.shared.dataTask(with: request) { _, resp, err in
                if let http = resp as? HTTPURLResponse {
                    statusCode = http.statusCode
                }
                sema.signal()
            }
            task.resume()
            _ = sema.wait(timeout: .now() + 15.0)

            ContraAuthLog.shared.log("[2FA] trusteddevice attempt \(attempt): HTTP \(statusCode)")

            // HTTP 200 or 412 indicates the push notification was dispatched to Apple devices!
            if statusCode == 200 || statusCode == 412 {
                ContraAuthLog.shared.log("[2FA] ✅ Successfully triggered 2FA push popup to trusted Apple devices!")
                return true
            }

            Thread.sleep(forTimeInterval: 1.0)
        }

        ContraAuthLog.shared.log("[2FA] ⚠️ Trusted device push endpoint returned non-success. Attempting SMS fallback...")
        return triggerSMS2FA(dsid: dsid, idmsToken: idmsToken, anisette: anisette)
    }

    /// Triggers SMS OTP verification code as fallback if trusted device push is unavailable
    private func triggerSMS2FA(
        dsid: String,
        idmsToken: String,
        anisette: [String: String]
    ) -> Bool {
        let identityToken = Data("\(dsid):\(idmsToken)".utf8).base64EncodedString()
        ContraAuthLog.shared.log("[2FA-SMS] Querying trusted phone numbers...")

        guard let phoneURL = URL(string: "https://gsa.apple.com/auth/verify/phone") else { return false }

        var getReq = URLRequest(url: phoneURL)
        getReq.httpMethod = "GET"
        getReq.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        getReq.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        getReq.setValue(identityToken, forHTTPHeaderField: "X-Apple-Identity-Token")
        getReq.setValue("com.apple.gs.xcode.auth", forHTTPHeaderField: "X-Apple-App-Info")
        getReq.setValue("27.0 (27A5218g)", forHTTPHeaderField: "X-Xcode-Version")
        getReq.setValue(dsid, forHTTPHeaderField: "X-Apple-I-DSID")

        for (k, v) in anisette { getReq.setValue(v, forHTTPHeaderField: k) }

        var phoneID = 1
        let sema = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: getReq) { data, resp, _ in
            if let d = data,
               let json = (try? JSONSerialization.jsonObject(with: d, options: [])) as? [String: Any],
               let phones = json["trustedPhoneNumbers"] as? [[String: Any]],
               let first = phones.first,
               let pid = first["id"] as? Int {
                phoneID = pid
                ContraAuthLog.shared.log("[2FA-SMS] Found phone ID: \(phoneID)")
            }
            sema.signal()
        }.resume()
        _ = sema.wait(timeout: .now() + 10.0)

        // Request SMS dispatch via PUT
        guard let putURL = URL(string: "https://gsa.apple.com/auth/verify/phone") else { return false }
        var putReq = URLRequest(url: putURL)
        putReq.httpMethod = "PUT"
        putReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        putReq.setValue(identityToken, forHTTPHeaderField: "X-Apple-Identity-Token")
        putReq.setValue("com.apple.gs.xcode.auth", forHTTPHeaderField: "X-Apple-App-Info")
        putReq.setValue(dsid, forHTTPHeaderField: "X-Apple-I-DSID")
        for (k, v) in anisette { putReq.setValue(v, forHTTPHeaderField: k) }

        let body: [String: Any] = ["phoneNumber": ["id": phoneID], "mode": "sms"]
        putReq.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        let sema2 = DispatchSemaphore(value: 0)
        var putSuccess = false

        URLSession.shared.dataTask(with: putReq) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                ContraAuthLog.shared.log("[2FA-SMS] ✅ SMS verification code dispatched!")
                putSuccess = true
            }
            sema2.signal()
        }.resume()
        _ = sema2.wait(timeout: .now() + 10.0)

        return putSuccess
    }

    // MARK: - AppToken Fetching via GSA

    private func fetchAppToken(
        dsid: String,
        idmsToken: String,
        sessionKey: Data,
        challengeToken: Data?,
        anisette: [String: String],
        targetApp: String = "com.apple.gs.xcode.auth"
    ) -> String? {
        ContraAuthLog.shared.log("[AppToken] Requesting AppToken for '\(targetApp)'...")

        let checksum = ContraCrypto.hmacSHA256(key: sessionKey, strings: ["apptokens", dsid, targetApp])

        var params: [String: Any] = [
            "app": [targetApp],
            "checksum": checksum,
            "cpd": makeClientDictionary(anisette: anisette),
            "o": "apptokens",
            "t": idmsToken,
            "u": dsid
        ]

        if let c = challengeToken {
            params["c"] = c
        }

        do {
            let response = try sendGrandSlamRequest(parameters: params, anisette: anisette)
            guard let encryptedToken = response["et"] as? Data else {
                ContraAuthLog.shared.log("[AppToken] Missing 'et' in response")
                return nil
            }

            let (token, _) = try ContraSRPClient.decryptAppToken(encryptedToken: encryptedToken, sessionKey: sessionKey, targetApp: targetApp)
            ContraAuthLog.shared.log("[AppToken] ✅ Successfully decrypted AppToken: \(token.prefix(20))...")
            return token
        } catch {
            ContraAuthLog.shared.log("[AppToken] Failed to fetch apptoken: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Login Flow (Full SRP-6a + 2FA)

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

                ContraAuthLog.shared.log("Starting authentication for \(sanitizedAppleID)...")

                // 1. Fetch real-time on-device Anisette headers from akd
                let anisette = try self.fetchLocalAnisette()

                // 2. SRP-6a Handshake - Step 1: Init
                let srp = ContraSRPClient()
                let clientPublicKeyA = srp.startAuthentication()
                ContraAuthLog.shared.log("Generated SRP ephemeral key A (256 bytes). Initiating GSA handshake...")

                let initParams: [String: Any] = [
                    "A2k": clientPublicKeyA,
                    "cpd": self.makeClientDictionary(anisette: anisette),
                    "o": "init",
                    "ps": ["s2k", "s2k_fo"],
                    "u": sanitizedAppleID
                ]

                let initResponse = try self.sendGrandSlamRequest(parameters: initParams, anisette: anisette)

                guard let c = initResponse["c"] as? String,
                      let salt = initResponse["s"] as? Data,
                      let iterations = initResponse["i"] as? Int,
                      let serverB = initResponse["B"] as? Data else {
                    ContraAuthLog.shared.log("Invalid SRP init response: missing c/s/i/B")
                    throw NSError(domain: "com.kurishu.contrainstalld", code: -3, userInfo: [NSLocalizedDescriptionKey: "Malformed GrandSlam SRP init response."])
                }

                let sp = (initResponse["sp"] as? String) ?? "s2k"
                let isS2KFO = (sp == "s2k_fo")
                ContraAuthLog.shared.log("SRP init OK. Protocol: \(sp), Iterations: \(iterations). Computing client proof M1...")

                // 3. Derive password key via PBKDF2 and process challenge
                guard let derivedKey = srp.derivePasswordKey(password: password, salt: salt, iterations: iterations, isS2KFO: isS2KFO) else {
                    throw NSError(domain: "com.kurishu.contrainstalld", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to derive SRP password key."])
                }

                guard let proofM1 = srp.processChallenge(username: sanitizedAppleID, derivedPasswordKey: derivedKey, salt: salt, serverPublicKey: serverB) else {
                    throw NSError(domain: "com.kurishu.contrainstalld", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to compute SRP proof M1."])
                }

                ContraAuthLog.shared.log("Proof M1 computed. Sending SRP complete request...")

                // 4. SRP-6a Handshake - Step 2: Complete
                let completeParams: [String: Any] = [
                    "c": c,
                    "cpd": self.makeClientDictionary(anisette: anisette),
                    "M1": proofM1,
                    "o": "complete",
                    "u": sanitizedAppleID
                ]

                let completeResponse = try self.sendGrandSlamRequest(parameters: completeParams, anisette: anisette)

                let status = (completeResponse["Status"] as? [String: Any]) ?? [:]
                let authType = (status["au"] as? String) ?? (completeResponse["au"] as? String)
                let hsc = (status["hsc"] as? Int) ?? 0
                let ec = (status["ec"] as? Int) ?? 0

                ContraAuthLog.shared.log("SRP complete returned. au='\(authType ?? "nil")', hsc=\(hsc), ec=\(ec)")

                // Decrypt SPD payload
                var decryptedSPD: DecryptedSPD?
                if let spdData = completeResponse["spd"] as? Data {
                    do {
                        decryptedSPD = try srp.decryptSPD(spdData)
                        ContraAuthLog.shared.log("SPD payload decrypted successfully. DSID: \(decryptedSPD?.dsid ?? "nil")")
                    } catch {
                        ContraAuthLog.shared.log("Failed to decrypt SPD: \(error.localizedDescription)")
                    }
                }

                let dsid = decryptedSPD?.dsid
                    ?? (status["dsid"] as? String)
                    ?? (completeResponse["dsid"] as? String)
                    ?? ""

                let idmsToken = decryptedSPD?.idmsToken
                    ?? (status["idmsToken"] as? String)
                    ?? (completeResponse["idmsToken"] as? String)
                    ?? ""

                let is2FARequired = ["trustedDeviceSecondaryAuth", "secondaryAuth", "smsSecondaryAuth", "trustedDevice", "pushedCode"].contains(authType ?? "")
                    || (hsc == 409)

                // 5. Handle Two-Factor Authentication Requirement
                if is2FARequired {
                    ContraAuthLog.shared.log("⚠️ Two-Factor Authentication required by Apple. Triggering verification code push...")

                    // Stash pending context
                    self.pendingTwoFactorContext = Pending2FAContext(
                        appleID: sanitizedAppleID,
                        password: password,
                        dsid: dsid,
                        idmsToken: idmsToken,
                        sessionKey: srp.sessionKey(),
                        challengeToken: decryptedSPD?.challengeToken,
                        anisetteHeaders: anisette
                    )

                    // EXPLICITLY TRIGGER 2FA PUSH NOTIFICATION (Fortiva method)
                    let pushSent = self.triggerTrustedDevice2FA(dsid: dsid, idmsToken: idmsToken, anisette: anisette)

                    let msg = pushSent
                        ? "Two-factor authentication required. A 6-digit verification code has been pushed to your Apple devices."
                        : "Two-factor authentication required. Please enter your 6-digit verification code."

                    completion(true, msg, nil)
                    return
                }

                // 6. Direct success without 2FA
                var sessionToken: String?

                // Check if xcode token is already present in decrypted SPD dictionary
                if let rawSPD = decryptedSPD?.rawDictionary,
                   let tokens = rawSPD["t"] as? [String: Any],
                   let xcodeTokenDict = tokens["com.apple.gs.xcode.auth"] as? [String: Any],
                   let tok = xcodeTokenDict["token"] as? String {
                    sessionToken = tok
                    ContraAuthLog.shared.log("Found existing Xcode token in SPD payload.")
                }

                if sessionToken == nil, let sk = srp.sessionKey(), !dsid.isEmpty, !idmsToken.isEmpty {
                    sessionToken = self.fetchAppToken(
                        dsid: dsid,
                        idmsToken: idmsToken,
                        sessionKey: sk,
                        challengeToken: decryptedSPD?.challengeToken,
                        anisette: anisette
                    )
                }

                let token = sessionToken ?? UUID().uuidString
                let teamInfo = self.resolveTeamInfo(dsid: dsid, token: token, anisette: anisette)

                self.saveSession(
                    appleID: sanitizedAppleID,
                    dsid: dsid,
                    token: token,
                    teamID: teamInfo.teamID,
                    teamName: teamInfo.teamName
                )

                ContraAuthLog.shared.log("✅ Authenticated successfully as \(sanitizedAppleID) (Team: \(teamInfo.teamName ?? "N/A"))")
                completion(false, "Successfully authenticated as \(sanitizedAppleID).", nil)
            } catch {
                ContraAuthLog.shared.log("❌ Authentication failed with error: \(error.localizedDescription)")
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

            ContraAuthLog.shared.log("Validating 2FA verification code with Apple GrandSlam...")

            // Build headers as per Fortiva / isideload specification:
            // GET /grandslam/GsService2/validate with header 'security-code: <code>'
            let identityToken = Data("\(context.dsid):\(context.idmsToken)".utf8).base64EncodedString()
            let validateURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!

            var request = URLRequest(url: validateURL)
            request.httpMethod = "POST"
            request.httpBody = Data()
            request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
            request.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
            request.setValue("akd/1.0 CFNetwork Darwin", forHTTPHeaderField: "User-Agent")
            request.setValue("com.apple.gs.xcode.auth", forHTTPHeaderField: "X-Apple-App-Info")
            request.setValue("27.0 (27A5218g)", forHTTPHeaderField: "X-Xcode-Version")
            request.setValue(identityToken, forHTTPHeaderField: "X-Apple-Identity-Token")
            request.setValue(context.dsid, forHTTPHeaderField: "X-Apple-I-DSID")
            request.setValue(cleanCode, forHTTPHeaderField: "security-code")
            request.setValue("close", forHTTPHeaderField: "Connection")

            if let clientInfo = context.anisetteHeaders["X-MMe-Client-Info"] {
                request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
            }

            for (k, v) in context.anisetteHeaders {
                request.setValue(v, forHTTPHeaderField: k)
            }

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
                ContraAuthLog.shared.log("[2FA Validate] Network error: \(err.localizedDescription)")
                completion(false, nil, err)
                return
            }

            let statusCode = httpResponse?.statusCode ?? 0
            ContraAuthLog.shared.log("[2FA Validate] HTTP \(statusCode)")

            var ec = -1
            if let data = responseData,
               let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
               let resp = plist["Response"] as? [String: Any],
               let status = resp["Status"] as? [String: Any] {
                ec = status["ec"] as? Int ?? -1
                ContraAuthLog.shared.log("[2FA Validate] Response ec=\(ec)")
            }

            let isValid = (statusCode == 200 || statusCode == 204) && (ec == 0 || ec == -1)

            guard isValid else {
                ContraAuthLog.shared.log("❌ 2FA validation failed: HTTP \(statusCode), ec=\(ec)")
                completion(false, nil, NSError(
                    domain: "com.kurishu.contrainstalld",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid 2FA verification code. Please check the code and try again."]
                ))
                return
            }

            ContraAuthLog.shared.log("✅ 2FA code verified successfully!")

            // Step 2: Now that 2FA is validated, acquire session token
            var token: String? = nil

            // Try requesting apptokens with existing session key
            if let sk = context.sessionKey, !context.dsid.isEmpty, !context.idmsToken.isEmpty {
                token = self.fetchAppToken(
                    dsid: context.dsid,
                    idmsToken: context.idmsToken,
                    sessionKey: sk,
                    challengeToken: context.challengeToken,
                    anisette: context.anisetteHeaders
                )
            }

            // Fallback: Re-authenticate to obtain fresh session key & token now that 2FA is cleared (Fortiva strategy)
            if token == nil {
                ContraAuthLog.shared.log("Re-authenticating via SRP to retrieve updated session token...")
                self.login(appleID: context.appleID, password: context.password) { success, msg, err in
                    self.pendingTwoFactorContext = nil
                    completion(success, msg, err)
                }
                return
            }

            let finalToken = token ?? UUID().uuidString
            let teamInfo = self.resolveTeamInfo(dsid: context.dsid, token: finalToken, anisette: context.anisetteHeaders)

            self.saveSession(
                appleID: context.appleID,
                dsid: context.dsid,
                token: finalToken,
                teamID: teamInfo.teamID,
                teamName: teamInfo.teamName
            )

            self.pendingTwoFactorContext = nil
            ContraAuthLog.shared.log("✅ Successfully authenticated after 2FA as \(context.appleID)")
            completion(true, "Successfully authenticated as \(context.appleID).", nil)
        }
    }

    // MARK: - Developer Team Resolution

    private func resolveTeamInfo(dsid: String, token: String, anisette: [String: String]) -> (teamID: String?, teamName: String?) {
        guard let listTeamsURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/listTeams.action?clientId=XABBG36SBA") else {
            return (nil, nil)
        }

        ContraAuthLog.shared.log("Querying Developer Portal teams at listTeams.action...")

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
            ContraAuthLog.shared.log("No teams returned from Developer Portal.")
            return (nil, nil)
        }

        let teamID = firstTeam["teamId"] as? String
        let teamName = firstTeam["name"] as? String
        ContraAuthLog.shared.log("Team found: '\(teamName ?? "")' (ID: \(teamID ?? ""))")
        return (teamID, teamName)
    }

    // MARK: - Session Persistence

    private func saveSession(appleID: String, dsid: String, token: String, teamID: String?, teamName: String?) {
        let sessionData: [String: Any] = [
            "appleID": appleID,
            "dsid": dsid,
            "token": token,
            "teamID": teamID ?? "",
            "teamName": teamName ?? "",
            "savedDate": ISO8601DateFormatter().string(from: Date())
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: sessionData, format: .xml, options: 0)
            try data.write(to: self.sessionFileURL, options: .atomic)
            ContraAuthLog.shared.log("Session saved to \(self.sessionFileURL.path)")
        } catch {
            ContraAuthLog.shared.log("Failed to save session plist: \(error.localizedDescription)")
        }
    }

    public func activeSession() -> [String: Any]? {
        guard let data = try? Data(contentsOf: sessionFileURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    public func getAccountStatus() -> [String: Any]? {
        return activeSession()
    }

    public func logout() -> Bool {
        ContraAuthLog.shared.log("Logging out. Removing stored session...")
        pendingTwoFactorContext = nil
        do {
            if FileManager.default.fileExists(atPath: sessionFileURL.path) {
                try FileManager.default.removeItem(at: sessionFileURL)
            }
            return true
        } catch {
            ContraAuthLog.shared.log("Failed to remove session file: \(error.localizedDescription)")
            return false
        }
    }
}

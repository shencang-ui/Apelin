import ApelinProtocol
import Foundation
import KWWKAI
import os

/// The balance and the check-in of one signed-in account, read where its
/// credentials live: a subscription's token never leaves this worker's
/// keychain group, and an API key leaves it for its own provider's meter
/// alone. What goes back over the wire is a balance and a message, never a
/// credential.
///
/// WorkBuddy's two builds are read as the aigw gateway reads them, from its
/// `CodeBuddyProvider`: the meter asks the web host's
/// `/v2/billing/meter/get-user-resource` and sums `Data.Accounts[]`, the
/// check-in posts to `/v2/billing/meter/daily-checkin`, and "already" is a
/// success. Both carry the desktop client's `WorkBuddy/5.5.6` identity, the
/// token, `X-Product: SaaS` and the account's headers; the international
/// build's meter and check-in sit on `www.workbuddy.ai`, the China build's on
/// `www.codebuddy.cn` — not on the chat host the model list reads. DeepSeek
/// and OpenRouter, whose keys the app edits, are read from the keychain the
/// same way and answered with their own meters' numbers. A provider with no
/// meter of its own answers "unknown" rather than an error: the settings
/// page shows nothing, not a failure.
enum AccountMeter {
    private static let log = Logger(subsystem: "wiki.qaq.apelin", category: "Accounts")

    /// WorkBuddy's billing endpoints, as its desktop client's own billing
    /// calls go out (`WorkBuddyOAuth.userAgent`, the version the meter and
    /// the check-in accept).
    private static let workBuddyClientVersion = "5.5.6"
    private static let workBuddyUserAgent = "WorkBuddy/\(workBuddyClientVersion)"
    /// The billing product code the meter query carries (the gateway's
    /// `PRODUCT_CODE`).
    private static let workBuddyProductCode = "p_tcaca"

    // MARK: - Entry points

    /// The signed-in account's balance. Unknown, not an error, when the
    /// provider has no meter this reads.
    static func balance(
        _ provider: AgentProvider,
        credentials: OAuthCredentials,
    ) async -> AgentAccountBalance {
        if let site = WorkBuddySite.site(id: provider.storeID) {
            do {
                return try await workBuddyCredits(site: site, credentials: credentials)
            } catch {
                log.notice("workbuddy meter read failed: \(error.localizedDescription, privacy: .public)")
                return AgentAccountBalance(known: false)
            }
        }
        switch provider {
        case .deepSeek, .openRouter:
            do {
                return try await apiKeyBalance(provider: provider, credentials: credentials)
            } catch {
                log.notice("\(provider.rawValue, privacy: .public) meter read failed: \(error.localizedDescription, privacy: .public)")
                return AgentAccountBalance(known: false)
            }
        default:
            return AgentAccountBalance(known: false)
        }
    }

    /// The provider's daily check-in. WorkBuddy only; the answer's message
    /// is what the settings page shows. A provider outside WorkBuddy's two
    /// builds is refused by its store id — the app side carries the display
    /// names, this worker does not.
    static func checkin(_ provider: AgentProvider, credentials: OAuthCredentials) async throws -> AgentAccountCheckinResponse {
        guard let site = WorkBuddySite.site(id: provider.storeID) else {
            throw ApelinError(.badRequest, "\(provider.rawValue) has no check-in of its own.")
        }
        do {
            return try await workBuddyCheckin(site: site, credentials: credentials)
        } catch let failure as WorkBuddyEnvelope.Failure {
            // 401/403 name a dead login; a business code names the meter's
            // own refusal. Both go to the page as words.
            return AgentAccountCheckinResponse(succeeded: false, message: failure.message)
        } catch {
            return AgentAccountCheckinResponse(succeeded: false, message: error.localizedDescription)
        }
    }

    // MARK: - WorkBuddy (both builds)

    /// WorkBuddy's `{code, msg, data}` envelope, its own spelling of it.
    private struct WorkBuddyEnvelope {
        struct Failure: Error { let message: String }
    }

    /// Whether the credential names the international build's domain, the
    /// way kwwk's `isGlobalDomain` reads it: a `workbuddy.ai` domain, or the
    /// international site itself when the credential names none.
    private static func isInternationalBuild(_ site: WorkBuddySite, credentials: OAuthCredentials) -> Bool {
        if case let .string(domain)? = credentials.extras["domain"], !domain.isEmpty {
            return domain.lowercased().contains("workbuddy.ai")
        }
        return site == .international
    }

    private static func workBuddyWebHost(_ site: WorkBuddySite, credentials: OAuthCredentials) -> String {
        if case let .string(domain)? = credentials.extras["domain"],
           !domain.isEmpty, URLComponents(string: "https://\(domain)")?.host != nil
        {
            let host = URLComponents(string: "https://\(domain)")?.host ?? ""
            if host.contains("workbuddy.ai") { return "https://www.workbuddy.ai" }
        }
        return site == .international ? "https://www.workbuddy.ai" : "https://www.codebuddy.cn"
    }

    /// The billing request's headers: the CLI's own identity, the token,
    /// `X-Product: SaaS` and the account's id and domain, as kwwk's chat
    /// provider names the account on every request.
    private static func workBuddyMeterHeaders(_ site: WorkBuddySite, credentials: OAuthCredentials) -> [String: String] {
        var headers = [
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-Requested-With": "XMLHttpRequest",
            "User-Agent": workBuddyUserAgent,
            "X-Product": "SaaS",
            "Authorization": "Bearer \(credentials.access)",
        ]
        if case let .string(uid)? = credentials.extras["uid"], !uid.isEmpty {
            headers["X-User-Id"] = uid
        }
        if case let .string(enterprise)? = credentials.extras["enterpriseId"], !enterprise.isEmpty {
            headers["X-Enterprise-Id"] = enterprise
            headers["X-Tenant-Id"] = enterprise
        }
        if case let .string(domain)? = credentials.extras["domain"], !domain.isEmpty {
            headers["X-Domain"] = domain
        }
        headers["Origin"] = URLComponents(string: workBuddyWebHost(site, credentials: credentials))?.host ?? ""
        headers["Referer"] = headers["Origin"].map { $0 + "/" } ?? ""
        return headers
    }

    private static func workBuddyRequest(_ url: URL, headers: [String: String], body: Data?) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        return request
    }

    /// The `{code, msg, data}` envelope read: code 0 and a 2xx pass, and the
    /// data comes back. Anything else is a `Failure` with the message the
    /// envelope gave.
    private static func workBuddyData(_ data: Data, status: Int) throws -> [String: Any] {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (root?["code"] as? NSNumber)?.intValue ?? -1
        let said = root?["msg"] as? String ?? ""
        if status == 401 || status == 403 {
            throw WorkBuddyEnvelope.Failure(message: "The sign-in has expired. Sign in to the provider again.")
        }
        guard status / 100 == 2, code == 0 else {
            throw WorkBuddyEnvelope.Failure(message: said.isEmpty ? "HTTP \(status)" : said)
        }
        return (root?["data"] as? [String: Any]) ?? [:]
    }

    /// `POST {webHost}/v2/billing/meter/get-user-resource`, the meter the
    /// gateway's `credits()` reads: the body names the billing product and
    /// a wide window, `Data.Response.Data.Accounts[]` holds one entry per
    /// package, and the balance is what the packages leave.
    private static func workBuddyCredits(site: WorkBuddySite, credentials: OAuthCredentials) async throws -> AgentAccountBalance {
        let host = workBuddyWebHost(site, credentials: credentials)
        guard let url = URL(string: host + "/v2/billing/meter/get-user-resource") else {
            throw WorkBuddyEnvelope.Failure(message: "bad meter URL")
        }
        // The window's end is the gateway's "no upper bound": now plus
        // 3185136000000 ms, formatted the way the CLI sends it.
        let now = Date()
        let end = now.addingTimeInterval(Double(3_185_136_000_000) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let body: [String: Any] = [
            "PageNumber": 1,
            "PageSize": 100,
            "ProductCode": workBuddyProductCode,
            "Status": [0, 3],
            "PackageEndTimeRangeBegin": formatter.string(from: now),
            "PackageEndTimeRangeEnd": formatter.string(from: end),
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(
            for: workBuddyRequest(url, headers: workBuddyMeterHeaders(site, credentials: credentials), body: payload)
        )
        guard let http = response as? HTTPURLResponse else {
            throw WorkBuddyEnvelope.Failure(message: "The provider did not answer.")
        }
        let dataNode = try workBuddyData(data, status: http.statusCode)
        // The envelope nests twice: {code,data:{Response:{Data:{Accounts}}}}.
        let accounts = ((dataNode["Response"] as? [String: Any])?["Data"] as? [String: Any])?["Accounts"] as? [[String: Any]]
        var packs: [AgentAccountBalance.Pack] = []
        var balance = 0.0
        var earliest: Date?
        for account in accounts ?? [] {
            let cycleSize = (account["CycleCapacitySize"] as? NSNumber)?.doubleValue ?? 0
            let capacitySize = (account["CapacitySize"] as? NSNumber)?.doubleValue ?? 0
            let isCycle = cycleSize > 0
            let size = isCycle ? cycleSize : capacitySize
            let used = (account[isCycle ? "CycleCapacityUsed" : "CapacityUsed"] as? NSNumber)?.doubleValue ?? 0
            let remain = (account[isCycle ? "CycleCapacityRemain" : "CapacityRemain"] as? NSNumber)?.doubleValue ?? 0
            var name = account["PackageName"] as? String ?? ""
            if name.isEmpty {
                name = "Package"
            }
            packs.append(AgentAccountBalance.Pack(name: name, limit: size, used: used, remain: remain))
            balance += remain
            if let ends = Self.workBuddyPackageEnd(account),
               earliest.map({ ends < $0 }) ?? true
            {
                earliest = ends
            }
        }
        let known = !packs.isEmpty
        return AgentAccountBalance(
            known: known,
            balance: known ? (balance * 100).rounded() / 100 : nil,
            unit: "credits",
            packs: packs,
            expiresAt: earliest,
        )
    }

    /// A package's end, from the keys the gateway tries, seconds or
    /// milliseconds or a date string, whichever one the entry carries.
    private static func workBuddyPackageEnd(_ account: [String: Any]) -> Date? {
        let keys = ["PackageEndTime", "EndTime", "ExpireTime", "expireAt", "ExpiredTime", "InvalidTime"]
        for key in keys {
            guard let value = account[key] else { continue }
            if let number = value as? NSNumber, number.doubleValue > 0 {
                let milliseconds = number.doubleValue > 1.0e12 ? number.doubleValue : number.doubleValue * 1000
                return Date(timeIntervalSince1970: milliseconds / 1000)
            }
            if let text = value as? String, !text.isEmpty,
               let parsed = DateFormatter.fallbackDate(from: text)
            {
                return parsed
            }
        }
        return nil
    }

    /// `POST {webHost}/v2/billing/meter/daily-checkin` with `{}`. An
    /// international account first asks the activity's status, whose "not
    /// open" means the credits come on their own and there is nothing to
    /// sign. "Already checked in" reads as today's success, either from the
    /// activity status or from the check-in's own refusal.
    private static func workBuddyCheckin(site: WorkBuddySite, credentials: OAuthCredentials) async throws -> AgentAccountCheckinResponse {
        let host = workBuddyWebHost(site, credentials: credentials)
        let headers = workBuddyMeterHeaders(site, credentials: credentials)
        let isInternational = isInternationalBuild(site, credentials: credentials)

        if isInternational,
           let statusURL = URL(string: host + "/v2/billing/meter/checkin-activity-status"),
           let (data, response) = try? await URLSession.shared.data(
               for: workBuddyRequest(statusURL, headers: headers, body: Data("{}".utf8))
           ),
           let http = response as? HTTPURLResponse,
           let status = try? workBuddyData(data, status: http.statusCode)
        {
            if (status["today_checked_in"] as? NSNumber)?.boolValue == true {
                return AgentAccountCheckinResponse(succeeded: true, message: "Already checked in today.")
            }
            if let active = status["active"] as? NSNumber, active.boolValue == false {
                return AgentAccountCheckinResponse(
                    succeeded: true,
                    message: "The international check-in is not open; the daily credits are granted on their own.",
                )
            }
        }

        guard let url = URL(string: host + "/v2/billing/meter/daily-checkin") else {
            throw WorkBuddyEnvelope.Failure(message: "bad check-in URL")
        }
        let (data, response) = try await URLSession.shared.data(
            for: workBuddyRequest(url, headers: headers, body: Data("{}".utf8))
        )
        guard let http = response as? HTTPURLResponse else {
            throw WorkBuddyEnvelope.Failure(message: "The provider did not answer.")
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let said = root?["msg"] as? String ?? ""
        if http.statusCode == 401 || http.statusCode == 403 {
            throw WorkBuddyEnvelope.Failure(message: "The sign-in has expired. Sign in to the provider again.")
        }
        let already = said.range(of: "已签到") != nil || said.range(of: "already", options: .caseInsensitive) != nil
        let unavailable = ["未开启", "已过期", "未开放", "not open", "expired"].contains {
            said.range(of: $0, options: .caseInsensitive) != nil
        }
        if http.statusCode / 100 == 2, (root?["code"] as? NSNumber)?.intValue == 0 {
            return AgentAccountCheckinResponse(succeeded: true, message: "Checked in.")
        }
        if already {
            return AgentAccountCheckinResponse(succeeded: true, message: "Already checked in today.")
        }
        if unavailable {
            return AgentAccountCheckinResponse(succeeded: true, message: said)
        }
        throw WorkBuddyEnvelope.Failure(message: said.isEmpty
            ? "The check-in failed (HTTP \(http.statusCode))."
            : said)
    }

    // MARK: - API-key providers

    /// DeepSeek's `GET /user/balance` and OpenRouter's `GET /api/v1/credits`.
    /// The two meters speak different shapes, read one at a time here. Both
    /// endpoints sit on the provider's own host, never under a key's saved
    /// base URL: that names a relay's model endpoint, which serves no meter.
    private static func apiKeyBalance(provider: AgentProvider, credentials: OAuthCredentials) async throws -> AgentAccountBalance {
        var request: URLRequest
        switch provider {
        case .deepSeek:
            guard let url = URL(string: "https://api.deepseek.com/user/balance") else { return AgentAccountBalance(known: false) }
            request = URLRequest(url: url, timeoutInterval: 20)
        case .openRouter:
            guard let url = URL(string: "https://openrouter.ai/api/v1/credits") else { return AgentAccountBalance(known: false) }
            request = URLRequest(url: url, timeoutInterval: 20)
        default:
            return AgentAccountBalance(known: false)
        }
        request.setValue("Bearer \(credentials.access)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ApelinError(.unavailable, "The provider did not answer.")
        }
        guard http.statusCode == 200, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ApelinError(.unavailable, "HTTP \(http.statusCode)")
        }
        if provider == .deepSeek {
            // {is_available, balance_infos: [{total_balance, currency}]}
            let infos = root["balance_infos"] as? [[String: Any]] ?? []
            guard let first = infos.first,
                  let total = Double(first["total_balance"] as? String ?? (first["total_balance"] as? NSNumber)?.stringValue ?? "")
            else { return AgentAccountBalance(known: false) }
            let currency = first["currency"] as? String
            return AgentAccountBalance(known: true, balance: total, unit: currency)
        }
        // {data: {total_credits, total_usage}}
        let node = root["data"] as? [String: Any] ?? [:]
        guard let credits = (node["total_credits"] as? NSNumber)?.doubleValue else {
            return AgentAccountBalance(known: false)
        }
        let usage = (node["total_usage"] as? NSNumber)?.doubleValue ?? 0
        return AgentAccountBalance(
            known: true,
            balance: credits - usage,
            unit: "USD",
        )
    }
}

private extension DateFormatter {
    /// WorkBuddy's timestamps come as seconds or milliseconds or a
    /// "yyyy-MM-dd HH:mm:ss" string; the last one is read as it is, the
    /// device's own time, the way the gateway reads it.
    static func fallbackDate(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

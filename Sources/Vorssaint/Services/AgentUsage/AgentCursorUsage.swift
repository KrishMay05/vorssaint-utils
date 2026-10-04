// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import SQLite3

/// Cursor's included usage and on-demand spend limit, read from the account
/// the Cursor app is already signed into. The sign-in stays in Cursor's
/// database; it is sent only to Cursor, and only for this reading.
enum AgentCursorUsage {
    static let freshness: TimeInterval = 5 * 60
    static let includedID = "cursor-included"
    static let onDemandID = "cursor-ondemand"
    static let autoID = "cursor-auto"
    static let apiID = "cursor-api"

    struct Reading: Equatable {
        let limits: AgentLimits
        let plan: AgentPlan?
    }

    static func stateDatabase(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    static func isInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(atPath: stateDatabase(home: home).path)
    }

    /// Included spend fills the first row. An on-demand cap fills the second
    /// when one is set; otherwise the fuller of the Auto and API buckets does.
    /// The limits card has room for two.
    static func displayed(_ windows: [AgentLimitWindow]) -> [AgentLimitWindow] {
        var picked: [AgentLimitWindow] = []
        if let included = windows.first(where: { $0.id == includedID }) { picked.append(included) }
        if let spend = windows.first(where: { $0.id == onDemandID }) { picked.append(spend) }
        if picked.count < 2 {
            let coding = windows.filter { $0.id == autoID || $0.id == apiID }.max {
                $0.usedPercent < $1.usedPercent
            }
            if let coding { picked.append(coding) }
        }
        return Array(picked.prefix(2))
    }

    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> Reading? {
        guard let token = accessToken(home: home) else { return nil }
        guard let usage = post("/aiserver.v1.DashboardService/GetCurrentPeriodUsage", token: token) else { return nil }
        let plan = post("/aiserver.v1.DashboardService/GetPlanInfo", token: token)
        return reading(usage: usage, plan: plan, observed: now)
    }

    static func reading(usage: [String: Any], plan: [String: Any]?, observed: Date) -> Reading? {
        guard let planUsage = usage["planUsage"] as? [String: Any] else { return nil }
        let end = date(usage["billingCycleEnd"])
        let start = date(usage["billingCycleStart"])
        let minutes: Int? = {
            guard let start, let end, end > start else { return nil }
            return max(1, Int(end.timeIntervalSince(start) / 60))
        }()
        var windows: [AgentLimitWindow] = []
        if let limit = number(planUsage["limit"]), limit > 0, let included = number(planUsage["includedSpend"]) {
            windows.append(window(id: includedID, scope: "Included \(money(included))/\(money(limit))",
                                  usedPercent: included / limit * 100, minutes: minutes, resetsAt: end))
        } else if let total = number(planUsage["totalPercentUsed"]) {
            windows.append(window(id: includedID, scope: "Included", usedPercent: total, minutes: minutes, resetsAt: end))
        }
        if let spend = usage["spendLimitUsage"] as? [String: Any] {
            let individualLimit = number(spend["individualLimit"])
            let pooledLimit = number(spend["pooledLimit"])
            if let limit = individualLimit, limit > 0 {
                let used = number(spend["individualUsed"]) ?? 0
                windows.append(window(id: onDemandID, scope: "On-demand \(money(used))/\(money(limit))",
                                      usedPercent: used / limit * 100, minutes: minutes, resetsAt: end))
            } else if let limit = pooledLimit, limit > 0 {
                let used = number(spend["pooledUsed"]) ?? 0
                windows.append(window(id: onDemandID, scope: "On-demand \(money(used))/\(money(limit))",
                                      usedPercent: used / limit * 100, minutes: minutes, resetsAt: end))
            }
        }
        if let auto = number(planUsage["autoPercentUsed"]) {
            windows.append(window(id: autoID, scope: "Auto", usedPercent: auto, minutes: minutes, resetsAt: end))
        }
        if let api = number(planUsage["apiPercentUsed"]) {
            windows.append(window(id: apiID, scope: "API", usedPercent: api, minutes: minutes, resetsAt: end))
        }
        guard !windows.isEmpty else { return nil }
        let info = plan?["planInfo"] as? [String: Any]
        let name = (info?["planName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let priced = (info?["price"] as? String).flatMap(monthlyPrice)
        let agentPlan = name.flatMap { $0.isEmpty ? nil : AgentPlan(name: $0, monthlyPrice: priced) }
        return Reading(limits: AgentLimits(provider: .cursor, windows: windows, observedAt: observed, source: .account),
                       plan: agentPlan)
    }

    static func accessToken(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        accessToken(database: stateDatabase(home: home))
    }

    static func accessToken(database: URL) -> String? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        let raw: String?
        if let text = sqlite3_column_text(statement, 0) {
            raw = String(cString: text)
        } else if let blob = sqlite3_column_blob(statement, 0) {
            let count = Int(sqlite3_column_bytes(statement, 0))
            raw = String(data: Data(bytes: blob, count: count), encoding: .utf8)
        } else {
            raw = nil
        }
        return normalize(raw)
    }

    private static func window(id: String, scope: String, usedPercent: Double, minutes: Int?,
                               resetsAt: Date?) -> AgentLimitWindow {
        AgentLimitWindow(id: id, kind: .other, minutes: minutes, scope: scope,
                         usedPercent: usedPercent.isFinite ? max(0, usedPercent) : 0, resetsAt: resetsAt)
    }

    private static func post(_ path: String, token: String) -> [String: Any]? {
        guard let url = URL(string: "https://api2.cursor.sh" + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        let arrived = DispatchSemaphore(value: 0)
        var parsed: [String: Any]?
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { arrived.signal() }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            parsed = json
        }
        task.resume()
        guard arrived.wait(timeout: .now() + 25) == .success else {
            task.cancel()
            return nil
        }
        return parsed
    }

    private static func normalize(_ raw: String?) -> String? {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        if token.hasPrefix("\""), token.hasSuffix("\""),
           let data = token.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            token = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard token.count >= 20, !token.contains(where: \.isWhitespace) else { return nil }
        return token
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let millis = number(value), millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    private static func money(_ cents: Double) -> String {
        let dollars = cents / 100
        guard dollars.isFinite else { return "$0" }
        if abs(dollars.rounded() - dollars) < 0.001 {
            return "$\(Int(dollars.rounded()))"
        }
        return String(format: "$%.2f", dollars)
    }

    private static func monthlyPrice(_ text: String) -> Double? {
        var digits = ""
        var started = false
        for character in text {
            if character.isNumber || (character == "." && started) {
                digits.append(character)
                started = true
            } else if started {
                break
            }
        }
        return Double(digits)
    }
}

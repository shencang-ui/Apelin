import ApelinProtocol
import Foundation
import KWWKAI

/// The reasoning levels each WorkBuddy model was last seen offering, per
/// store id.
///
/// The live config fetch — this module's `WorkBuddyEffortRefresher`, asked
/// from the worker and from a session's own resolve — names the models and
/// their levels together, while the account list needs the same levels
/// without a request of its own: what a fetch kept answers the list, and a
/// model no fetch has covered yet falls back to the bundled rows. Ten
/// minutes is what kwwk keeps a gate's own listing for: the config does not
/// change often, and an account list is drawn every time Settings opens. A
/// stale entry still answers for the session's own model — the bundled rows
/// say nothing for several, `deepseek-v4.1-flash` among them, and a
/// session's request carries `reasoning_effort` only when the model record
/// says it reasons — with a fresh fetch asked behind the answer.
public final class WorkBuddyEffortCache: @unchecked Sendable {
    public static let shared = WorkBuddyEffortCache()

    private let lock = NSLock()
    private var entries: [String: (efforts: [String: [AgentReasoningEffort]], at: Date)] = [:]
    private let lifetime: TimeInterval = 10 * 60

    /// Objective-C cannot carry these dictionaries, so the accessors stay
    /// plain (AGENTS.md ▸ Hard rules).
    public func efforts(for storeID: String) -> [String: [AgentReasoningEffort]]? {
        lock.withLock {
            guard let entry = entries[storeID], Date().timeIntervalSince(entry.at) < lifetime else { return nil }
            return entry.efforts
        }
    }

    /// The entry even when stale, for a read that would rather have the last
    /// answer than none, with the fresh fetch asked behind it.
    public func staleEfforts(for storeID: String) -> [String: [AgentReasoningEffort]]? {
        lock.withLock { entries[storeID]?.efforts }
    }

    /// Whether `storeID` is one of WorkBuddy's two builds.
    public static func isWorkBuddy(storeID: String) -> Bool {
        storeID == "workbuddy" || storeID == "workbuddy-ai"
    }

    public func store(_ efforts: [String: [AgentReasoningEffort]], for storeID: String) {
        lock.withLock { entries[storeID] = (efforts, Date()) }
    }
}

/// Reads WorkBuddy's live model config and keeps what each model offers in
/// `WorkBuddyEffortCache`, joining a read already in flight for the same
/// site. Fired from the account list on a cold cache, so the next opening
/// carries the levels, and from a session's resolve, so the model a chat
/// runs under says it reasons.
public enum WorkBuddyEffortRefresher {
    private static let lock = NSLock()
    private static var inFlight: [String: Task<Void, Never>] = [:]

    /// The levels a model record's map names as supported: the keys whose
    /// entry is a wire value, in the level order kwwk keeps. A model with no
    /// map offers none.
    static func supportedThinkingLevels(of model: KWWKAI.Model) -> [String] {
        let order = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
        guard let map = model.thinkingLevelMap else { return [] }
        return order.filter { level in
            guard let entry = map[level] else { return false }
            if case .string? = entry { return true }
            return false
        }
    }

    public static func refresh(siteID: String, credentials: OAuthCredentials) {
        guard let site = WorkBuddySite.site(id: siteID) else { return }
        lock.withLock {
            if let running = inFlight[siteID], !running.isCancelled { return }
            inFlight[siteID] = Task.detached(priority: .utility) {
                defer {
                    lock.withLock { inFlight[siteID] = nil }
                }
                guard let listings = try? await WorkBuddyModels.fetch(site: site, credentials: credentials) else { return }
                var levels: [String: [AgentReasoningEffort]] = [:]
                for listing in listings where levels[listing.model.id] == nil {
                    levels[listing.model.id] = supportedThinkingLevels(of: listing.model)
                        .compactMap { AgentReasoningEffort(rawValue: $0) }
                }
                WorkBuddyEffortCache.shared.store(levels, for: siteID)
            }
        }
    }
}

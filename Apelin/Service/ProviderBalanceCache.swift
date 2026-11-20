import ApelinCore
import ApelinProtocol
import Foundation

/// The last balance each provider answered, kept so the model sheet and the
/// settings page show the last read instead of asking the worker every time
/// the sheet opens. In memory while the app runs, in the app's own defaults
/// across launches; a balance holds no credential, only the numbers the
/// provider's meter said and when they were read. A read older than ten
/// minutes is stale: the sheet shows it and asks for a new one beside it.
enum ProviderBalanceCache {
    /// One stored balance, tagged with its provider: the shape the list on
    /// disk carries, read one entry at a time through `PreservedList`, so an
    /// entry another version wrote badly is kept as it was and written back
    /// with the rest instead of taking them all down.
    private struct Entry: Codable {
        var provider: String
        var balance: AgentAccountBalance
    }

    private static let defaultsKey = "apelin.providerBalances"
    private static let maxAge: TimeInterval = 10 * 60

    private static var memory: [String: AgentAccountBalance] = [:]
    private static let queue = DispatchQueue(label: "wiki.qaq.apelin.balances")

    /// The provider's last balance, or nil when none was read yet or the
    /// last one has gone stale.
    static func balance(for provider: AgentProvider) -> AgentAccountBalance? {
        queue.sync {
            guard let balance = memory[provider.rawValue] ?? readStoredList().last(where: { $0.provider == provider.rawValue })?.balance,
                  Date().timeIntervalSince(balance.readAt) < maxAge
            else { return nil }
            return balance
        }
    }

    static func store(_ balance: AgentAccountBalance, for provider: AgentProvider) {
        queue.sync {
            memory[provider.rawValue] = balance
            var entries = readStoredList()
            entries.removeAll { $0.provider == provider.rawValue }
            entries.append(Entry(provider: provider.rawValue, balance: balance))
            writeStored(entries)
        }
    }

    /// Forgets the provider's balance: a check-in may have changed it.
    static func expire(for provider: AgentProvider) {
        queue.sync {
            memory[provider.rawValue] = nil
            let entries = readStoredList().filter { $0.provider != provider.rawValue }
            writeStored(entries)
        }
    }

    /// Whether the provider's balance would ask the worker again: nothing
    /// read yet, or the last read past its age.
    static func isStale(_ provider: AgentProvider) -> Bool {
        balance(for: provider) == nil
    }

    /// One line for a group's subtitle: what is left and how old the read
    /// is. Nil when there is nothing to show.
    static func subtitle(for provider: AgentProvider) -> String? {
        guard let balance = balance(for: provider) else { return nil }
        guard balance.known, let balanceValue = balance.balance else { return nil }
        let amount = balanceValue.formatted(.number.precision(.fractionLength(0...2)))
        let age = Int(Date().timeIntervalSince(balance.readAt) / 60)
        let staleness = age <= 0
            ? String(localized: "just now")
            : String(localized: "\(age) min ago")
        let unit = balance.unit ?? ""
        return unit.isEmpty ? "\(amount) · \(staleness)" : "\(amount) \(unit) · \(staleness)"
    }

    // MARK: - Storage

    /// The stored list, one entry at a time: an entry that does not decode
    /// stays in `PreservedList`'s `unreadable` and is written back unchanged,
    /// never allowed to blank the rest. A blob that is not a list at all — a
    /// hand edit, or a shape another version wrote — answers empty: what was
    /// in it is gone from the cache, and what the cache keeps is only the
    /// last meter read, which the next stale check asks for again. No
    /// credential rides in it.
    private static func readStoredList() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        guard let list = try? JSONDecoder().decode(PreservedList<Entry>.self, from: data) else {
            return []
        }
        return list.items
    }

    private static func writeStored(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(PreservedList(entries)) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

public extension AgentProvider {
    /// Whether a balance read has somewhere to read from: the WorkBuddy
    /// builds' meter, DeepSeek's and OpenRouter's own hosts, and the OpenAI
    /// meters — OpenAI's own and any OpenAI-compatible endpoint's, whose
    /// base URL is the host its panel answers the billing call on. An
    /// Anthropic OAuth seat or a Copilot plan has no meter this reads.
    var supportsBalance: Bool {
        if case .openAICompatibleEndpoint = self { return true }
        switch self {
        case .workBuddy, .workBuddyAI, .deepSeek, .openRouter, .openAI, .openAICompatible:
            true
        default:
            false
        }
    }

    /// Whether the provider runs a daily check-in to sign.
    var supportsCheckin: Bool {
        self == .workBuddy || self == .workBuddyAI
    }
}

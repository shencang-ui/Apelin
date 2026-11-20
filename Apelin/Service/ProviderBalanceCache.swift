import ApelinProtocol
import Foundation

/// The last balance each provider answered, kept so the model sheet and the
/// settings page show the last read instead of asking the worker every time
/// the sheet opens. In memory while the app runs, in the app's own defaults
/// across launches; a balance holds no credential, only the numbers the
/// provider's meter said and when they were read. A read older than ten
/// minutes is stale: the sheet shows it and asks for a new one beside it.
enum ProviderBalanceCache {
    private static let defaultsKey = "apelin.providerBalances"
    private static let maxAge: TimeInterval = 10 * 60

    private static var memory: [String: AgentAccountBalance] = [:]
    private static let queue = DispatchQueue(label: "wiki.qaq.apelin.balances")

    /// The provider's last balance, or nil when none was read yet or the
    /// last one has gone stale.
    static func balance(for provider: AgentProvider) -> AgentAccountBalance? {
        queue.sync {
            guard let balance = memory[provider.rawValue] ?? readStored()[provider.rawValue],
                  Date().timeIntervalSince(balance.readAt) < maxAge
            else { return nil }
            return balance
        }
    }

    static func store(_ balance: AgentAccountBalance, for provider: AgentProvider) {
        queue.sync {
            memory[provider.rawValue] = balance
            var stored = readStored()
            stored[provider.rawValue] = balance
            writeStored(stored)
        }
    }

    /// Forgets the provider's balance: a check-in may have changed it.
    static func expire(for provider: AgentProvider) {
        queue.sync {
            memory[provider.rawValue] = nil
            var stored = readStored()
            stored[provider.rawValue] = nil
            writeStored(stored)
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

    private static func readStored() -> [String: AgentAccountBalance] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: AgentAccountBalance].self, from: data)) ?? [:]
    }

    private static func writeStored(_ balances: [String: AgentAccountBalance]) {
        guard let data = try? JSONEncoder().encode(balances) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

public extension AgentProvider {
    /// Whether a balance read has somewhere to read from: the WorkBuddy
    /// builds' meter, and the two key providers whose meters the app reads
    /// on their own hosts. An Anthropic OAuth seat or a Copilot plan has no
    /// meter this reads, and a further OpenAI-compatible endpoint names no
    /// balance endpoint of its own.
    var supportsBalance: Bool {
        self == .workBuddy || self == .workBuddyAI || self == .deepSeek || self == .openRouter
    }

    /// Whether the provider runs a daily check-in to sign.
    var supportsCheckin: Bool {
        self == .workBuddy || self == .workBuddyAI
    }
}

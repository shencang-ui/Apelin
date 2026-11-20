import Foundation

/// A provider account's balance or credits, read by `agentAccountBalance`
/// in apelin-agent's `credential-import` instance, where the credentials
/// live. Nothing secret crosses the wire: a balance, its currency and the
/// packs it sums, or the error that stopped the read. The check-in result
/// of `agentAccountCheckin` says only what the user would read on the
/// provider's own page. The app caches the last answer per provider; a
/// balance read again after one minute takes a new request.
public struct AgentAccountBalance: Codable, Sendable, Equatable {
    /// Whether the provider answered with a balance at all: a plan with no
    /// meter (an Anthropic OAuth seat, an enterprise seat without packs)
    /// answers `false`, not an error.
    public var known: Bool
    /// The credits or money left, in the provider's own unit.
    public var balance: Double?
    /// What the unit is: a currency code ("CNY"), or a provider's own word.
    public var unit: String?
    /// One line per package the balance sums, as the provider lists them.
    public var packs: [Pack]
    /// The earliest end of a package, when any names one.
    public var expiresAt: Date?
    /// When this was read, so the sheet can say how stale it is.
    public var readAt: Date

    public struct Pack: Codable, Sendable, Equatable {
        public var name: String
        /// The package's whole size, cycle or capacity.
        public var limit: Double
        public var used: Double
        public var remain: Double

        public init(name: String, limit: Double, used: Double, remain: Double) {
            self.name = name
            self.limit = limit
            self.used = used
            self.remain = remain
        }
    }

    public init(
        known: Bool,
        balance: Double? = nil,
        unit: String? = nil,
        packs: [Pack] = [],
        expiresAt: Date? = nil,
        readAt: Date = Date(),
    ) {
        self.known = known
        self.balance = balance
        self.unit = unit
        self.packs = packs
        self.expiresAt = expiresAt
        self.readAt = readAt
    }
}

/// The balance of one provider's signed-in account. The read runs in
/// apelin-agent: a subscription's token never leaves the keychain it sits
/// in, and an API key leaves it for its own provider's meter alone. An
/// unsigned-in provider is refused `notFound`.
public struct AgentAccountBalanceRequest: OperationRequest {
    public typealias Response = AgentAccountBalanceResponse
    public static let operation = AppOperation.agentAccountBalance
    public var provider: AgentProvider
    public init(provider: AgentProvider) {
        self.provider = provider
    }
}

public struct AgentAccountBalanceResponse: Codable, Sendable, Equatable {
    public var balance: AgentAccountBalance?
    public init(balance: AgentAccountBalance?) {
        self.balance = balance
    }
}

/// Signs the provider's daily check-in, where the provider has one
/// (WorkBuddy). A provider with no check-in of its own is refused
/// `badRequest`; one whose activity is not open answers that, not an
/// error. "Already checked in" is a success.
public struct AgentAccountCheckinRequest: OperationRequest {
    public typealias Response = AgentAccountCheckinResponse
    public static let operation = AppOperation.agentAccountCheckin
    public var provider: AgentProvider
    public init(provider: AgentProvider) {
        self.provider = provider
    }
}

public struct AgentAccountCheckinResponse: Codable, Sendable, Equatable {
    public var succeeded: Bool
    /// What the provider said, or what the check-in did: the words the
    /// settings page shows.
    public var message: String

    public init(succeeded: Bool, message: String) {
        self.succeeded = succeeded
        self.message = message
    }
}

public extension ApelinService {
    func agentAccountBalance(provider: AgentProvider) async throws -> AgentAccountBalanceResponse {
        try await send(AgentAccountBalanceRequest(provider: provider))
    }

    func agentAccountCheckin(provider: AgentProvider) async throws -> AgentAccountCheckinResponse {
        try await send(AgentAccountCheckinRequest(provider: provider))
    }
}

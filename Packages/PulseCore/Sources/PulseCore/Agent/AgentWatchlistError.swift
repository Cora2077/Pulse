import Foundation

public enum AgentWatchlistError: Error, Equatable, Sendable {
    case groupNotFound(UUID)
    case symbolNotFound(AgentSymbolRef)
    case invalidSymbol(AgentSymbolRef)
    case invalidName
    case duplicateGroupName(String)
    case lastGroupProtected
    case positionNotSupported
    case itemNotOnWatchlist
    case invalidQuantity
    case invalidPrice
    case invalidBuyAccount
    case invalidBuyMethod
    case transactionNotFound(UUID)
    case searchUnavailable
    case searchFailed(String)
    /// `group_ids` is not a permutation of the current watchlist groups.
    case invalidGroupOrder
    /// `symbols` is not a permutation of the target group's members.
    case invalidSymbolOrder
    /// The store refused a checked trade mutation. The sentence is the store's
    /// own localized reason, carried verbatim so a caller reads *why* the write
    /// was declined instead of a collapsed generic code. Nothing was written.
    case tradeMutationFailed(String)
}

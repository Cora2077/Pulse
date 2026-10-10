import Foundation
import Security

@main
struct MCPTokenStoreTests {
    enum FixtureError: Error { case denied, saveFailed }
    enum CheckFailure: Error { case failed(String) }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }

    @MainActor
    static func main() throws {
        var generated = 0
        var writes = 0
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
            do {
                _ = try MCPTokenStore.loadOrCreate(read: {
                    try MCPTokenStore.decodeRead(status: status, data: nil)
                }, generate: { generated += 1; return "synthetic-unwanted" },
                   persist: { _ in writes += 1 })
                throw CheckFailure.failed("unavailable Keychain access must fail")
            } catch let failure as MCPTokenStore.KeychainFailure {
                try check(failure.status == status, "preserve the no-interaction failure")
            }
        }
        try check(generated == 0 && writes == 0,
                  "blocked authorization must never replace the saved token")
        do {
            _ = try MCPTokenStore.loadOrCreate(read: {
                try MCPTokenStore.decodeRead(status: errSecAuthFailed, data: nil)
            }, generate: { generated += 1; return "synthetic-new" }, persist: { _ in writes += 1 })
            throw CheckFailure.failed("denied reads must fail")
        } catch let failure as MCPTokenStore.KeychainFailure {
            try check(failure.status == errSecAuthFailed, "preserve the actual Keychain failure")
        }
        try check(generated == 0 && writes == 0, "denial must never replace an existing token")

        let created = try MCPTokenStore.loadOrCreate(read: {
            try MCPTokenStore.decodeRead(status: errSecItemNotFound, data: nil)
        }, generate: { generated += 1; return "synthetic-created" }, persist: { _ in writes += 1 })
        try check(created == "synthetic-created" && generated == 1 && writes == 1,
                  "only an absent item may create and persist a token")
        do {
            _ = try MCPTokenStore.decodeRead(status: errSecSuccess, data: Data())
            throw CheckFailure.failed("empty records must not become new tokens")
        } catch let failure as MCPTokenStore.KeychainFailure {
            try check(failure.status == errSecDecode, "corrupt records remain an error")
        }

        var reads = 0
        var mayRead = false
        var mayRotate = false
        let session = MCPTokenSession(read: {
            reads += 1
            guard mayRead else { throw FixtureError.denied }
            return "synthetic-old"
        }, rotate: {
            guard mayRotate else { throw FixtureError.saveFailed }
            writes += 1
            return "synthetic-rotated"
        })
        for _ in 0..<3 {
            do {
                _ = try session.current()
                throw CheckFailure.failed("the initial denial must propagate")
            } catch FixtureError.denied {}
        }
        try check(reads == 1, "view refreshes must not repeat denied Keychain requests")
        mayRead = true
        session.retryAfterFailure()
        let first = try session.current()
        let again = try session.current()
        try check(first == "synthetic-old" && again == first && reads == 2,
                  "explicit retry reads once, then reuses the listener token")
        do {
            _ = try session.rotate()
            throw CheckFailure.failed("failed persistence must propagate")
        } catch FixtureError.saveFailed {}
        let afterFailure = try session.current()
        try check(afterFailure == first && reads == 2, "failed rotation preserves the working token")
        mayRotate = true
        let rotated = try session.rotate()
        let afterRotation = try session.current()
        try check(rotated == "synthetic-rotated" && afterRotation == rotated && reads == 2,
                  "successful rotation must replace the cached token without another read")

        var successfulReads = 0
        let successfulSession = MCPTokenSession(read: {
            successfulReads += 1
            return "synthetic-read-\(successfulReads)"
        })
        let initiallyLoaded = try successfulSession.current()
        successfulSession.retryAfterFailure()
        let afterRestart = try successfulSession.current()
        try check(initiallyLoaded == "synthetic-read-1" && afterRestart == initiallyLoaded
                  && successfulReads == 1,
                  "successful first reads stay cached across listener restarts")

        var unloadedReads = 0
        let unloadedSession = MCPTokenSession(read: {
            unloadedReads += 1
            return "synthetic-unloaded"
        }, rotate: { "synthetic-first-rotation" })
        let firstRotation = try unloadedSession.rotate()
        unloadedSession.retryAfterFailure()
        let afterFirstRotation = try unloadedSession.current()
        try check(firstRotation == "synthetic-first-rotation" && afterFirstRotation == firstRotation
                  && unloadedReads == 0,
                  "rotation before the first read supplies the listener token without a read")
        print("MCP_KEYCHAIN_SESSION_SELFTEST passed")
    }
}

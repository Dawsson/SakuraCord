@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

@Suite(.serialized)
struct CommandIndexSafetyTests {
    @Test func `unavailable channel command indexes cannot stop other conversations`() async throws {
        let provider = makeProvider()
        for id in [200, 201] {
            await #expect(throws: ChatProviderError.self) {
                _ = try await provider.applicationCommandCatalog(for: .channel(.init(rawValue: UInt64(id))))
            }
        }
        #expect(await !provider.requestSafetyCircuitIsOpen)
        let catalog = try await provider.applicationCommandCatalog(for: .user)
        #expect(catalog.target == .user)
        #expect(CommandIndexSafetyURLProtocol.paths.withLock { $0 } == [
            "/api/v9/channels/200/application-command-index",
            "/api/v9/channels/201/application-command-index",
            "/api/v9/users/@me/application-command-index"
        ])
        await provider.disconnect()
    }

    @Test(arguments: [false, true])
    func `real session stops retain their reason and prevent later requests`(authentication: Bool) async throws {
        let provider = makeProvider()
        let path = authentication ? "/channels/202/application-command-index" : "/unexpected-resource/200"
        for _ in 0 ..< (authentication ? 1 : 2) {
            do {
                _ = try await provider.perform(path, method: "GET", query: [], body: nil)
            } catch {}
        }
        #expect(await provider.requestSafetyCircuitIsOpen)
        let count = CommandIndexSafetyURLProtocol.paths.withLock { $0.count }
        do {
            _ = try await provider.applicationCommandCatalog(for: .user)
            Issue.record("A stopped session must reject the next request")
        } catch {
            let reason = await provider.requestSafetyStopReason
            #expect(error.localizedDescription == reason)
            #expect(reason.contains(authentication ? "HTTP 401" : "not-found"))
        }
        #expect(CommandIndexSafetyURLProtocol.paths.withLock { $0.count } == count)
        await provider.disconnect()
    }

    private func makeProvider() -> DiscordRESTProvider {
        CommandIndexSafetyURLProtocol.paths.withLock { $0.removeAll() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CommandIndexSafetyURLProtocol.self]
        return DiscordRESTProvider(credentials: TestCredentialStore(),
                                   handle: CredentialHandle(accountID: "command-index-safety"),
                                   session: URLSession(configuration: configuration))
    }
}

private final class CommandIndexSafetyURLProtocol: URLProtocol, @unchecked Sendable {
    static let paths = Mutex<[String]>([])
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.paths.withLock { $0.append(url.path) }
        let status = url.path.contains("/202/") ? 401 : url.path == "/api/v9/users/@me/application-command-index" ? 200 : 404
        let body = status == 200 ? #"{"applications":[],"application_commands":[]}"#
            : status == 401 ? #"{"code":40001,"message":"Unauthorized"}"# : #"{"code":10003,"message":"Unknown Channel"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
                                                            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

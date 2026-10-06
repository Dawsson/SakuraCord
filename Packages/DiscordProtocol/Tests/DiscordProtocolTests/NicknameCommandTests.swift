@testable import DiscordProtocol
import Foundation
import SakuraCordModels
import Synchronization
import Testing

@Suite(.serialized)
struct NicknameCommandTests {
    @Test func `nickname set and reset are single scoped mutations and reconcile the member`() async throws {
        let provider = await makeProvider()
        let guildID = GuildID(rawValue: 100)
        #expect(try await provider.setNickname("Research", in: guildID) == "Research")
        #expect(await provider.cachedMembers[guildID]?.first?.guildNickname == "Research")
        #expect(try await provider.setNickname("", in: guildID) == nil)
        #expect(await provider.cachedMembers[guildID]?.first?.guildNickname == nil)
        let requests = NicknameURLProtocol.requests.withLock { $0 }
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.httpMethod == "PATCH" && $0.url?.absoluteString == "https://discord.com/api/v9/guilds/100/members/%40me/nick" })
        #expect(await !provider.requestSafetyCircuitIsOpen)
        await provider.disconnect()
    }

    @Test func `nickname validation and permission failures do not stop the session or retry`() async throws {
        let provider = await makeProvider()
        for value in ["invalid", "forbidden"] {
            await #expect(throws: (any Error).self) {
                _ = try await provider.setNickname(value, in: .init(rawValue: 100))
            }
            #expect(await !provider.requestSafetyCircuitIsOpen)
        }
        #expect(NicknameURLProtocol.requests.withLock { $0.count } == 2)
        #expect(try await provider.setNickname("Recovered", in: .init(rawValue: 100)) == "Recovered")
        await provider.disconnect()
    }

    private func makeProvider() async -> DiscordRESTProvider {
        NicknameURLProtocol.requests.withLock { $0.removeAll() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NicknameURLProtocol.self]
        let provider = DiscordRESTProvider(credentials: TestCredentialStore(),
                                           handle: CredentialHandle(accountID: "nickname-command"),
                                           session: URLSession(configuration: configuration))
        await provider.seedNicknameCommand()
        return provider
    }
}

private extension DiscordRESTProvider {
    func seedNicknameCommand() {
        currentUser = User(id: .init(rawValue: 1), username: "fixture", displayName: "Fixture")
    }
}

private final class NicknameURLProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let body: Data
        if let data = request.httpBody { body = data } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        } else { body = Data() }
        let nickname = (try? JSONDecoder().decode([String: String].self, from: body))?["nick"]
        let status = nickname == "invalid" ? 400 : nickname == "forbidden" ? 403 : nickname == nil ? 500 : 200
        let responseBody: String
        if status == 400 {
            responseBody = #"{"code":50035,"errors":{"nick":{"_errors":[{"code":"INVALID","message":"Invalid nickname"}]}}}"#
        } else if status == 403 {
            responseBody = #"{"code":50013,"message":"Missing Permissions"}"#
        } else {
            let nick = nickname.flatMap { $0.isEmpty ? nil : $0 }.map(JSONValue.string) ?? .null
            let response = JSONValue.object(["user": .object(["id": .string("1"), "username": .string("fixture")]),
                                             "nick": nick, "roles": .array([])])
            responseBody = (try? JSONEncoder().encode(response)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                                                            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

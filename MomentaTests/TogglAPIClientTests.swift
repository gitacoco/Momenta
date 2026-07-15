import Foundation
import Testing
@testable import Momenta

/// Transport stub: returns canned data/status or throws, and records the
/// last request for header/URL assertions.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    var result: Result<(Data, Int), Error>
    private(set) var lastRequest: URLRequest?

    init(data: Data = Data("{}".utf8), status: Int = 200) {
        result = .success((data, status))
    }

    init(error: Error) {
        result = .failure(error)
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lastRequest = request
        switch result {
        case .success(let (data, status)):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        case .failure(let error):
            throw error
        }
    }
}

struct TogglAPIClientTests {
    private func client(_ transport: StubTransport, token: String = "tok123") -> TogglAPIClient {
        TogglAPIClient(token: token, transport: transport)
    }

    // MARK: Auth

    @Test func requestCarriesBasicAuthHeader() async throws {
        let transport = StubTransport(data: Data(#"{"id":1,"fullname":"Z","email":"z@x.dev"}"#.utf8))
        _ = try await client(transport, token: "secret-token").me()
        let expected = "Basic " + Data("secret-token:api_token".utf8).base64EncodedString()
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Authorization") == expected)
    }

    // MARK: Error classification

    @Test(arguments: [(401, TogglAPIError.unauthorized), (403, .unauthorized), (429, .rateLimited), (503, .server(status: 503))])
    func httpStatusClassification(status: Int, expected: TogglAPIError) async {
        let transport = StubTransport(data: Data(), status: status)
        await #expect(throws: expected) {
            _ = try await client(transport).me()
        }
    }

    @Test func urlErrorsClassifyAsOffline() async {
        let transport = StubTransport(error: URLError(.notConnectedToInternet))
        await #expect(throws: TogglAPIError.offline) {
            _ = try await client(transport).workspaces()
        }
    }

    @Test func unknownURLErrorClassifiesAsOther() {
        let classified = TogglAPIClient.classify(URLError(.badServerResponse))
        guard case .other = classified else {
            Issue.record("Expected .other, got \(classified)")
            return
        }
    }

    @Test func malformedBodyClassifiesAsDecoding() async {
        let transport = StubTransport(data: Data("not json".utf8))
        await #expect(throws: TogglAPIError.decoding("Failed to decode TogglMe")) {
            _ = try await client(transport).me()
        }
    }

    // MARK: Parsing

    @Test func parsesMe() async throws {
        let json = #"{"id":9000,"fullname":"Zhibang Jiang","email":"z@example.com","default_workspace_id":101,"api_token":"never-touch-this"}"#
        let transport = StubTransport(data: Data(json.utf8))
        let me = try await client(transport).me()
        #expect(me == TogglMe(id: 9000, fullname: "Zhibang Jiang", email: "z@example.com", defaultWorkspaceId: 101))
    }

    @Test func parsesWorkspacesAndClients() async throws {
        let workspacesJSON = #"[{"id":101,"name":"Freelance"},{"id":102,"name":"Side Projects"}]"#
        let workspaces = try await client(StubTransport(data: Data(workspacesJSON.utf8))).workspaces()
        #expect(workspaces.map(\.name) == ["Freelance", "Side Projects"])

        let clientsJSON = #"[{"id":7,"wid":101,"name":"Acme Corp","archived":false},{"id":8,"wid":101,"name":"Old Co","archived":true}]"#
        let clients = try await client(StubTransport(data: Data(clientsJSON.utf8))).clients(workspaceID: 101)
        #expect(clients.count == 2)
        #expect(clients[0].name == "Acme Corp")
        #expect(clients[1].archived == true)
    }

    @Test func parsesProjectsWithClientLink() async throws {
        let json = #"[{"id":31,"workspace_id":101,"client_id":7,"name":"Website","active":true},{"id":32,"workspace_id":101,"client_id":null,"name":"Internal","active":false}]"#
        let projects = try await client(StubTransport(data: Data(json.utf8))).projects(workspaceID: 101)
        #expect(projects[0].clientId == 7)
        #expect(projects[1].clientId == nil)
        #expect(projects[1].active == false)
    }

    @Test func parsesTimeEntriesAndPreservesRunningDurationRaw() async throws {
        let json = #"""
        [
          {"id":1,"workspace_id":101,"project_id":31,"start":"2026-07-14T09:00:00+00:00","stop":"2026-07-14T12:30:00Z","duration":12600,"description":"Design"},
          {"id":2,"workspace_id":101,"project_id":31,"start":"2026-07-14T15:00:00Z","stop":null,"duration":-1784127600,"description":null}
        ]
        """#
        let entries = try await client(StubTransport(data: Data(json.utf8)))
            .timeEntries(from: .distantPast, to: .distantFuture)
        #expect(entries.count == 2)
        #expect(entries[0].duration == 12600)
        // Running entry: negative duration and nil stop pass through untouched.
        #expect(entries[1].duration == -1784127600)
        #expect(entries[1].stop == nil)
    }

    @Test func timeEntriesQueryUsesISO8601Dates() async throws {
        let transport = StubTransport(data: Data("[]".utf8))
        let from = Date(timeIntervalSince1970: 1_782_000_000)
        let to = Date(timeIntervalSince1970: 1_784_678_400)
        _ = try await client(transport).timeEntries(from: from, to: to)
        let query = transport.lastRequest?.url?.query() ?? ""
        #expect(query.contains("start_date="))
        #expect(query.contains("end_date="))
        #expect(query.contains("Z"))
    }

    @Test func currentEntryNullBodyMeansNoRunningEntry() async throws {
        let transport = StubTransport(data: Data("null".utf8))
        let entry = try await client(transport).currentTimeEntry()
        #expect(entry == nil)
    }

    @Test func currentEntryParsesWhenRunning() async throws {
        let json = #"{"id":5,"workspace_id":101,"project_id":null,"start":"2026-07-14T15:00:00Z","stop":null,"duration":-1784127600,"description":"Live"}"#
        let entry = try await client(StubTransport(data: Data(json.utf8))).currentTimeEntry()
        #expect(entry?.id == 5)
        #expect(entry?.projectId == nil)
        #expect(entry?.duration == -1784127600)
    }
}

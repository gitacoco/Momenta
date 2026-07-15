import Foundation

/// Minimal transport abstraction so the API client is unit-testable without
/// touching the network.
protocol HTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TogglAPIError.other("Non-HTTP response")
        }
        return (data, http)
    }
}

/// Error taxonomy consumable by the UI layer. Every request failure is
/// classified into one of these cases.
enum TogglAPIError: Error, Equatable, LocalizedError {
    case unauthorized
    case rateLimited
    case offline
    case server(status: Int)
    case decoding(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Toggl rejected the API token. Check the token and reconnect."
        case .rateLimited:
            return "Toggl API quota reached (free plan: 30 requests/hour)."
        case .offline:
            return "You appear to be offline."
        case .server(let status):
            return "Toggl is having trouble (HTTP \(status)). Try again later."
        case .decoding:
            return "Unexpected response from Toggl."
        case .other(let message):
            return message
        }
    }
}

/// Read-only Toggl Track API v9 client. Requests run sequentially through the
/// caller; the client itself never fans out, keeping free-plan limits safe.
struct TogglAPIClient: Sendable {
    private let token: String
    private let transport: any HTTPTransport
    private let baseURL: URL

    init(
        token: String,
        transport: any HTTPTransport = URLSession.shared,
        baseURL: URL = URL(string: "https://api.track.toggl.com/api/v9")!
    ) {
        self.token = token
        self.transport = transport
        self.baseURL = baseURL
    }

    // MARK: Endpoints

    func me() async throws -> TogglMe {
        try await get("me")
    }

    func workspaces() async throws -> [TogglWorkspace] {
        try await get("workspaces")
    }

    func clients(workspaceID: Int) async throws -> [TogglClientDTO] {
        try await get("workspaces/\(workspaceID)/clients")
    }

    func projects(workspaceID: Int) async throws -> [TogglProjectDTO] {
        try await get("workspaces/\(workspaceID)/projects")
    }

    /// Time entries whose start falls inside [from, to). Dates are sent in
    /// UTC; callers over-fetch a little and filter by configured time zone.
    func timeEntries(from: Date, to: Date) async throws -> [TogglTimeEntryDTO] {
        try await get("me/time_entries", query: [
            URLQueryItem(name: "start_date", value: from.formatted(.iso8601)),
            URLQueryItem(name: "end_date", value: to.formatted(.iso8601)),
        ])
    }

    /// The currently running entry, or nil when none is running (Toggl
    /// returns a literal `null` body in that case).
    func currentTimeEntry() async throws -> TogglTimeEntryDTO? {
        let data = try await getData("me/time_entries/current")
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" {
            return nil
        }
        return try Self.decode(TogglTimeEntryDTO.self, from: data)
    }

    // MARK: Plumbing

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await getData(path, query: query)
        return try Self.decode(T.self, from: data)
    }

    private func getData(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty {
            components.queryItems = query
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(Self.basicAuthValue(token: token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.perform(request)
        } catch let error as TogglAPIError {
            throw error
        } catch let error as URLError {
            throw Self.classify(error)
        } catch {
            throw TogglAPIError.other(error.localizedDescription)
        }

        switch response.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw TogglAPIError.unauthorized
        case 402, 429:
            // Toggl signals the free plan's hourly request quota with 402
            // ("payment required") as well as the conventional 429.
            throw TogglAPIError.rateLimited
        case 500...599:
            throw TogglAPIError.server(status: response.statusCode)
        default:
            throw TogglAPIError.other("Unexpected HTTP \(response.statusCode) from \(path)")
        }
    }

    static func basicAuthValue(token: String) -> String {
        "Basic " + Data("\(token):api_token".utf8).base64EncodedString()
    }

    static func classify(_ error: URLError) -> TogglAPIError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed,
             .internationalRoamingOff:
            return .offline
        default:
            return .other(error.localizedDescription)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            // Toggl mixes "Z" / "+00:00" suffixes and sometimes fractional seconds.
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: string) {
                return date
            }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized date: \(string)"
            )
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            // Never include response bodies in the error: they could carry
            // account details. The type name is enough to debug.
            throw TogglAPIError.decoding("Failed to decode \(T.self)")
        }
    }
}

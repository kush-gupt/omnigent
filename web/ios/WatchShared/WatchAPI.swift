import Foundation

/// What the iPhone hands the watch: the signed-in server's API root and the cookies a browser
/// would send to it. The watch then calls the existing API directly over its own network.
struct WatchCredentials: Codable, Hashable, Sendable {
  static let contextKey = "credentials"

  let apiURL: URL
  let cookie: String
}

struct WatchPage<Element: Decodable & Sendable>: Decodable, Sendable {
  let data: [Element]
}

struct WatchProject: Decodable, Sendable {
  let id: String?
  let name: String
}

struct WatchSession: Decodable, Hashable, Identifiable, Sendable {
  let id: String
  let title: String?
  let agentId: String?
  let agentName: String?
  let harness: String?
  let hostId: String?
  let projectId: String?
  let workspace: String?
  var status: String
  var pendingElicitationsCount: Int?
  let updatedAt: TimeInterval?
  let viewerUnread: Bool?

  var name: String {
    let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard title.isEmpty else { return title }
    // An untitled session reads as its harness, the way the agent pickers name it.
    return agentName.map { HarnessStyle.name(WatchAgent(id: id, name: $0, harness: harness)) }
      ?? "Untitled session"
  }
  var approvals: Int { pendingElicitationsCount ?? 0 }
  var updated: Date? { updatedAt.map(Date.init(timeIntervalSince1970:)) }
  var isActive: Bool { status == "running" || status == "waiting" }
  var statusLabel: String {
    if approvals > 0 { return approvals == 1 ? "1 approval" : "\(approvals) approvals" }
    return status == "idle" ? "Ready" : status.capitalized
  }
}

/// A host from `GET /v1/hosts`, with the harnesses it reports as ready.
struct WatchHost: Decodable, Identifiable, Sendable {
  struct Ready: Decodable, Sendable {
    let value: Bool
    init(from decoder: Decoder) throws {
      value = (try? decoder.singleValueContainer().decode(Bool.self)) ?? false
    }
  }

  let hostId: String
  let name: String?
  let status: String?
  let configuredHarnesses: [String: Ready]?
  var id: String { hostId }

  func runs(_ agent: WatchAgent) -> Bool {
    agent.harness.flatMap { configuredHarnesses?[$0]?.value } ?? false
  }
}

struct WatchHostList: Decodable, Sendable {
  let hosts: [WatchHost]
}

struct WatchAgent: Decodable, Identifiable, Sendable {
  let id: String
  let name: String
  let harness: String?
}

struct WatchSessionGroup: Identifiable, Sendable {
  let title: String
  let symbol: String
  var projectId: String? = nil
  let sessions: [WatchSession]
  var id: String { symbol + title }
}

extension [WatchSession] {
  /// The web sidebar's layout: a section per project in display order, then other sessions.
  func grouped(projects: [WatchProject]) -> [WatchSessionGroup] {
    let projectIDs = Set(projects.compactMap(\.id))
    let byProject = projects.compactMap { project in
      project.id.map { id in
        WatchSessionGroup(
          title: project.name, symbol: "folder", projectId: id,
          sessions: filter { $0.projectId == id })
      }
    }
    let others = filter { !projectIDs.contains($0.projectId ?? "") }
    return (byProject + [WatchSessionGroup(title: "Sessions", symbol: "", sessions: others)])
      .filter { !$0.sessions.isEmpty }
  }
}

struct WatchSnapshot: Decodable, Sendable {
  struct TaskError: Decodable, Sendable { let message: String? }

  let status: String?
  let lastTaskError: TaskError?
  let pendingElicitations: [WatchElicitation]?
  let pendingInputs: [WatchItem]?
}

/// A committed item, a queued input (`pending_id`), or a streamed item: all share this shape.
struct WatchItem: Decodable, Sendable {
  struct Part: Decodable, Sendable { let text: String? }

  let id: String?
  let pendingId: String?
  let type: String?
  let role: String?
  let content: [Part]?
  let message: String?
  let isMeta: Bool?

  /// The visible text, without the `<system-reminder>` blocks Claude Code injects into user turns.
  var text: String {
    (content ?? []).compactMap(\.text).joined(separator: "\n")
      .replacing(#/<system-reminder>[\s\S]*?</system-reminder>/#, with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The chat bubble for a message or a failed turn; nil for tool calls and empty turns.
  var bubble: WatchMessage? {
    // Hidden durable context (skill instructions, wake notices) the web never shows.
    if isMeta == true { return nil }
    if type == "error", let id, let message {
      return WatchMessage(id: "error:" + id, isUser: false, text: message)
    }
    guard !text.isEmpty else { return nil }
    if let pendingId { return WatchMessage(id: "pending:" + pendingId, isUser: true, text: text) }
    guard let id, type == "message", role == "user" || role == "assistant" else { return nil }
    return WatchMessage(id: id, isUser: role == "user", text: text)
  }
}

struct WatchMessage: Hashable, Identifiable, Sendable {
  let id: String
  let isUser: Bool
  let text: String
  var isPending: Bool { id.hasPrefix("pending:") }
  var isError: Bool { id.hasPrefix("error:") }
}

struct WatchElicitation: Decodable, Identifiable, Sendable {
  struct Params: Decodable, Sendable {
    let mode: String?
    let message: String
    let contentPreview: String?
    let targetSessionId: String?
    let requestedSchema: Schema?
  }
  struct Schema: Decodable, Sendable { let properties: [String: AnyField]? }
  struct AnyField: Decodable, Sendable { init(from decoder: Decoder) {} }

  let elicitationId: String
  let params: Params
  var id: String { elicitationId }
  /// Plain yes/no prompts only; forms and URL flows need the phone.
  var isBinary: Bool {
    (params.mode ?? "form") == "form" && params.requestedSchema?.properties?.isEmpty != false
  }
}

struct WatchInfo: Decodable, Sendable {
  let dictationAvailable: Bool?
}

struct WatchAck: Decodable, Sendable {
  let denied: Bool?
  let reason: String?
}

struct WatchStreamEvent: Decodable, Equatable, Sendable {
  static let done = WatchStreamEvent(type: "[DONE]", delta: nil)

  let type: String
  let delta: String?
}

extension WatchStreamEvent {
  /// Decodes one `data:` line of the session SSE stream; nil for other lines and unknown JSON.
  init?(line: String) {
    guard line.hasPrefix("data:") else { return nil }
    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
    if payload == "[DONE]" {
      self = .done
    } else if let event = try? WatchClient.decoder.decode(Self.self, from: Data(payload.utf8)) {
      self = event
    } else {
      return nil
    }
  }
}

enum WatchError: LocalizedError, Equatable {
  case signedOut
  case status(Int)
  case denied(String)

  var errorDescription: String? {
    switch self {
    case .signedOut: "Open Omnigent on your iPhone to sign in again."
    case .status(let code): "The server returned HTTP \(code)."
    case .denied(let reason): reason
    }
  }
}

struct WatchClient: Sendable {
  static let decoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()
  private static let sliceKey = "X-Databricks-Omnigent-Slice-Key"
  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration)
  }()

  let credentials: WatchCredentials

  func get<Response: Decodable>(
    _ path: String, _ query: [String: String] = [:], host: String? = nil
  ) async throws -> Response {
    let data = try await send(request(path, query, host: host)) {
      try await Self.session.data(for: $0)
    }
    return try Self.decoder.decode(Response.self, from: data)
  }

  /// The `POST /v1/sessions/{id}/events` body for a plain-text user message.
  static func message(_ text: String) -> [String: Any] {
    [
      "type": "message",
      "data": ["role": "user", "content": [["type": "input_text", "text": text]]],
    ]
  }

  func post<Response: Decodable>(
    _ path: String, _ body: [String: Any], host: String?
  ) async throws -> Response {
    var request = request(path, host: host)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let data = try await send(request) { try await Self.session.data(for: $0) }
    return try Self.decoder.decode(Response.self, from: data)
  }

  func stream(_ path: String, host: String?) async throws -> some AsyncSequence<String, Error> {
    var request = request(path, host: host)
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    return try await send(request) { try await Self.session.bytes(for: $0) }.lines
  }

  func request(_ path: String, _ query: [String: String] = [:], host: String?) -> URLRequest {
    var url = credentials.apiURL.appending(path: path)
    url.append(queryItems: query.sorted { $0.key < $1.key }.map(URLQueryItem.init))
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
    request.setValue(
      credentials.cookie.isEmpty ? nil : credentials.cookie, forHTTPHeaderField: "Cookie")
    request.setValue(host, forHTTPHeaderField: Self.sliceKey)
    return request
  }

  private func send<Payload>(
    _ request: URLRequest, _ load: (URLRequest) async throws -> (Payload, URLResponse)
  ) async throws -> Payload {
    var request = request
    var (payload, response) = try await load(request)
    // A stale host key reaches a replica without the session's tunnel; retry keyless like the web,
    // only on that error (a stream's body can't be read here, and a GET is safe to repeat).
    let wrongReplica = (payload as? Data).map {
      String(decoding: $0, as: UTF8.self).contains("wrong_replica")
    }
    if (response as? HTTPURLResponse)?.statusCode == 400,
      request.value(forHTTPHeaderField: Self.sliceKey) != nil,
      wrongReplica ?? ((request.httpMethod ?? "GET") == "GET")
    {
      request.setValue(nil, forHTTPHeaderField: Self.sliceKey)
      (payload, response) = try await load(request)
    }
    switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
    case 200..<300: return payload
    case 401, 403: throw WatchError.signedOut
    case let code: throw WatchError.status(code)
    }
  }
}

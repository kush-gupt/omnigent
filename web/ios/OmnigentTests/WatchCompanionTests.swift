import XCTest

@testable import Omnigent

final class WatchCompanionTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000)

  @MainActor func testCredentialsSendOnlyCookiesTheAPIWouldReceive() throws {
    let cookies = [
      cookie("session", domain: "omnigent.example.com", path: "/"),
      cookie("parent", domain: ".example.com", path: "/omnigent"),
      cookie("other-host", domain: "other.example.com", path: "/"),
      cookie("other-path", domain: "omnigent.example.com", path: "/admin"),
      cookie("secure", domain: "omnigent.example.com", path: "/", secure: true),
      cookie("expired", domain: "omnigent.example.com", path: "/", expires: now),
    ]
    let http = try XCTUnwrap(
      WatchCredentials(
        serverURL: URL(string: "http://omnigent.example.com/omnigent/")!,
        cookies: cookies))
    XCTAssertEqual(http.apiURL.absoluteString, "http://omnigent.example.com/omnigent/v1")
    XCTAssertEqual(http.cookie, "session=1; parent=1")

    let https = try XCTUnwrap(
      WatchCredentials(
        serverURL: URL(string: "https://omnigent.example.com/omnigent?o=42&next=x")!,
        cookies: cookies))
    // A shared host's workspace selector survives; the rest of the page's query does not.
    XCTAssertEqual(https.apiURL.absoluteString, "https://omnigent.example.com/omnigent/v1?o=42")
    XCTAssertEqual(
      WatchClient(credentials: https).request("sessions", ["limit": "5"], host: nil).url?
        .absoluteString,
      "https://omnigent.example.com/omnigent/v1/sessions?o=42&limit=5")
    XCTAssertEqual(https.cookie, "session=1; parent=1; secure=1")
  }

  func testClientAddressesTheAPIWithCookieAndHostKey() {
    let client = WatchClient(
      credentials: WatchCredentials(
        apiURL: URL(string: "https://omnigent.example.com/v1")!, cookie: "session=1"))
    let request = client.request(
      "sessions/conv_1/items", ["order": "desc", "limit": "5"], host: "h1")
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://omnigent.example.com/v1/sessions/conv_1/items?limit=5&order=desc")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=1")
    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Databricks-Omnigent-Slice-Key"), "h1")
    XCTAssertNil(
      client.request("sessions", host: nil).value(
        forHTTPHeaderField: "X-Databricks-Omnigent-Slice-Key"))
  }

  func testSessionsGroupByProjectThenTheRest() throws {
    let json = """
      {"data": [
        {"id": "a", "status": "running", "pending_elicitations_count": 1},
        {"id": "b", "status": "running", "title": "  "},
        {"id": "c", "status": "idle", "project_id": "p1", "agent_name": "helper"},
        {"id": "n", "status": "idle", "agent_name": "claude-native-ui", "harness": "claude-native"},
        {"id": "d", "status": "failed", "project_id": "gone"},
        {"id": "e", "status": "waiting"}
      ]}
      """
    let sessions = try WatchClient.decoder.decode(
      WatchPage<WatchSession>.self, from: Data(json.utf8)
    ).data
    let groups = sessions.grouped(projects: [
      WatchProject(id: "p1", name: "Docs"), WatchProject(id: nil, name: "Legacy"),
    ])
    XCTAssertEqual(groups.map(\.title), ["Docs", "Sessions"])
    XCTAssertEqual(groups.map { $0.sessions.map(\.id) }, [["c"], ["a", "b", "n", "d", "e"]])
    XCTAssertEqual(
      sessions.map(\.statusLabel), ["1 approval", "Running", "Ready", "Ready", "Failed", "Waiting"])
    XCTAssertEqual(sessions[1].name, "Untitled session")
    XCTAssertEqual(sessions[2].name, "Helper")
    XCTAssertEqual(sessions[3].name, "Claude Code")
  }

  func testSnapshotDecodesMessagesQueuedInputsAndApprovals() throws {
    let json = """
      {"status": "running",
       "pending_inputs": [{"pending_id": "p1", "content": [{"type": "input_text", "text": "queued"}]}],
       "pending_elicitations": [
         {"elicitation_id": "e1", "params": {"mode": "form", "message": "Run it?",
          "requestedSchema": {"type": "object", "properties": {}}}},
         {"elicitation_id": "e2", "params": {"mode": "form", "message": "Pick",
          "requestedSchema": {"properties": {"choice": {"type": "string"}}}}},
         {"elicitation_id": "e3", "params": {"mode": "url", "message": "Sign in"}}
       ]}
      """
    let snapshot = try WatchClient.decoder.decode(WatchSnapshot.self, from: Data(json.utf8))
    XCTAssertEqual(
      snapshot.pendingInputs?.compactMap(\.bubble),
      [
        WatchMessage(id: "pending:p1", isUser: true, text: "queued")
      ])
    XCTAssertEqual(snapshot.pendingElicitations?.map(\.isBinary), [true, false, false])

    let items = """
      {"data": [
        {"id": "m2", "type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "**hi**"}]},
        {"id": "f1", "type": "function_call", "name": "shell"},
        {"id": "h1", "type": "message", "role": "user", "is_meta": true, "content": [{"type": "input_text", "text": "hidden"}]},
        {"id": "x1", "type": "error", "code": "workspace_missing", "message": "workspace gone"},
        {"id": "r1", "type": "message", "role": "user", "content": [{"type": "input_text", "text": "<system-reminder>\\nnote\\n</system-reminder>"}]},
        {"id": "r2", "type": "message", "role": "user", "content": [{"type": "input_text", "text": "<system-reminder>a</system-reminder>\\n ok"}]},
        {"id": "m1", "type": "message", "role": "user", "content": [{"type": "input_text", "text": " hello "}]}
      ]}
      """
    let page = try WatchClient.decoder.decode(WatchPage<WatchItem>.self, from: Data(items.utf8))
    XCTAssertEqual(
      page.data.compactMap(\.bubble),
      [
        WatchMessage(id: "m2", isUser: false, text: "**hi**"),
        WatchMessage(id: "error:x1", isUser: false, text: "workspace gone"),
        WatchMessage(id: "r2", isUser: true, text: "ok"),
        WatchMessage(id: "m1", isUser: true, text: "hello"),
      ])
  }

  func testHostsOfferOnlyHarnessesTheyReportReady() throws {
    let json = """
      {"hosts": [{"host_id": "h1", "name": "Laptop", "status": "online",
        "configured_harnesses": {"claude-native": true, "codex-native": "binary-missing", "pi": false}}]}
      """
    let host = try XCTUnwrap(
      WatchClient.decoder.decode(WatchHostList.self, from: Data(json.utf8)).hosts.first)
    let agents = ["claude-native", "codex-native", "pi", "unknown"].map {
      WatchAgent(id: $0, name: $0, harness: $0)
    }
    XCTAssertEqual(agents.filter(host.runs).map(\.id), ["claude-native"])
  }

  func testHarnessNamesAndIconsFollowTheWebPicker() {
    let agents = [
      ("claude-native-ui", "claude-native"), ("codex-native-ui", "codex-native"),
      ("opencode-native-ui", "opencode-native"), ("debby", "claude-sdk"), ("polly", "claude-sdk"),
      ("jcode", "jcode"),
    ].map { WatchAgent(id: $0.0, name: $0.0, harness: $0.1) }
    XCTAssertEqual(
      agents.map(HarnessStyle.name),
      ["Claude Code", "Codex", "OpenCode", "Debby", "Polly", "Jcode"])
    XCTAssertEqual(
      agents.map(HarnessStyle.iconName),
      [
        "harness-claude", "harness-codex", "harness-opencode", "harness-databricks",
        "harness-databricks", nil,
      ])
  }

  func testMarkdownKeepsBlocksTextDoesNotDraw() {
    let markdown = "# Title\n\nSome **bold** text.\n\n- one\n- two\n  - nested\n\n1. first"
    XCTAssertEqual(
      String(AttributedString(watchMarkdown: markdown).characters),
      "Title\n\nSome bold text.\n\n• one\n• two\n  • nested\n\n1. first")
  }

  func testStreamLinesDecodeEventsAndTheTerminator() {
    XCTAssertEqual(
      WatchStreamEvent(line: #"data: {"type":"response.output_text.delta","delta":"Hi"}"#)?.delta,
      "Hi")
    XCTAssertEqual(WatchStreamEvent(line: "data: [DONE]"), .done)
    XCTAssertNil(WatchStreamEvent(line: "event: session.status"))
    XCTAssertNil(WatchStreamEvent(line: "data: {not json"))
  }

  func testUserMessageMatchesTheEventsContract() {
    XCTAssertEqual(
      WatchClient.message("yes") as NSDictionary,
      [
        "type": "message",
        "data": ["role": "user", "content": [["type": "input_text", "text": "yes"]]],
      ])
  }

  private func cookie(
    _ name: String, domain: String, path: String, secure: Bool = false, expires: Date? = nil
  ) -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name, .value: "1", .domain: domain, .path: path,
    ]
    if secure { properties[.secure] = "TRUE" }
    if let expires { properties[.expires] = expires }
    return HTTPCookie(properties: properties)!
  }
}

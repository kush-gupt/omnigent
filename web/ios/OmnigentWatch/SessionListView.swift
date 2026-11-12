import SwiftUI

struct SessionListView: View {
  enum Route: Hashable {
    case new(projectId: String?)
    case session(WatchSession)
  }

  let client: WatchClient
  @State private var sessions: [WatchSession]?
  @State private var projects: [WatchProject] = []
  @State private var groups: [WatchSessionGroup] = []
  @State private var path: [Route] = []
  @State private var error: String?

  var body: some View {
    NavigationStack(path: $path) {
      List {
        if let error { ErrorLabel(error) }
        NavigationLink(value: Route.new(projectId: nil)) {
          Label("New session", systemImage: "plus.circle")
        }
        .glassRow(tint: .brand.opacity(0.35))
        ForEach(groups) { group in
          Section {
            // Like the sidebar's per-project "+": a session filed under this project.
            if let projectId = group.projectId {
              NavigationLink(value: Route.new(projectId: projectId)) {
                Label("New session", systemImage: "plus").foregroundStyle(.secondary)
              }
              .glassRow()
            }
            ForEach(group.sessions) { session in
              NavigationLink(value: Route.session(session)) { SessionRow(session: session) }
                .glassRow()
            }
          } header: {
            Group {
              if group.symbol.isEmpty {
                Text(group.title)
              } else {
                Label(group.title, systemImage: group.symbol)
              }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          }
        }
      }
      .overlay {
        if sessions?.isEmpty == true {
          ContentUnavailableView("No sessions", systemImage: "bubble.left.and.bubble.right")
        }
      }
      .toolbar { LoadingIndicator(isLoading: sessions == nil && error == nil) }
      .navigationTitle("Omnigent")
      .navigationDestination(for: Route.self) { route in
        switch route {
        case .new(let projectId):
          NewSessionView(
            client: client, sessions: sessions ?? [], projects: projects, projectId: projectId
          ) { path = [.session($0)] }
        case .session(let session):
          SessionView(session: session, client: client)
        }
      }
      .containerBackground(for: .navigation) { BrandBackground() }
      .refreshable { await load() }
      .task {
        while !Task.isCancelled {
          await load()
          try? await Task.sleep(for: .seconds(30))
        }
      }
    }
  }

  private func load() async {
    do {
      let query = ["order": "desc", "sort_by": "updated_at", "limit": "25", "visibility": "all"]
      async let page: WatchPage<WatchSession> = client.get("sessions", query)
      projects = (try? await client.get("sessions/projects")) ?? []
      let loaded = try await page.data
      (sessions, groups) = (loaded, loaded.grouped(projects: projects))
      error = nil
    } catch is CancellationError {
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// An empty session with the web composer's choices: project, host, and harness. Defaults and
/// the workspace come from the most recent matching session; the server fills the rest.
private struct NewSessionView: View {
  enum Field: Identifiable {
    case project, host, harness
    var id: Self { self }
  }

  let client: WatchClient
  let sessions: [WatchSession]
  let projects: [WatchProject]
  @State var projectId: String?
  let open: (WatchSession) -> Void
  @State private var hosts: [WatchHost] = []
  @State private var agents: [WatchAgent] = []
  @State private var hostId: String?
  @State private var agentId: String?
  @State private var picking: Field?
  @State private var isStarting = false
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  init(
    client: WatchClient, sessions: [WatchSession], projects: [WatchProject], projectId: String?,
    open: @escaping (WatchSession) -> Void
  ) {
    (self.client, self.sessions, self.projects, self.open) = (client, sessions, projects, open)
    _projectId = State(initialValue: projectId)
  }

  /// The latest session on the chosen host, preferring one in the chosen project.
  private var recent: WatchSession? {
    let onHost = sessions.filter { $0.hostId == hostId && $0.workspace != nil }
    return onHost.first { $0.projectId == projectId } ?? onHost.first
  }
  private var host: WatchHost? { hosts.first { $0.hostId == hostId } }
  private var harnesses: [WatchAgent] { agents.filter { host?.runs($0) ?? false } }

  var body: some View {
    List {
      if let error { ErrorLabel(error) }
      let agent = agents.first { $0.id == agentId }
      choice(.project, "Project", projects.first { $0.id == projectId }?.name ?? "None")
      choice(.host, "Host", host.map { $0.name ?? $0.hostId } ?? "None online")
      choice(
        .harness, "Harness", agent.map(HarnessStyle.name) ?? "None ready", HarnessStyle.icon(agent))
      if hostId != nil && recent == nil {
        Text("Start a session on this host from iPhone first to pick its folder.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("New session")
    .toolbar { LoadingIndicator(isLoading: isStarting || hosts.isEmpty && error == nil) }
    .navigationBarBackButtonHidden()
    .containerBackground(for: .navigation) { BrandBackground() }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      FloatingBar {
        Composer(
          client: client, prompt: "New session",
          disabled: isStarting || agentId == nil || recent == nil
        ) { text in
          Task { await start(text) }
        } leading: {
          Button("Back", systemImage: "chevron.backward") { dismiss() }
            .buttonStyle(CircleButtonStyle())
        }
      }
    }
    .sheet(item: $picking) { field in
      List {
        switch field {
        case .project:
          option("None", projectId == nil) { projectId = nil }
          ForEach(projects.filter { $0.id != nil }, id: \.id) { project in
            option(project.name, project.id == projectId) { projectId = project.id }
          }
        case .host:
          ForEach(hosts.filter { $0.status == "online" }) { host in
            option(host.name ?? host.hostId, host.hostId == hostId) { pick(host: host.hostId) }
          }
        case .harness:
          ForEach(harnesses) { agent in
            option(HarnessStyle.name(agent), agent.id == agentId, HarnessStyle.icon(agent)) {
              agentId = agent.id
            }
          }
        }
      }
    }
    .task { await load() }
  }

  private func choice(_ field: Field, _ title: String, _ value: String, _ icon: Image? = nil)
    -> some View
  {
    Button {
      picking = field
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.caption2).foregroundStyle(.secondary)
        HStack(spacing: 6) {
          icon?.resizable().scaledToFit().frame(width: 18, height: 18)
          Text(value).lineLimit(1)
        }
      }
    }
    .glassRow()
  }

  private func option(
    _ title: String, _ selected: Bool, _ icon: Image? = nil, _ choose: @escaping () -> Void
  ) -> some View {
    Button {
      choose()
      picking = nil
    } label: {
      HStack(spacing: 8) {
        icon?.resizable().scaledToFit().frame(width: 20, height: 20)
        Text(title).lineLimit(1)
        Spacer(minLength: 4)
        if selected { Image(systemName: "checkmark").foregroundStyle(Color.brand) }
      }
    }
  }

  private func load() async {
    do {
      async let hostList: WatchHostList = client.get("hosts")
      async let agentList: WatchPage<WatchAgent> = client.get("agents")
      (hosts, agents) = try await (hostList.hosts, agentList.data)
      // The latest matching session's host when it's online, like the picker offers.
      let online = Set(hosts.filter { $0.status == "online" }.map(\.hostId))
      let latest =
        sessions.first { $0.projectId == projectId && online.contains($0.hostId ?? "") }
        ?? sessions.first { online.contains($0.hostId ?? "") }
      pick(host: latest?.hostId ?? hosts.first { $0.status == "online" }?.hostId)
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Choosing a host keeps the harness when it runs there, else the latest one used there.
  private func pick(host chosen: String?) {
    hostId = chosen
    guard !harnesses.contains(where: { $0.id == agentId }) else { return }
    agentId = harnesses.first { $0.id == recent?.agentId }?.id ?? harnesses.first?.id
  }

  private func start(_ text: String) async {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let agentId, let hostId, let workspace = recent?.workspace, !text.isEmpty else { return }
    isStarting = true
    defer { isStarting = false }
    var body: [String: Any] = ["agent_id": agentId, "host_id": hostId, "workspace": workspace]
    body["project_id"] = projectId
    do {
      // Keyed by the chosen host, as the web keys creates, so the request finds its replica.
      let session: WatchSession = try await client.post("sessions", body, host: hostId)
      // Open the new session even if its first message fails, so a retry doesn't create another.
      defer { open(session) }
      let _: WatchAck = try await client.post(
        "sessions/\(session.id)/events", WatchClient.message(text), host: session.hostId)
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// A sidebar row: the title, with the web's trailing state marker and nothing when idle.
private struct SessionRow: View {
  let session: WatchSession

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(session.name).lineLimit(1)
        Spacer(minLength: 4)
        if session.approvals == 0 { SessionMarker(session: session) }
      }
      if session.approvals > 0 {
        Text("Needs response")
          .font(.caption2.weight(.medium))
          .foregroundStyle(Color.brand)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.brand.opacity(0.15), in: .capsule)
      }
    }
  }
}

/// `SessionStateBadge`'s markers: a spinner while running, an alert on failure, a dot when unread.
struct SessionMarker: View {
  let session: WatchSession

  var body: some View {
    if session.isActive {
      Image(systemName: "progress.indicator")
        .foregroundStyle(.secondary)
        .symbolEffect(.variableColor.iterative)
        .accessibilityLabel("Session running")
    } else if session.status == "failed" {
      Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        .accessibilityLabel("Latest message is an error")
    } else if session.viewerUnread == true {
      Circle().fill(Color.brand).frame(width: 6, height: 6).accessibilityLabel("New messages")
    }
  }
}

extension View {
  /// A list row on an interactive Liquid Glass platter, like the iOS app's floating controls.
  func glassRow(tint: Color? = nil) -> some View {
    padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: 22))
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
  }
}

struct ErrorLabel: View {
  let message: String
  init(_ message: String) { self.message = message }

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle.fill")
      .font(.footnote)
      .foregroundStyle(.red)
  }
}

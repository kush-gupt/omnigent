import SwiftUI
import WatchKit

struct SessionView: View {
  let client: WatchClient
  @State private var conversation: Conversation
  @State private var position = ScrollPosition(edge: .bottom)
  @State private var chrome = Chrome.composer
  @Environment(\.dismiss) private var dismiss

  /// What floats at the bottom: controls at the latest message, a jump back while scrolling
  /// toward it, and nothing while reading back through the transcript.
  enum Chrome { case composer, jump, hidden }

  init(session: WatchSession, client: WatchClient) {
    self.client = client
    _conversation = State(initialValue: Conversation(session: session, client: client))
  }

  var body: some View {
    let session = conversation.session
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        if let error = conversation.error { ErrorLabel(error) }
        ForEach(conversation.messages) { MessageBubble(message: $0) }
        if !conversation.isLoading && conversation.messages.isEmpty {
          Text("No messages yet").font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(conversation.approvals) { ApprovalCard(approval: $0, conversation: conversation) }
      }
    }
    .scrollPosition($position)
    .defaultScrollAnchor(.bottom)
    .onScrollGeometryChange(for: CGFloat.self) {
      $0.contentSize.height - $0.visibleRect.maxY
    } action: { previous, distance in
      chrome = distance < 30 ? .composer : distance < previous ? .jump : .hidden
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      FloatingBar(visible: chrome != .hidden) {
        ZStack {
          Composer(
            client: client, prompt: "Reply", disabled: conversation.isBusy || chrome != .composer
          ) { text in
            Task { await conversation.send(text) }
          } leading: {
            Button("Back", systemImage: "chevron.backward") { dismiss() }
              .buttonStyle(CircleButtonStyle())
          }
          .opacity(chrome == .composer ? 1 : 0)
          if chrome == .jump {
            Button("Latest", systemImage: "chevron.down") {
              withAnimation { position.scrollTo(edge: .bottom) }
            }
            .buttonStyle(CircleButtonStyle(tint: .brand))
            .transition(.scale.combined(with: .opacity))
          }
        }
      }
    }
    .animation(.snappy, value: chrome)
    .environment(\.openURL, OpenURLAction { _ in .discarded })
    .navigationTitle(session.name)
    .navigationBarBackButtonHidden()
    .containerBackground(for: .navigation) { BrandBackground() }
    .toolbar { LoadingIndicator(isLoading: conversation.isLoading || conversation.isBusy) }
    .task { await conversation.load() }
    .task { await conversation.stream() }
  }
}

/// Dictation in the middle as the primary action, the keyboard on the right, and `leading`
/// (where to start, or the session's live control) on the left.
struct Composer<Leading: View>: View {
  let client: WatchClient
  let prompt: String
  let disabled: Bool
  let submit: (String) -> Void
  @ViewBuilder let leading: Leading
  @State private var dictation: ServerDictation?

  var body: some View {
    VStack(spacing: 6) {
      if let dictation {
        Text(dictation.text.isEmpty ? "Listening…" : dictation.text)
          .font(.footnote)
          .lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      // One container, so the buttons' glass blends and morphs like the iOS app's controls.
      GlassEffectContainer {
        HStack {
          leading
          Spacer()
          // A stop square while listening; back to the mic once the text is sent.
          Button(
            dictation == nil ? "Dictate" : "Finish",
            systemImage: dictation == nil ? "mic.fill" : "stop.fill"
          ) { dictate() }
          .buttonStyle(CircleButtonStyle(tint: .brand, size: 52))
          .offset(y: 6)
          Spacer()
          TextFieldLink(prompt: Text(prompt)) {
            Label("Type", systemImage: "keyboard")
          } onSubmit: {
            submit($0)
          }
          .buttonStyle(CircleButtonStyle())
        }
      }
    }
    .disabled(disabled)
  }

  /// Like the web composer: the server transcribes when it can, otherwise the system does.
  private func dictate() {
    if let dictation { return dictation.finish() }
    // Claimed before the capability check, so a second tap can't start a second take.
    let session = ServerDictation()
    dictation = session
    Task {
      defer { dictation = nil }
      let info: WatchInfo? = try? await client.get("info")
      guard info?.dictationAvailable == true else { return systemDictation() }
      do {
        try await session.start(client)
        let text = session.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { submit(text) }
      } catch {
        // Fall back only when the server never took the audio; a failed take just ends.
        if !session.isRecording { systemDictation() }
      }
    }
  }

  private func systemDictation() {
    // Plain mode with no suggestions asks the system to open straight to dictation.
    WKApplication.shared().visibleInterfaceController?.presentTextInputController(
      withSuggestions: nil, allowedInputMode: .plain
    ) { results in
      if let text = results?.first as? String { submit(text) }
    }
  }
}

/// A small spinner in the top-left corner while the screen loads or sends.
struct LoadingIndicator: ToolbarContent {
  let isLoading: Bool

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      if isLoading { ProgressView().controlSize(.small) }
    }
  }
}

/// Bottom controls over a fade to the canvas, so text dims away beneath them instead of colliding.
struct FloatingBar<Content: View>: View {
  var visible = true
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(.horizontal, 4)
      .padding(.top, 22)
      .frame(maxWidth: .infinity)
      // Sit in the rounded bottom corners, as system bottom-bar buttons do.
      .padding(.bottom, -18)
      .background {
        LinearGradient(
          stops: [
            .init(color: .canvas.opacity(0), location: 0),
            .init(color: .canvas.opacity(0.9), location: 0.4), .init(color: .canvas, location: 1),
          ], startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
      }
      .opacity(visible ? 1 : 0)
  }
}

/// A 44 pt glass disc showing the label's icon; its title stays the accessibility label.
struct CircleButtonStyle: ButtonStyle {
  var tint: Color = .white.opacity(0.15)
  var size: CGFloat = 44

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(.iconOnly)
      .font(.system(size: size * 0.4, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: size, height: size)
      .glassEffect(.regular.tint(tint).interactive(), in: .circle)
      .scaleEffect(configuration.isPressed ? 0.92 : 1)
  }
}

private struct ApprovalCard: View {
  let approval: WatchElicitation
  let conversation: SessionView.Conversation

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Needs response").font(.caption2.weight(.semibold)).foregroundStyle(Color.brand)
      Text(approval.params.message).font(.subheadline.weight(.medium))
      if let preview = approval.params.contentPreview, !preview.isEmpty {
        Text(preview)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(6)
          .padding(6)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.black.opacity(0.35), in: .rect(cornerRadius: 10))
      }
      if approval.isBinary {
        HStack {
          button("Decline", "xmark", .white.opacity(0.2), accept: false)
          button("Approve", "checkmark", .brand, accept: true)
        }
        .buttonStyle(.glassProminent)
        .disabled(conversation.isBusy)
      } else {
        Label("Open on iPhone", systemImage: "iphone").font(.caption2).foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .glassEffect(.regular.tint(.brand.opacity(0.25)), in: .rect(cornerRadius: 22))
  }

  private func button(_ title: String, _ symbol: String, _ tint: Color, accept: Bool) -> some View {
    Button {
      Task { await conversation.resolve(approval, accept: accept) }
    } label: {
      Label(title, systemImage: symbol).labelStyle(.iconOnly).frame(maxWidth: .infinity)
    }
    .tint(tint)
  }
}

private struct MessageBubble: View {
  let message: WatchMessage

  var body: some View {
    HStack(alignment: .lastTextBaseline, spacing: 4) {
      Text(AttributedString(watchMarkdown: message.text))
      if message.isError {
        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
      } else if message.id == "live" {
        Image(systemName: "ellipsis").symbolEffect(.variableColor.iterative.dimInactiveLayers)
      } else if message.isPending {
        Image(systemName: "clock").font(.caption2)
      }
    }
    .font(.footnote)
    .foregroundStyle(message.isError ? .red : .primary)
    // The web chat: your messages in a glass bubble, the agent's as plain text.
    .padding(.horizontal, message.isUser ? 10 : 0)
    .padding(.vertical, message.isUser ? 7 : 0)
    .glassEffect(message.isUser ? .regular : .identity, in: .rect(cornerRadius: 16))
    .opacity(message.isPending ? 0.65 : 1)
    .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    .padding(message.isUser ? .leading : .trailing, 14)
  }
}

extension SessionView {
  /// One session's transcript: snapshot reads for committed state, the SSE stream for live text.
  @MainActor @Observable
  final class Conversation {
    private(set) var session: WatchSession
    private let client: WatchClient
    private(set) var approvals: [WatchElicitation] = []
    private(set) var isLoading = true
    private(set) var isBusy = false
    var error: String?
    private var committed: [WatchMessage] = []
    private var queued: [WatchMessage] = []
    private var sending: WatchMessage?
    private var live = ""
    private var clearsLive = false
    private var reload: Task<Void, Never>?

    init(session: WatchSession, client: WatchClient) {
      self.session = session
      self.client = client
    }

    var messages: [WatchMessage] {
      let streaming = live.isEmpty ? nil : WatchMessage(id: "live", isUser: false, text: live)
      return Array(committed.suffix(12)) + queued + [sending, streaming].compactMap { $0 }
    }

    func load() async {
      let path = "sessions/\(session.id)"
      let snapshotQuery = [
        "include_items": "false", "include_liveness": "false", "include_usage": "false",
      ]
      do {
        async let snapshot: WatchSnapshot = client.get(path, snapshotQuery, host: session.hostId)
        async let items: WatchPage<WatchItem> = client.get(
          path + "/items", ["order": "desc", "limit": "30"], host: session.hostId)
        let (state, page) = try await (snapshot, items)
        guard !Task.isCancelled else { return }
        committed = page.data.reversed().compactMap(\.bubble)
        // A native harness records the message before its pending copy clears; show it once.
        let recent = Set(committed.suffix(6).filter(\.isUser).map(\.text))
        queued = (state.pendingInputs ?? []).compactMap(\.bubble).filter {
          !recent.contains($0.text)
        }
        approvals = state.pendingElicitations ?? []
        session.status = state.status ?? session.status
        session.pendingElicitationsCount = approvals.count
        if clearsLive { (live, clearsLive) = ("", false) }
        error = state.status == "failed" ? state.lastTaskError?.message ?? "Session failed." : nil
      } catch is CancellationError {
      } catch let failure as URLError where failure.code == .cancelled {
      } catch {
        self.error = error.localizedDescription
      }
      isLoading = false
    }

    /// Follows the live stream, reconciling from the snapshot after every drop with backoff.
    func stream() async {
      var attempt = 0
      while !Task.isCancelled {
        do {
          for try await line in try await client.stream(
            "sessions/\(session.id)/stream", host: session.hostId)
          {
            guard let event = WatchStreamEvent(line: line) else { continue }
            if event == .done { break }
            attempt = 0
            handle(event)
          }
        } catch WatchError.signedOut {
          error = WatchError.signedOut.localizedDescription
          return
        } catch {}
        live = ""
        await load()
        attempt += 1
        try? await Task.sleep(for: .seconds(1 << min(attempt, 5)))
      }
    }

    func send(_ text: String) async {
      let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      sending = WatchMessage(id: "pending:local", isUser: true, text: text)
      await perform {
        let ack: WatchAck = try await self.client.post(
          "sessions/\(self.session.id)/events", WatchClient.message(text), host: self.session.hostId
        )
        if ack.denied == true {
          throw WatchError.denied(ack.reason ?? "The server denied this message.")
        }
      }
      sending = nil
    }

    func resolve(_ approval: WatchElicitation, accept: Bool) async {
      let target = approval.params.targetSessionId ?? session.id
      await perform {
        let _: WatchAck = try await self.client.post(
          "sessions/\(target)/elicitations/\(approval.id)/resolve",
          ["action": accept ? "accept" : "decline"], host: self.session.hostId)
        self.approvals.removeAll { $0.id == approval.id }
      }
    }

    private func perform(_ work: () async throws -> Void) async {
      isBusy = true
      defer { isBusy = false }
      do {
        try await work()
        await load()
      } catch {
        self.error = error.localizedDescription
      }
    }

    private func handle(_ event: WatchStreamEvent) {
      switch event.type {
      case "response.output_text.delta":
        live += event.delta ?? ""
      case "response.output_item.done", "response.completed", "response.failed",
        "response.incomplete", "response.cancelled", "response.error":
        refresh(clearingLive: true)
      case "session.status", "session.input.consumed", "response.elicitation_request",
        "response.elicitation_resolved":
        refresh()
      default:
        break
      }
    }

    /// Coalesces bursts of stream events into the latest snapshot read.
    private func refresh(clearingLive: Bool = false) {
      clearsLive = clearsLive || clearingLive
      reload?.cancel()
      reload = Task { await load() }
    }
  }
}

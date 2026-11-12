import AVFoundation
import Foundation

/// The web composer's server dictation on the watch: the mic streams 16 kHz mono s16le PCM to
/// `WS /v1/dictation/stream` and the server answers with partial and final text.
@MainActor @Observable
final class ServerDictation {
  private(set) var text = ""
  private(set) var isRecording = false
  private var finals = ""
  private var stream: MicStream?

  /// Listens until `finish()`; throws when the server or microphone can't take the stream.
  func start(_ client: WatchClient) async throws {
    guard await AVAudioApplication.requestRecordPermission() else {
      throw WatchError.denied("Allow microphone access to dictate.")
    }
    var request = client.request("dictation/stream", host: nil)
    let http = request.url!.absoluteString
    request.url = URL(
      string: http.hasPrefix("https") ? "wss" + http.dropFirst(5) : "ws" + http.dropFirst(4))
    let socket = URLSession.shared.webSocketTask(with: request)
    socket.resume()
    let mic = MicStream(socket: socket)
    stream = mic
    (text, finals) = ("", "")
    defer {
      mic.stop()
      socket.cancel()
    }
    while case .string(let frame) = try await socket.receive() {
      let event = try JSONDecoder().decode(Event.self, from: Data(frame.utf8))
      switch event.type {
      case "ready":
        try mic.start()
        isRecording = true
      case "partial": text = finals + (event.text ?? "")
      case "final", "stopped":
        finals += (event.text ?? "") + " "
        text = finals
      default: throw WatchError.denied(event.message ?? "Dictation failed.")
      }
      if event.type == "stopped" { break }
    }
  }

  /// Flushes the tail utterance; `start` returns once the server sends it.
  func finish() {
    stream?.finish()
  }

  private struct Event: Decodable {
    let type: String
    let text: String?
    let message: String?
  }
}

/// Microphone capture converted to the stream's PCM format, off the main actor.
private final class MicStream: @unchecked Sendable {
  private let socket: URLSessionWebSocketTask
  private let engine = AVAudioEngine()

  init(socket: URLSessionWebSocketTask) { self.socket = socket }

  func start() throws {
    try AVAudioSession.sharedInstance().setCategory(.record)
    try AVAudioSession.sharedInstance().setActive(true)
    let input = engine.inputNode.outputFormat(forBus: 0)
    let output = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let converter = AVAudioConverter(from: input, to: output)!
    let socket = socket
    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: input) { buffer, _ in
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / input.sampleRate) + 1
      guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
      var consumed = false
      converter.convert(to: pcm, error: nil) { _, status in
        status.pointee = consumed ? .noDataNow : .haveData
        defer { consumed = true }
        return consumed ? nil : buffer
      }
      guard let samples = pcm.int16ChannelData?[0], pcm.frameLength > 0 else { return }
      socket.send(.data(Data(bytes: samples, count: Int(pcm.frameLength) * 2))) { _ in }
    }
    try engine.start()
  }

  func finish() {
    stop()
    socket.send(.string(#"{"type":"stop"}"#)) { _ in }
  }

  func stop() {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
  }
}

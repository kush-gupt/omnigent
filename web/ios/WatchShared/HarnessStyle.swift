import SwiftUI

/// The web's harness presentation: display names from `lib/nativeCodingAgents.ts` and the icons
/// `ComposerAgentIcon` picks, exported into `Harnesses.xcassets`.
enum HarnessStyle {
  private static let names = [
    "claude-native": "Claude Code", "codex-native": "Codex", "opencode-native": "OpenCode",
    "devin-native": "Devin", "cursor-native": "Cursor", "pi-native": "Pi", "kiro-native": "Kiro",
    "antigravity-native": "Antigravity", "goose-native": "Goose", "qwen-native": "Qwen Code",
    "kimi-native": "Kimi", "hermes-native": "Hermes",
  ]
  private static let icons = [
    "codex", "claude", "cursor", "hermes", "kiro", "goose", "devin", "kimi", "antigravity",
    "opencode",
  ]

  /// Native wrappers by their harness's name, other agents by their own capitalized name.
  static func name(_ agent: WatchAgent) -> String {
    agent.harness.flatMap { names[$0] } ?? agent.name.prefix(1).uppercased()
      + agent.name.dropFirst()
  }

  /// The asset `ComposerAgentIcon` would pick; nil means the generic glyph.
  static func iconName(_ agent: WatchAgent?) -> String? {
    if agent?.name == "polly" || agent?.name == "debby" { return "harness-databricks" }
    guard let harness = agent?.harness else { return nil }
    if harness == "pi" || harness == "pi-native" { return "harness-pi" }
    return icons.first(where: harness.contains).map { "harness-" + $0 }
  }

  static func icon(_ agent: WatchAgent?) -> Image {
    iconName(agent).map { Image($0) } ?? Image(systemName: "cpu")
  }
}

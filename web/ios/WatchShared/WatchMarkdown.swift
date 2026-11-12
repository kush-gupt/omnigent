import SwiftUI

extension AttributedString {
  /// Apple's full Markdown parse, plus the block structure SwiftUI's `Text` doesn't draw: larger
  /// bold headings, list markers, monospaced code blocks, and breaks between blocks.
  init(watchMarkdown text: String) {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
    guard let parsed = try? AttributedString(markdown: text, options: options) else {
      self.init(text)
      return
    }
    self.init()
    var block: Int?
    var lastList: Int?
    for run in parsed.runs {
      var piece = AttributedString(parsed[run.range])
      let kinds = run.presentationIntent?.components.map(\.kind) ?? []
      let identity = run.presentationIntent?.components.first?.identity
      // Items of one list (nested ones included) stay on consecutive lines.
      let list = run.presentationIntent?.components
        .last { $0.kind == .unorderedList || $0.kind == .orderedList }?.identity
      if identity != block {
        let item = kinds.lazy.compactMap { kind -> Int? in
          if case .listItem(let ordinal) = kind { ordinal } else { nil }
        }.first
        let cell = kinds.lazy.compactMap { kind -> Int? in
          if case .tableCell(let column) = kind { column } else { nil }
        }.first
        if block != nil {
          self += AttributedString(
            (cell ?? 0) > 0 ? " · " : list != nil && list == lastList ? "\n" : "\n\n")
        }
        if let item {
          let depth = kinds.filter { $0 == .unorderedList || $0 == .orderedList }.count - 1
          let ordered = kinds.first { $0 == .unorderedList || $0 == .orderedList } == .orderedList
          self += AttributedString(
            String(repeating: "  ", count: max(depth, 0)) + (ordered ? "\(item). " : "• "))
        }
        (block, lastList) = (identity, list)
      }
      for kind in kinds {
        if case .header(let level) = kind { piece.font = level == 1 ? .title3.bold() : .headline }
        if case .codeBlock = kind { piece.font = .footnote.monospaced() }
      }
      self += piece
    }
  }
}

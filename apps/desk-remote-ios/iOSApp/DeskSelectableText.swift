import SwiftUI
import UIKit

/// Read-only text where any part can be selected and copied. On iOS, SwiftUI's
/// `.textSelection(.enabled)` only offers copying the whole text (reported on the phone 10/27),
/// so this is a non-editable, non-scrolling UITextView sized to its text.
struct DeskSelectableText: UIViewRepresentable {
    let text: AttributedString
    var style: UIFont.TextStyle = .body
    var monospaced = false

    init(_ text: AttributedString, style: UIFont.TextStyle = .body, monospaced: Bool = false) {
        self.text = text
        self.style = style
        self.monospaced = monospaced
    }

    init(_ plain: String, style: UIFont.TextStyle = .body, monospaced: Bool = false) {
        self.init(AttributedString(plain), style: style, monospaced: monospaced)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let rendered = Self.render(text, style: style, monospaced: monospaced)
        if !(view.attributedText?.isEqual(to: rendered) ?? false) {
            view.attributedText = rendered
        }
    }

    /// As wide as the text needs (short messages keep a short bubble), never wider than offered.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let offered = proposal.width ?? .greatestFiniteMagnitude
        let width = offered.isFinite && offered > 0 ? offered : 10_000
        let box = (uiView.attributedText ?? NSAttributedString()).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return CGSize(width: min(width, ceil(box.width)), height: ceil(box.height))
    }

    /// Inline Markdown (bold, italic, code, links, strikethrough) in the text style's font.
    static func render(_ text: AttributedString, style: UIFont.TextStyle, monospaced: Bool) -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: style)
        let plain = monospaced ? UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular) : base
        let out = NSMutableAttributedString()
        for run in text.runs {
            var font = plain
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.label]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: base.pointSize * 0.95, weight: .regular)
                    attributes[.backgroundColor] = UIColor.tertiarySystemFill
                }
                var traits = font.fontDescriptor.symbolicTraits
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                    font = UIFont(descriptor: descriptor, size: 0)
                }
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            if let link = run.link {
                attributes[.link] = link
            }
            attributes[.font] = font
            out.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        return out
    }
}

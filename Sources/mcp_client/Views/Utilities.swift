import SwiftUI
import AppKit

// The pieces that render text — the code/prose surface, its highlighters, its
// sizing rules — live in TextSurface.swift and TextHighlight.swift; the
// announced-icon machinery in Icons.swift. What is left here is the rest of
// the shared furniture: clipboard, palette, the draggable sash, the flow
// layout, the grouping card, schema examples.

// MARK: - Clipboard

enum Clip {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Byte sizes
//
// The one way this app says how big something was. The counts come from the
// transport (bytes written, bytes read — see `TranscriptEntry.bytes` and
// `CallResult.wireBytes`), never from measuring the text on screen: the printed
// body is pretty-printed, and a size that describes the formatting instead of
// the wire would be a lie with a number on it.
//
// 1024 steps, one decimal past a kilobyte, plain ASCII units: `940 B`,
// `12.4 KB`, `3.1 MB`. Compact enough for a log row, exact under the tooltip.

enum ByteSize {
    private static let kb = 1_024
    private static let mb = 1_048_576
    private static let gb = 1_073_741_824

    static func label(_ count: Int) -> String {
        let b = Double(count)
        if count < kb { return "\(count) B" }
        if count < mb { return String(format: "%.1f KB", b / Double(kb)) }
        if count < gb { return String(format: "%.1f MB", b / Double(mb)) }
        return String(format: "%.2f GB", b / Double(gb))
    }

    /// The tooltip under a compact label: the count itself, grouped so a
    /// seven-digit one is readable at a glance.
    static func exact(_ count: Int) -> String {
        let grouped = groupedDigits(count)
        return "\(grouped) byte\(count == 1 ? "" : "s")"
    }

    private static func groupedDigits(_ n: Int) -> String {
        let digits = String(n)
        guard digits.count > 3 else { return digits }
        var out = ""
        for (offset, ch) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return String(out.reversed())
    }
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Catppuccin palette (Frappé for light, Mocha for dark)
//
// The SwiftUI colours for labels, chips and the sash. The text surfaces use the
// AppKit mirror of the same six colours (CodePalette in TextHighlight.swift),
// dynamic so a light/dark flip is free.

enum Catppuccin {
    struct Palette {
        let blue: Color     // keys / requests
        let green: Color    // strings / responses
        let peach: Color    // numbers
        let yellow: Color   // true / false / null
        let red: Color      // errors
        let subtle: Color   // notes / secondary
    }

    static let frappe = Palette(
        blue:   Color(hex: 0x8CAAEE),
        green:  Color(hex: 0xA6D189),
        peach:  Color(hex: 0xEF9F76),
        yellow: Color(hex: 0xE5C890),
        red:    Color(hex: 0xE78284),
        subtle: Color(hex: 0x949CBB)
    )

    static let mocha = Palette(
        blue:   Color(hex: 0x89B4FA),
        green:  Color(hex: 0xA6E3A1),
        peach:  Color(hex: 0xFAB387),
        yellow: Color(hex: 0xF9E2AF),
        red:    Color(hex: 0xF38BA8),
        subtle: Color(hex: 0xA6ADC8)
    )

    static func palette(for scheme: ColorScheme) -> Palette {
        scheme == .dark ? mocha : frappe
    }
}

// MARK: - Deterministic draggable vertical split
//
// VSplitView computes its divider position from the children's ideal sizes
// and rebalances it whenever the content churns — erratic in a tool pane.
// This one is rule-driven: starts at 50%, moves ONLY when the user drags
// the handle, and reports every change through the binding (the caller
// stores it per server for the session, and restores it on selection).

struct DraggableVSplit<Top: View, Bottom: View>: View {
    @Binding var fraction: Double   // fraction of total height above the handle
    @State private var dragStart: Double?
    @Environment(\.colorScheme) private var scheme

    private let topContent: Top
    private let bottomContent: Bottom

    init(fraction: Binding<Double>,
         @ViewBuilder top: () -> Top,
         @ViewBuilder bottom: () -> Bottom) {
        _fraction = fraction
        self.topContent = top()
        self.bottomContent = bottom()
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 0) {
                topContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .frame(height: max(40, fraction * h))
                handle(totalHeight: h)
                bottomContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func handle(totalHeight h: CGFloat) -> some View {
        let pal = Catppuccin.palette(for: scheme)
        return Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 7)
            .overlay(
                Capsule()
                    .fill(pal.subtle.opacity(0.55))
                    .frame(width: 36, height: 4)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                // .global, NOT the default .local: the handle itself moves
                // during the drag, and local-space translation gets rebased
                // under the moving view — which makes the handle lag/elastic
                // behind the cursor. Global translation is the true pointer
                // delta no matter where the handle is.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard h > 60 else { return }
                        if dragStart == nil { dragStart = fraction }
                        let start = dragStart ?? fraction
                        let raw = start + Double(value.translation.height / h)
                        fraction = min(max(raw, 0.15), 0.85)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .help("Drag to resize the tools / editor split")
    }
}

// MARK: - Wrapping flow layout for content-sized chips
//
// A GridItem(.adaptive) hands every cell the column width, so a capsule
// around a short word grows past it. This Layout instead measures each
// subview at its intrinsic size, lays rows left to right, and wraps when
// the next subview would overflow — pill width follows the text, rows
// follow the container. (Layout is macOS 13+; the app targets 14.)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0        // cursor inside the current row
        var y: CGFloat = 0        // top of the current row
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x > 0, x + spacing + s.width > limit {
                widest = max(widest, x)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            if x > 0 { x += spacing }
            x += s.width
            rowHeight = max(rowHeight, s.height)
        }
        widest = max(widest, x)
        return CGSize(width: min(widest, limit), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sub in subviews {
            // Same measurement as sizeThatFits: place with the intrinsic size,
            // so the two passes agree and nothing re-wraps under placement.
            let s = sub.sizeThatFits(.unspecified)
            if x > 0, x + spacing + s.width > bounds.width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            if x > 0 { x += spacing }
            sub.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                      anchor: .topLeading,
                      proposal: ProposedViewSize(s))
            x += s.width
            rowHeight = max(rowHeight, s.height)
        }
    }
}

// MARK: - Grouping card (rounded box)
//
// The shape the Server profile groups its sections with — one reusable view
// so any other boxed area (the tool editor's argument form + call row) reads
// as the same kind of surface.

struct CardBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.22)))
    }
}

// MARK: - Disclosure whose whole title row toggles it
//
// The system `DisclosureGroup` toggles only from its triangle, and there is
// no style knob for the hit area. This is the transcript rows' behavior in a
// reusable shape: a plain button over title + chevron, with
// `.contentShape(Rectangle())` so the whole row is the hit area, and the
// content below mounted only while open.

struct TappableDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                // Deliberately not animated, exactly as in the transcript:
                // the body below is a box with a height of its own, and
                // animating that height re-lays the body out once per frame.
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Example arguments generated from an input schema

enum SchemaExample {
    static func argumentsJSON(from schema: JSONValue?) -> String {
        JSONValue.object(exampleObject(schema)).prettyString
    }

    private static func exampleObject(_ schema: JSONValue?) -> [String: JSONValue] {
        guard let props = schema?["properties"]?.object else { return [:] }
        var out: [String: JSONValue] = [:]
        for (key, prop) in props {
            out[key] = exampleValue(prop)
        }
        return out
    }

    private static func exampleValue(_ p: JSONValue) -> JSONValue {
        if let e = p["enum"]?.array, let first = e.first { return first }
        if let ex = p["examples"]?.array, let first = ex.first { return first }
        if let d = p["default"] { return d }
        switch p["type"]?.string {
        case "boolean": return .bool(false)
        case "integer": return .int(0)
        case "number":  return .double(0)
        case "array":   return .array([])
        case "object":
            if p["properties"] != nil { return .object(exampleObject(p)) }
            return .object([:])
        case "null":    return .null
        default:
            if let props = p["properties"]?.object, !props.isEmpty {
                return .object(exampleObject(p))
            }
            return .string("")
        }
    }
}

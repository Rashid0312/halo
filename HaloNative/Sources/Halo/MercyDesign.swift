import SwiftUI

/// Mercy's design tokens: Halo's palette on a light, layered layout with a
/// fixed type scale and corner radii, shared by setup and Settings.
enum Mercy {
    static let name = "Mercy"

    // Palette, from the Halo gradient.
    static let indigo = Color(red: 0.43, green: 0.48, blue: 0.97)
    static let violet = Color(red: 0.72, green: 0.56, blue: 0.96)
    static let teal = Color(red: 0.48, green: 0.88, blue: 0.91)
    static let accent = indigo
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.14)
    static let inkSecondary = Color(red: 0.42, green: 0.42, blue: 0.47)
    static let inkFaint = Color(red: 0.56, green: 0.56, blue: 0.60)
    static let hairline = Color.black.opacity(0.07)
    static let rail = Color.white.opacity(0.55)
    static let card = Color.white.opacity(0.82)

    // Corner radii.
    static let chipRadius: CGFloat = 10
    static let controlRadius: CGFloat = 14
    static let cardRadius: CGFloat = 22
    static let dialogRadius: CGFloat = 20
    static let panelRadius: CGFloat = 28

    // Type scale.
    static let pageTitle = Font.system(size: 30, weight: .semibold, design: .rounded)
    static let heroTitle = Font.system(size: 34, weight: .semibold, design: .rounded)
    static let dialogTitle = Font.system(size: 20, weight: .semibold, design: .rounded)
    static let sectionTitle = Font.system(size: 16, weight: .semibold)
    static let rowTitle = Font.system(size: 14, weight: .medium)
    static let body = Font.system(size: 13)
    static let heroBody = Font.system(size: 15)
    static let caption = Font.system(size: 12)
    static let micro = Font.system(size: 11, weight: .medium)

    static let gradient = LinearGradient(colors: [indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The brand mark from the panel: seven dots in a flower.
struct MercyMark: View {
    var size: CGFloat = 22
    var color: Color = Mercy.indigo

    var body: some View {
        let dot = size * 0.3
        ZStack {
            Circle().frame(width: dot, height: dot)
            ForEach(0..<6, id: \.self) { index in
                Circle().frame(width: dot, height: dot)
                    .offset(x: cos(Double(index) * .pi / 3) * size * 0.34, y: sin(Double(index) * .pi / 3) * size * 0.34)
            }
        }
        .foregroundStyle(color)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A soft wash of the Halo gradient under a light surface.
struct MercyBackdrop: View {
    var strength: Double = 0.35

    var body: some View {
        ZStack {
            Color(red: 0.985, green: 0.985, blue: 0.99)
            FluidGradient(configuration: .init(colors: FluidGradientConfiguration.halo.colors, speed: 0, intensity: 0.6, opacity: strength))
        }
        .ignoresSafeArea()
    }
}

/// A rounded group of rows separated by hairlines.
struct MercyCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(Mercy.micro).textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(Mercy.inkFaint).padding(.leading, 18)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Rectangle().fill(Mercy.hairline).frame(height: 1).padding(.leading, 18) }
                        row
                    }
                }
            }
            .background(Mercy.card, in: RoundedRectangle(cornerRadius: Mercy.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Mercy.cardRadius, style: .continuous).strokeBorder(Mercy.hairline))
            if let footer {
                Text(footer).font(Mercy.caption).foregroundStyle(Mercy.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 18)
            }
        }
    }
}

/// A row with a title, optional detail, and a trailing accessory.
struct MercyRow<Trailing: View>: View {
    var icon: String?
    var title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(Mercy.accent)
                    .frame(width: 28, height: 28)
                    .background(Mercy.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Mercy.rowTitle).foregroundStyle(Mercy.ink)
                if let detail, !detail.isEmpty {
                    Text(detail).font(Mercy.caption).foregroundStyle(Mercy.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension MercyRow where Trailing == EmptyView {
    init(icon: String? = nil, title: String, detail: String? = nil) {
        self.init(icon: icon, title: title, detail: detail) { EmptyView() }
    }
}

/// A row that shows a current value and opens a pop-up to change it.
struct MercyValueRow: View {
    var icon: String?
    var title: String
    var value: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            MercyRow(icon: icon, title: title) {
                Text(value).font(Mercy.body).foregroundStyle(Mercy.inkSecondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Mercy.inkFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MercyToggleRow: View {
    var icon: String?
    var title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        MercyRow(icon: icon, title: title, detail: detail) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Mercy.accent)
        }
    }
}

/// A status pill: green when done, muted otherwise.
struct MercyStatus: View {
    var done: Bool
    var doneText = "On"
    var pendingText = "Needed"

    var body: some View {
        Label(done ? doneText : pendingText, systemImage: done ? "checkmark.circle.fill" : "circle.dashed")
            .font(Mercy.micro)
            .foregroundStyle(done ? Color.green : Mercy.inkSecondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background((done ? Color.green : Color.black).opacity(0.07), in: Capsule())
    }
}

/// Filled for the main action, quiet for the rest.
struct MercyButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, onGradient, glass }
    var kind: Kind = .primary
    var wide = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 18).frame(height: 40)
            .frame(maxWidth: wide ? .infinity : nil)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: Mercy.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Mercy.controlRadius, style: .continuous)
                .strokeBorder(kind == .glass ? Color.white.opacity(0.35) : (kind == .secondary ? Mercy.hairline : .clear)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Mercy.controlRadius, style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: Mercy.ink
        case .onGradient: Mercy.ink
        case .glass: .white
        }
    }

    private var background: AnyShapeStyle {
        switch kind {
        case .primary: AnyShapeStyle(Mercy.gradient)
        case .secondary: AnyShapeStyle(Color.white.opacity(0.9))
        case .onGradient: AnyShapeStyle(Color.white.opacity(0.92))
        case .glass: AnyShapeStyle(Color.white.opacity(0.16))
        }
    }
}

/// A text field drawn as a soft rounded well.
struct MercyFieldStyle: TextFieldStyle {
    var onGradient = false

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .padding(.horizontal, 14).frame(height: 44)
            .foregroundStyle(onGradient ? Color.white : Mercy.ink)
            .background(onGradient ? Color.white.opacity(0.16) : Color.white,
                        in: RoundedRectangle(cornerRadius: Mercy.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Mercy.controlRadius, style: .continuous)
                .strokeBorder(onGradient ? Color.white.opacity(0.35) : Mercy.hairline))
    }
}

/// A centered pop-up for changing one setting, with a title and a short line.
struct MercyPopup<Content: View>: View {
    var title: String
    var subtitle: String
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Mercy.dialogTitle).foregroundStyle(Mercy.ink)
                    Text(subtitle).font(Mercy.body).foregroundStyle(Mercy.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Mercy.inkSecondary)
                        .frame(width: 26, height: 26).background(Color.black.opacity(0.05), in: Circle())
                }
                .buttonStyle(.plain).keyboardShortcut(.cancelAction)
            }
            content
        }
        .padding(24)
        .frame(width: 440)
        .background(MercyBackdrop(strength: 0.18))
    }
}

import AppKit

/// Who made Mixtape.
enum Credits {
    static let line = "Idea by SM/AEIOU"
    static let email = "aeiou11235+mixtape@gmail.com"
    static let website = "mixtape.toyko.online"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
}

/// The About screen: the picture, MIXTAPE in heavy lettering and the credits, in a frameless
/// paper card. A click anywhere else, or any key, sends it away.
@MainActor
final class AboutScreen {
    static let shared = AboutScreen()
    private(set) var window: NSWindow?
    private var timer: Timer?

    private final class CardWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class CardView: NSView {
        var onDismiss: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { onDismiss?() }
        override func keyDown(with event: NSEvent) { onDismiss?() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// `briefly`: on launch it fades by itself after a few seconds; from the menu it stays until clicked.
    func show(briefly: Bool) {
        if window != nil { dismiss(); return }
        let ink = NSColor(calibratedWhite: 0.06, alpha: 1)
        let red = NSColor(calibratedRed: 0.77, green: 0.18, blue: 0.16, alpha: 1)
        let paper = NSColor(calibratedRed: 0.965, green: 0.96, blue: 0.94, alpha: 1)
        let picture = Bundle.main.url(forResource: "startbild", withExtension: "jpg").flatMap { NSImage(contentsOf: $0) }

        let margin: CGFloat = 22, width: CGFloat = 420
        let pictureSize: NSSize = {
            guard let p = picture, p.size.width > 0 else { return .zero }
            let w = width - 2 * margin
            return NSSize(width: w, height: (p.size.height * w / p.size.width).rounded())
        }()
        let textHeight: CGFloat = 238
        let total = NSSize(width: width, height: pictureSize.height + textHeight + margin * 2)
        let view = CardView(frame: NSRect(origin: .zero, size: total))
        view.wantsLayer = true
        view.layer?.backgroundColor = paper.cgColor
        view.layer?.borderColor = ink.cgColor
        view.layer?.borderWidth = 4

        if let picture {
            let iv = NSImageView(frame: NSRect(x: margin, y: textHeight + margin, width: pictureSize.width, height: pictureSize.height))
            iv.image = picture
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.borderColor = ink.cgColor
            iv.layer?.borderWidth = 2
            view.addSubview(iv)
        }
        func lettering(_ text: String, size: CGFloat, color: NSColor, kern: CGFloat) -> NSAttributedString {
            let font = NSFont(name: "Futura-CondensedExtraBold", size: size) ?? .systemFont(ofSize: size, weight: .black)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: style])
        }
        func label(_ text: NSAttributedString, y: CGFloat, height: CGFloat) {
            let f = NSTextField(labelWithAttributedString: text)
            f.frame = NSRect(x: margin, y: y, width: total.width - margin * 2, height: height)
            f.alignment = .center
            view.addSubview(f)
        }
        let top = margin + textHeight
        label(lettering("MIXTAPE", size: 66, color: ink, kern: 7), y: top - 84, height: 80)
        label(lettering(L("WIE 1986").uppercased(), size: 22, color: red, kern: 9), y: top - 112, height: 30)
        let bar = NSView(frame: NSRect(x: margin + 24, y: top - 122, width: total.width - margin * 2 - 48, height: 4))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = ink.cgColor
        view.addSubview(bar)

        // Logo, and the credits small and centred under it.
        if let logo = Bundle.main.url(forResource: "aeiou-logo", withExtension: "png").flatMap({ NSImage(contentsOf: $0) }) {
            let lv = NSImageView(frame: NSRect(x: (total.width - 40) / 2, y: top - 176, width: 40, height: 40))
            lv.image = logo
            view.addSubview(lv)
        }
        let small = NSFont.systemFont(ofSize: 10.5)
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        let plain: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: ink.withAlphaComponent(0.75)]
        let credits = NSMutableAttributedString(string: Credits.line + " · ", attributes: plain)
        credits.append(NSAttributedString(string: Credits.website, attributes: [.font: small, .foregroundColor: red,
                                                                                .link: URL(string: "https://" + Credits.website)!]))
        credits.append(NSAttributedString(string: "\n© 2026 · Mixtape " + Credits.version + " · ", attributes: plain))
        credits.append(NSAttributedString(string: Credits.email, attributes: [.font: small, .foregroundColor: red,
                                                                              .link: URL(string: "mailto:" + Credits.email)!]))
        credits.append(NSAttributedString(string: "\n" + L("Gefällt dir Mixtape?") + " ", attributes: plain))
        credits.append(NSAttributedString(string: L("Spende auf itch.io") + " ♥", attributes: [.font: small, .foregroundColor: red,
                                                                                            .link: AppDelegate.donatePage]))
        credits.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: credits.length))
        let cf = NSTextField(labelWithAttributedString: credits)
        cf.isSelectable = true          // makes the address clickable
        cf.allowsEditingTextAttributes = true
        cf.alignment = .center
        cf.frame = NSRect(x: margin, y: top - 228, width: total.width - margin * 2, height: 46)
        view.addSubview(cf)


        let w = CardWindow(contentRect: NSRect(origin: .zero, size: total), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.center()
        view.onDismiss = { [weak self] in self?.dismiss() }
        window = w
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; w.animator().alphaValue = 1 }
        NSApp.activate()
        if briefly {
            timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        guard let w = window else { return }
        window = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; w.animator().alphaValue = 0 },
                                            completionHandler: { w.orderOut(nil) })
    }
}

/// A small "working on it" card under the cassette while something slow runs.
@MainActor
final class BusyPanel {
    private let panel: NSPanel
    private let label: NSTextField

    init(_ text: String, near window: NSWindow?) {
        let size = NSSize(width: 280, height: 46)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        let spinner = NSProgressIndicator(frame: NSRect(x: 16, y: 14, width: 18, height: 18))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        fx.addSubview(spinner)
        label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 44, y: 14, width: size.width - 56, height: 18)
        fx.addSubview(label)
        panel.contentView = fx
        if let w = window {
            let f = w.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - Geo.margin - Geo.ch - size.height - 12))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }

    func setText(_ text: String) { label.stringValue = text }
}

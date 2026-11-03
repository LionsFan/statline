import AppKit
import ServiceManagement

// `StatLine --sample` prints a couple of readings to stdout and exits (handy for checking numbers).
if CommandLine.arguments.contains("--sample") {
    let s = Sampler()
    s.sample()
    for _ in 0..<3 {
        Thread.sleep(forTimeInterval: 1)
        s.sample()
        print(String(format: "CPU %@ (usr %@ sys %@) | MEM %@ used %@ of %@ (app %@ wired %@ comp %@) | NET down %@ up %@ [%@]",
                     Fmt.pct(s.cpu.total), Fmt.pct(s.cpu.user), Fmt.pct(s.cpu.system),
                     Fmt.pct(s.memory.fraction), Fmt.bytes(s.memory.used), Fmt.bytes(s.memory.total),
                     Fmt.bytes(s.memory.app), Fmt.bytes(s.memory.wired), Fmt.bytes(s.memory.compressed),
                     Fmt.rate(s.net.downBytesPerSec, bits: true), Fmt.rate(s.net.upBytesPerSec, bits: true),
                     s.net.interfaces.joined(separator: ",")))
    }
    exit(0)
}

enum Style: String, CaseIterable {
    case labels = "Labels"   // CPU 6%  ↓8.1M / MEM 58% ↑1.1M
    case bars = "Bars"       // two mini bars + network
    var title: String { self == .labels ? "Compact Text" : "Mini Bars (smallest)" }
}

final class Prefs {
    private let d = UserDefaults.standard
    var style: Style {
        get { Style(rawValue: d.string(forKey: "style") ?? "") ?? .labels }
        set { d.set(newValue.rawValue, forKey: "style") }
    }
    var bits: Bool {
        get { d.object(forKey: "bits") as? Bool ?? true }   // Usage shows Mb/s, so default to bits
        set { d.set(newValue, forKey: "bits") }
    }
    /// false = Activity Monitor "Memory Used"; true = active + wired + compressed (≈ Usage).
    var activeMemory: Bool {
        get { d.bool(forKey: "activeMemory") }
        set { d.set(newValue, forKey: "activeMemory") }
    }
    var interval: Double {
        get { let v = d.double(forKey: "interval"); return v > 0 ? v : 2 }
        set { d.set(newValue, forKey: "interval") }
    }
}

// MARK: - Menu bar rendering

/// Draws the whole item as one template image so macOS tints it for light/dark menu bars automatically.
enum Renderer {
    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
    static let labelFont = NSFont.systemFont(ofSize: 7, weight: .bold)
    static let arrowFont = NSFont.systemFont(ofSize: 7.5, weight: .bold)
    static let dim: CGFloat = 0.55

    static func width(_ s: String, _ f: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }
    // Fixed column widths so the item never jitters as numbers change.
    static let pctW = width("100%", valueFont)
    static let netW = ["888K", "8.8M", "88M", "888M", "8.8G"].map { width($0, valueFont) }.max()!
    static let labelW = max(width("CPU", labelFont), width("MEM", labelFont))
    static let arrowW = width("↓", arrowFont)

    static func image(cpu: Double, mem: Double, down: String, up: String, style: Style) -> NSImage {
        let h = NSStatusBar.system.thickness
        let rowH: CGFloat = 10.5
        let top = (h + 2 * rowH) / 2           // baseline-ish anchor for the two stacked rows
        let row1 = NSRect(x: 0, y: top - rowH, width: 0, height: rowH)
        let row2 = NSRect(x: 0, y: top - 2 * rowH, width: 0, height: rowH)

        var x: CGFloat = 1
        var ops: [(NSRect) -> Void] = []

        func text(_ s: String, _ font: NSFont, alpha: CGFloat, x: CGFloat, w: CGFloat, row: NSRect, right: Bool) {
            let p = NSMutableParagraphStyle()
            p.alignment = right ? .right : .left
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.black.withAlphaComponent(alpha), .paragraphStyle: p,
            ]
            // Vertically centre smaller fonts on the value font's line.
            let dy = (valueFont.ascender - font.ascender) / 2 + (font == valueFont ? 0 : -0.5)
            ops.append { _ in
                (s as NSString).draw(in: NSRect(x: x, y: row.minY - dy, width: w, height: row.height + 2), withAttributes: attrs)
            }
        }

        switch style {
        case .labels:
            text("CPU", labelFont, alpha: dim, x: x, w: labelW, row: row1, right: false)
            text("MEM", labelFont, alpha: dim, x: x, w: labelW, row: row2, right: false)
            x += labelW + 1
            text(Fmt.pct(cpu), valueFont, alpha: 1, x: x, w: pctW, row: row1, right: true)
            text(Fmt.pct(mem), valueFont, alpha: 1, x: x, w: pctW, row: row2, right: true)
            x += pctW + 5
        case .bars:
            let barW: CGFloat = 4, barH = 2 * rowH - 3
            let y = (h - barH) / 2
            for (i, v) in [cpu, mem].enumerated() {
                let bx = x + CGFloat(i) * (barW + 2)
                ops.append { _ in
                    let track = NSBezierPath(roundedRect: NSRect(x: bx, y: y, width: barW, height: barH), xRadius: 1.2, yRadius: 1.2)
                    NSColor.black.withAlphaComponent(0.22).setFill(); track.fill()
                    let fh = max(1, barH * CGFloat(min(1, max(0, v))))
                    NSGraphicsContext.saveGraphicsState()
                    track.addClip()
                    NSColor.black.setFill()
                    NSRect(x: bx, y: y, width: barW, height: fh).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            x += 2 * barW + 2 + 5
        }

        text("↓", arrowFont, alpha: dim, x: x, w: arrowW, row: row1, right: false)
        text("↑", arrowFont, alpha: dim, x: x, w: arrowW, row: row2, right: false)
        x += arrowW + 1
        text(down, valueFont, alpha: 1, x: x, w: netW, row: row1, right: true)
        text(up, valueFont, alpha: 1, x: x, w: netW, row: row2, right: true)
        x += netW + 1

        let img = NSImage(size: NSSize(width: ceil(x), height: h), flipped: false) { r in
            ops.forEach { $0(r) }
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let sampler = Sampler()
    private let prefs = Prefs()
    private var item: NSStatusItem!
    private var timer: Timer?
    private var lastKey = ""
    private var menuOpen = false

    private let menu = NSMenu()
    private let cpuItem = NSMenuItem()
    private let loadItem = NSMenuItem()
    private let memItem = NSMenuItem()
    private let memDetailItem = NSMenuItem()
    private let memSwapItem = NSMenuItem()
    private let netItem = NSMenuItem()
    private let netDetailItem = NSMenuItem()
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private var styleItems: [NSMenuItem] = []
    private var unitItems: [NSMenuItem] = []
    private var intervalItems: [NSMenuItem] = []
    private var memModeItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "StatLine"
        item.button?.imagePosition = .imageOnly
        buildMenu()
        item.menu = menu
        sampler.sample()            // prime deltas
        restartTimer()
        if CommandLine.arguments.contains("--open-menu") {   // debug: pop the menu open to inspect it
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.item.button?.performClick(nil) }
        }
    }

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: prefs.interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = prefs.interval * 0.1
        RunLoop.main.add(t, forMode: .common)   // .common keeps it ticking while the menu is open
        timer = t
        tick()
    }

    private var memFraction: Double { prefs.activeMemory ? sampler.memory.activeFraction : sampler.memory.fraction }

    private func tick() {
        sampler.sample()
        let cpu = sampler.cpu.total, mem = memFraction
        let bits = prefs.bits
        let down = Fmt.compactRate(sampler.net.downBytesPerSec, bits: bits)
        let up = Fmt.compactRate(sampler.net.upBytesPerSec, bits: bits)
        let style = prefs.style
        let key = "\(style.rawValue)|\(Fmt.pct(cpu))|\(Fmt.pct(mem))|\(down)|\(up)|\(Int(cpu * 40))|\(Int(mem * 40))"
        if key != lastKey {
            lastKey = key
            item.button?.image = Renderer.image(cpu: cpu, mem: mem, down: down, up: up, style: style)
            item.button?.setAccessibilityLabel("CPU \(Fmt.pct(cpu)), memory \(Fmt.pct(mem)), download \(Fmt.rate(sampler.net.downBytesPerSec, bits: bits)), upload \(Fmt.rate(sampler.net.upBytesPerSec, bits: bits))")
        }
        if menuOpen { updateMenuText() }
    }

    // MARK: Menu

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        for i in [cpuItem, loadItem, memItem, memDetailItem, memSwapItem, netItem, netDetailItem] {
            i.target = self
            i.action = #selector(openActivityMonitor)
        }
        menu.addItem(cpuItem); menu.addItem(loadItem)
        menu.addItem(.separator())
        menu.addItem(memItem); menu.addItem(memDetailItem); menu.addItem(memSwapItem)
        menu.addItem(.separator())
        menu.addItem(netItem); menu.addItem(netDetailItem)
        menu.addItem(.separator())

        let am = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
        am.target = self
        menu.addItem(am)

        let styleMenu = NSMenu()
        for s in Style.allCases {
            let i = NSMenuItem(title: s.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = s.rawValue
            styleItems.append(i); styleMenu.addItem(i)
        }
        let unitMenu = NSMenu()
        for (title, bits) in [("Bits (Mb/s)", true), ("Bytes (MB/s)", false)] {
            let i = NSMenuItem(title: title, action: #selector(pickUnits(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = bits
            unitItems.append(i); unitMenu.addItem(i)
        }
        let intervalMenu = NSMenu()
        for secs in [1.0, 2.0, 5.0] {
            let i = NSMenuItem(title: "Every \(Int(secs))s", action: #selector(pickInterval(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = secs
            intervalItems.append(i); intervalMenu.addItem(i)
        }
        let memMenu = NSMenu()
        for (title, active) in [("App + Wired + Compressed (Activity Monitor)", false), ("Active + Wired + Compressed (like Usage)", true)] {
            let i = NSMenuItem(title: title, action: #selector(pickMemMode(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = active
            memModeItems.append(i); memMenu.addItem(i)
        }
        let settings = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu()
        for (t, m) in [("Style", styleMenu), ("Memory Used", memMenu), ("Network Units", unitMenu), ("Refresh", intervalMenu)] {
            let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.submenu = m; settingsMenu.addItem(i)
        }
        settingsMenu.addItem(.separator())
        loginItem.target = self
        settingsMenu.addItem(loginItem)
        settings.submenu = settingsMenu
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit StatLine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func menuWillOpen(_ m: NSMenu) {
        menuOpen = true
        updateMenuText()
        styleItems.forEach { $0.state = ($0.representedObject as? String) == prefs.style.rawValue ? .on : .off }
        unitItems.forEach { $0.state = ($0.representedObject as? Bool) == prefs.bits ? .on : .off }
        memModeItems.forEach { $0.state = ($0.representedObject as? Bool) == prefs.activeMemory ? .on : .off }
        intervalItems.forEach { $0.state = ($0.representedObject as? Double) == prefs.interval ? .on : .off }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func menuDidClose(_ m: NSMenu) { menuOpen = false }

    private func line(_ head: String, _ rest: String, sub: Bool = false) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: sub ? 11 : 13, weight: .regular)
        if !head.isEmpty {
            s.append(NSAttributedString(string: head + "  ", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]))
        }
        s.append(NSAttributedString(string: rest, attributes: [
            .font: font, .foregroundColor: sub ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]))
        return s
    }

    private func updateMenuText() {
        let c = sampler.cpu, m = sampler.memory, n = sampler.net, bits = prefs.bits
        cpuItem.attributedTitle = line("CPU", "\(Fmt.pct(c.total))   user \(Fmt.pct(c.user)) · system \(Fmt.pct(c.system))")
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        loadItem.attributedTitle = line("", "Load avg  " + load.map { String(format: "%.2f", $0) }.joined(separator: "  ")
                                         + "  ·  \(ProcessInfo.processInfo.activeProcessorCount) cores", sub: true)

        let shownUsed = prefs.activeMemory ? m.active + m.wired + m.compressed : m.used
        memItem.attributedTitle = line("Memory", "\(Fmt.pct(memFraction))   \(Fmt.bytes(shownUsed)) of \(Fmt.bytes(m.total))")
        memDetailItem.attributedTitle = line("", "App \(Fmt.bytes(m.app)) · Wired \(Fmt.bytes(m.wired)) · Compressed \(Fmt.bytes(m.compressed))", sub: true)
        let pressure = m.pressure >= 4 ? "Critical" : m.pressure >= 2 ? "Warning" : "Normal"
        memSwapItem.attributedTitle = line("", "Cached \(Fmt.bytes(m.cached)) · Swap \(Fmt.bytes(m.swapUsed)) · Pressure \(pressure)", sub: true)

        netItem.attributedTitle = line("Network", "↓ \(Fmt.rate(n.downBytesPerSec, bits: bits))   ↑ \(Fmt.rate(n.upBytesPerSec, bits: bits))")
        let ifs = n.interfaces.isEmpty ? "no active interface" : n.interfaces.joined(separator: ", ")
        netDetailItem.attributedTitle = line("", "\(ifs) · total ↓ \(Fmt.fileBytes(n.totalDown)) ↑ \(Fmt.fileBytes(n.totalUp))", sub: true)
    }

    // MARK: Actions

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                           configuration: .init())
    }

    @objc private func pickStyle(_ s: NSMenuItem) {
        if let raw = s.representedObject as? String, let st = Style(rawValue: raw) { prefs.style = st; lastKey = ""; tick() }
    }

    @objc private func pickUnits(_ s: NSMenuItem) {
        if let b = s.representedObject as? Bool { prefs.bits = b; lastKey = ""; tick() }
    }

    @objc private func pickMemMode(_ s: NSMenuItem) {
        if let b = s.representedObject as? Bool { prefs.activeMemory = b; lastKey = ""; tick() }
    }

    @objc private func pickInterval(_ s: NSMenuItem) {
        if let v = s.representedObject as? Double { prefs.interval = v; restartTimer() }
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at Login"
            a.informativeText = "\(error.localizedDescription)\n\nYou can add StatLine manually in System Settings → General → Login Items."
            a.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
app.run()

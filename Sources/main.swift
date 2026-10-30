import AppKit
import Combine
import IOKit.ps
import SwiftUI

// MARK: - Battery

struct BatteryState: Equatable {
    var percent: Int?        // nil when the Mac has no internal battery
    var isCharging = false
    var isPluggedIn = false

    static func read() -> BatteryState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return BatteryState(percent: nil) }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }

            return BatteryState(
                percent: Int((Double(current) / Double(max) * 100).rounded()),
                isCharging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                isPluggedIn: desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            )
        }
        return BatteryState(percent: nil)
    }
}

final class BatteryModel: ObservableObject {
    @Published var state = BatteryState.read()
    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?

    init() {
        // IOKit pushes a notification whenever any power source changes.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryModel>.fromOpaque(ctx).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = source
        }
        // Safety net in case a notification is missed (e.g. after sleep).
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let new = BatteryState.read()
        if new != state { state = new }
    }
}

// MARK: - Overlay view

struct BatteryView: View {
    @ObservedObject var model: BatteryModel

    var body: some View {
        if isCritical {
            // Alternate between a yellow and the normal background twice a second.
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let flashOn = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                pill(flashOn: flashOn)
            }
        } else {
            pill(flashOn: false)
        }
    }

    private func pill(flashOn: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.hierarchical)
            Text(model.state.percent.map { "\($0)%" } ?? "AC")
                .monospacedDigit()
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(flashOn ? .black : color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(flashOn ? Color.yellow : Color.black.opacity(0.55)))
        .fixedSize()
    }

    /// Under 3% and not plugged in.
    private var isCritical: Bool {
        guard let p = model.state.percent else { return false }
        return p < 3 && !model.state.isPluggedIn
    }

    private var symbolName: String {
        let s = model.state
        guard let p = s.percent else { return "powerplug.fill" }
        if s.isCharging { return "battery.100percent.bolt" }
        switch p {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default:    return "battery.100percent"
        }
    }

    private var color: Color {
        let s = model.state
        guard let p = s.percent else { return .white }
        if s.isCharging || s.isPluggedIn { return .green }
        if p <= 10 { return .red }
        if p <= 20 { return .yellow }
        return .white
    }
}

// MARK: - Corner placement

enum Corner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }

    static var saved: Corner {
        get { Corner(rawValue: UserDefaults.standard.string(forKey: "corner") ?? "") ?? .bottomRight }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "corner") }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = BatteryModel()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private let margin: CGFloat = 8

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpPanel()
        setUpStatusItem()
        reposition()

        NotificationCenter.default.addObserver(
            self, selector: #selector(reposition),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func setUpPanel() {
        let host = NSHostingView(rootView: BatteryView(model: model))
        host.frame.size = host.fittingSize

        panel = NSPanel(contentRect: host.frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true          // clicks pass straight through
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver                // above normal and full-screen windows
        panel.collectionBehavior = [
            .canJoinAllSpaces,                    // every desktop/Space
            .fullScreenAuxiliary,                 // allowed over full-screen apps
            .stationary,                          // unaffected by Mission Control / Exposé
            .ignoresCycle,
        ]
        panel.orderFrontRegardless()

        // Keep the panel anchored to its corner as the text width changes.
        // ($state fires before the value is stored, hence the async hop.)
        model.$state.sink { [weak self] _ in
            DispatchQueue.main.async { self?.reposition() }
        }.store(in: &cancellables)
    }

    private var cancellables: Set<AnyCancellable> = []

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "battery.75percent", accessibilityDescription: "Battery Peek")
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Corner", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for corner in Corner.allCases {
            let item = NSMenuItem(title: corner.title, action: #selector(pickCorner(_:)), keyEquivalent: "")
            item.representedObject = corner.rawValue
            item.state = corner == Corner.saved ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Battery Peek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func pickCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let corner = Corner(rawValue: raw) else { return }
        Corner.saved = corner
        rebuildMenu()
        reposition()
    }

    @objc private func reposition() {
        // The first screen is the one with the menu bar.
        guard let screen = NSScreen.screens.first, let host = panel.contentView else { return }
        let size = host.fittingSize
        let area = screen.visibleFrame
        let x: CGFloat, y: CGFloat
        switch Corner.saved {
        case .topLeft:     (x, y) = (area.minX + margin, area.maxY - size.height - margin)
        case .topRight:    (x, y) = (area.maxX - size.width - margin, area.maxY - size.height - margin)
        case .bottomLeft:  (x, y) = (area.minX + margin, area.minY + margin)
        case .bottomRight: (x, y) = (area.maxX - size.width - margin, area.minY + margin)
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon; required to float over other apps' full-screen Spaces
app.run()

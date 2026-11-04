import AppKit
import AudioToolbox
import AVFoundation
import Combine
import CoreAudio
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

// MARK: - Audio devices and processes (Core Audio)

/// Finds output devices and reads/writes their volume and mute, independently of
/// whatever the system's current output device is.
enum AudioDevices {
    private static let internalSpeakerSource: UInt32 = 0x6973_706B   // 'ispk'
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    /// The MacBook's built-in speakers.
    static func builtInSpeakers() -> AudioDeviceID? {
        let builtInOutputs = objectList(kAudioHardwarePropertyDevices).filter {
            transportType($0) == kAudioDeviceTransportTypeBuiltIn && hasOutputStreams($0)
        }
        // On Apple Silicon the headphone jack is a separate built-in device; pick the speakers.
        return builtInOutputs.first {
            get($0, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput, UInt32(0)) == internalSpeakerSource
        } ?? builtInOutputs.first { uid($0)?.contains("Speaker") == true }
    }

    /// The current system output (headphones, AirPods, USB/HDMI audio…), skipping
    /// virtual devices such as Zoom's or loopback drivers.
    static func defaultOutput() -> AudioDeviceID? {
        guard let id = get(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0)),
              id != kAudioObjectUnknown,
              transportType(id) != kAudioDeviceTransportTypeVirtual
        else { return nil }
        return id
    }

    /// Bundle IDs of other apps currently sending audio to any output.
    static func appsPlayingAudio() -> [String] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return objectList(kAudioHardwarePropertyProcessObjectList).compactMap { process in
            guard get(process, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, UInt32(0)) == 1,
                  get(process, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, pid_t(0)) != ownPID
            else { return nil }
            return string(process, kAudioProcessPropertyBundleID) ?? ""
        }
    }

    static func uid(_ id: AudioDeviceID) -> String? {
        string(id, kAudioDevicePropertyDeviceUID)
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32? {
        get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0))
    }

    private static func objectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        guard let ref = get(id, selector, kAudioObjectPropertyScopeGlobal, Unmanaged<CFString>?.none) ?? nil
        else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func volume(_ id: AudioDeviceID) -> Float32? {
        get(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, Float32(0))
    }

    static func setVolume(_ id: AudioDeviceID, _ value: Float32) {
        set(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput, value)
    }

    static func mute(_ id: AudioDeviceID) -> UInt32? {
        get(id, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, UInt32(0))
    }

    static func setMute(_ id: AudioDeviceID, _ value: UInt32) {
        set(id, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, value)
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope, _ initial: T) -> T? {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    private static func set<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope, _ value: T) {
        var addr = address(selector, scope)
        withUnsafeBytes(of: value) {
            _ = AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32($0.count), $0.baseAddress!)
        }
    }
}

// MARK: - Media key

/// Simulates the keyboard's Play/Pause key, which goes to the app macOS considers
/// "Now Playing". Posting it requires Accessibility permission.
enum MediaKey {
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt if permission hasn't been granted yet.
    static func requestPermissionIfNeeded() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func playPause() {
        let playKey = 16   // NX_KEYTYPE_PLAY
        for state in [0xA, 0xB] {   // key down, key up
            NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: (playKey << 16) | (state << 8), data2: -1
            )?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Low-battery alarm

/// At or below `threshold`% and unplugged, sounds an alert, repeating every
/// `repeatInterval` until the Mac is plugged in:
/// - always through the built-in speakers at a fixed volume, ignoring their volume and mute;
/// - also through the current output (headphones, AirPods…) at its own volume, raised to a
///   minimum if lower and unmuted;
/// - pausing playing media first (via the Play/Pause key) and resuming it afterwards.
/// Every device's volume and mute are restored once the beeps end.
final class LowBatteryAlarm: NSObject, AVAudioPlayerDelegate {
    static let threshold = 3
    private static let repeatInterval: TimeInterval = 60
    private static let speakerVolume: Float32 = 0.75
    private static let headphoneMinVolume: Float32 = 0.3
    private static let pauseSettleDelay: TimeInterval = 0.4
    private static let soundURL = URL(fileURLWithPath: "/System/Library/Sounds/Sosumi.aiff")
    /// Call apps: their audio doesn't count as media to pause, since the Play/Pause key
    /// wouldn't reach them and would start or stop some other app instead.
    private static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.apple.FaceTime", "com.tinyspeck.slackmacgap",
    ]

    private struct Output {
        let device: AudioDeviceID
        let player: AVAudioPlayer
        let savedVolume: Float32?
        let savedMute: UInt32?
    }

    private var timer: Timer?
    private var outputs: [Output] = []
    private var pendingStart: DispatchWorkItem?
    private var pausedMedia = false

    func update(_ state: BatteryState) {
        let critical = (state.percent ?? 100) <= Self.threshold && !state.isPluggedIn
        if critical, timer == nil {
            sound()
            timer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: true) { [weak self] _ in self?.sound() }
        } else if !critical, timer != nil {
            timer?.invalidate()
            timer = nil
            stop()
        }
    }

    private func sound() {
        guard outputs.isEmpty, pendingStart == nil else { return }
        let mediaPlaying = AudioDevices.appsPlayingAudio().contains { !$0.isEmpty && !Self.callApps.contains($0) }
        guard mediaPlaying, MediaKey.isAllowed else { return startBeeps() }

        MediaKey.playPause()
        pausedMedia = true
        // Give the app a moment to actually stop before beeping.
        let work = DispatchWorkItem { [weak self] in
            self?.pendingStart = nil
            self?.startBeeps()
        }
        pendingStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pauseSettleDelay, execute: work)
    }

    private func startBeeps() {
        let speakers = AudioDevices.builtInSpeakers()
        var targets: [(AudioDeviceID, (Float32?) -> Float32)] = []
        if let speakers { targets.append((speakers, { _ in Self.speakerVolume })) }
        if let current = AudioDevices.defaultOutput(), current != speakers {
            targets.append((current, { max($0 ?? Self.headphoneMinVolume, Self.headphoneMinVolume) }))
        }

        for (device, volumeFor) in targets {
            guard let uid = AudioDevices.uid(device),
                  let player = try? AVAudioPlayer(contentsOf: Self.soundURL)
            else { continue }
            player.currentDevice = uid      // route to this device, not just the default output
            player.numberOfLoops = 2        // three beeps
            player.delegate = self

            let output = Output(device: device, player: player,
                                savedVolume: AudioDevices.volume(device), savedMute: AudioDevices.mute(device))
            AudioDevices.setVolume(device, volumeFor(output.savedVolume))
            AudioDevices.setMute(device, 0)
            outputs.append(output)
        }
        for output in outputs where !output.player.play() { finished(output.player) }
        if outputs.isEmpty { resumeMedia() }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finished(player)
    }

    private func finished(_ player: AVAudioPlayer) {
        guard let index = outputs.firstIndex(where: { $0.player === player }) else { return }
        restore(outputs.remove(at: index))
        if outputs.isEmpty { resumeMedia() }
    }

    private func stop() {
        pendingStart?.cancel()
        pendingStart = nil
        for output in outputs {
            output.player.stop()
            restore(output)
        }
        outputs = []
        resumeMedia()
    }

    private func restore(_ output: Output) {
        if let volume = output.savedVolume { AudioDevices.setVolume(output.device, volume) }
        if let mute = output.savedMute { AudioDevices.setMute(output.device, mute) }
    }

    private func resumeMedia() {
        guard pausedMedia else { return }
        pausedMedia = false
        MediaKey.playPause()
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
                pill(flashOn: flashOn, date: context.date)
            }
        } else {
            // Ticks on each minute boundary to keep the clock current.
            TimelineView(.everyMinute) { context in
                pill(flashOn: false, date: context.date)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"   // 24-hour, ignores the system 12/24h setting
        return f
    }()

    private func pill(flashOn: Bool, date: Date) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.hierarchical)
            Text(model.state.percent.map { "\($0)%" } ?? "AC")
                .monospacedDigit()
            Text(Self.timeFormatter.string(from: date))
                .monospacedDigit()
                .foregroundStyle(flashOn ? .black : .white)
                .padding(.leading, 3)
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
    private let alarm = LowBatteryAlarm()
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private let margin: CGFloat = 8

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpPanel()
        setUpStatusItem()
        reposition()
        MediaKey.requestPermissionIfNeeded()   // lets the low-battery alarm pause media

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
        model.$state.sink { [weak self] state in
            self?.alarm.update(state)
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

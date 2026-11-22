// WindowMemory — remembers window size/position per display setup and
// restores them when the setup changes (e.g. laptop only <-> laptop + external).
//
// Native macOS only: AppKit + Accessibility API + Carbon hotkeys. No third-party tools.
// Build with ./build.sh, install with ./install.sh.

import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - Settings

let saveInterval: TimeInterval = 3      // seconds between snapshots
let persistInterval: TimeInterval = 30  // seconds between writes to disk
let settleDelay: TimeInterval = 2       // wait after a display change before restoring
let scaleOnScreenMove = true            // resize windows moved to another display to the same fraction of it
let ignoredBundleIDs: Set<String> = []  // e.g. ["com.apple.systempreferences"]

let storeURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/WindowMemory/layouts.json")

func log(_ items: Any...) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)]", items.map { "\($0)" }.joined(separator: " "))
    fflush(stdout)
}

// MARK: - Model

/// Window frame as fractions (0...1) of a screen's visible frame.
struct WinInfo: Codable {
    var screen: String?   // display UUID; nil = "whatever screen the window is on now"
    var x, y, w, h: Double
}

struct Layout: Codable {
    var byId: [String: WinInfo] = [:]     // CGWindowID -> info (valid within one login session)
    var byTitle: [String: WinInfo] = [:]  // "bundleID|title" -> info (survives app relaunches)
}

struct Store: Codable {
    var session: String?                  // login session the byId entries belong to
    var layouts: [String: Layout] = [:]   // display-setup key -> layout
}

// MARK: - Screens

struct ScreenInfo {
    let uuid: String
    let frame: CGRect   // visible frame in Accessibility coordinates (top-left origin)
}

func currentScreens() -> [ScreenInfo] {
    guard let primary = NSScreen.screens.first else { return [] }
    let primaryHeight = primary.frame.height
    return NSScreen.screens.compactMap { s in
        guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let cfUUID = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(num.uint32Value))?.takeRetainedValue(),
              let uuid = CFUUIDCreateString(nil, cfUUID) as String?
        else { return nil }
        let v = s.visibleFrame
        return ScreenInfo(uuid: uuid,
                          frame: CGRect(x: v.minX, y: primaryHeight - v.maxY, width: v.width, height: v.height))
    }
}

func configKey(_ screens: [ScreenInfo] = currentScreens()) -> String {
    screens.map(\.uuid).sorted().joined(separator: "+")
}

/// The display setup as the WindowServer reports it right now. NSScreen.screens
/// is AppKit's cached copy and only updates once the main run loop handles the
/// change, so it can lag behind macOS moving windows. Only compare this with an
/// earlier value of itself.
func liveConfigKey() -> String {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return "" }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return "" }
    return ids.prefix(Int(count))
        .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        .compactMap { CGDisplayCreateUUIDFromDisplayID($0)?.takeRetainedValue() }
        .map { CFUUIDCreateString(nil, $0) as String }
        .sorted()
        .joined(separator: "+")
}

func screen(for rect: CGRect, in screens: [ScreenInfo]) -> ScreenInfo? {
    let best = screens.max { a, b in
        let ia = a.frame.intersection(rect), ib = b.frame.intersection(rect)
        return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
    }
    if let best, !best.frame.intersection(rect).isNull { return best }
    // Window is off every screen: pick the screen whose center is closest.
    let c = CGPoint(x: rect.midX, y: rect.midY)
    return screens.min { a, b in
        hypot(a.frame.midX - c.x, a.frame.midY - c.y) < hypot(b.frame.midX - c.x, b.frame.midY - c.y)
    }
}

// MARK: - Accessibility helpers

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func axCopy(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func axBool(_ el: AXUIElement, _ name: String) -> Bool {
    (axCopy(el, name) as? Bool) ?? false
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let p = axCopy(el, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = axCopy(el, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID()
    else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func axSetFrame(_ el: AXUIElement, _ r: CGRect) {
    var pt = r.origin, sz = r.size
    guard let p = AXValueCreate(.cgPoint, &pt), let s = AXValueCreate(.cgSize, &sz) else { return }
    // Position, size, position: moving first lets the size fit on the target
    // screen; moving again fixes apps that clamp position while resizing.
    AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, p)
    AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, s)
    AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, p)
}

struct Win {
    let element: AXUIElement
    let pid: pid_t
    let windowID: CGWindowID?
    let bundleID: String
    let title: String
    let frame: CGRect

    var idKey: String? { windowID.map { String($0) } }
    var titleKey: String { "\(bundleID)|\(title)" }
    var pendingKey: String { idKey.map { "id:\($0)" } ?? "t:\(titleKey)" }
}

func listWindows(pid onlyPID: pid_t? = nil) -> [Win] {
    var out: [Win] = []
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular && app.processIdentifier != getpid() {
        let pid = app.processIdentifier
        if let onlyPID, pid != onlyPID { continue }
        let bundle = app.bundleIdentifier ?? "?"
        if ignoredBundleIDs.contains(bundle) { continue }

        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.5)  // don't hang on unresponsive apps
        guard let list = axCopy(axApp, kAXWindowsAttribute) as? [AXUIElement] else { continue }

        for w in list {
            guard (axCopy(w, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
                  !axBool(w, kAXMinimizedAttribute),
                  !axBool(w, "AXFullScreen"),
                  let f = axFrame(w), f.width > 50, f.height > 50
            else { continue }
            var wid: CGWindowID = 0
            let hasID = _AXUIElementGetWindow(w, &wid) == .success && wid != 0
            out.append(Win(element: w, pid: pid, windowID: hasID ? wid : nil, bundleID: bundle,
                           title: (axCopy(w, kAXTitleAttribute) as? String) ?? "", frame: f))
        }
    }
    return out
}

func systemBootTime() -> Double {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    sysctl(&mib, 2, &tv, &size, nil, 0)
    return Double(tv.tv_sec)
}

/// Identifies this boot and login session. Window IDs are only unique within
/// one: the WindowServer starts numbering again after a logout, not just after
/// a reboot. The audit session ID is new for every login.
func loginSessionID() -> String {
    var info = auditinfo_addr()
    let asid = getaudit_addr(&info, Int32(MemoryLayout<auditinfo_addr>.size)) == 0 ? Int(info.ai_asid) : -1
    return "\(Int(systemBootTime()))-\(asid)"
}

func isAccessibilityTrusted(prompt: Bool) -> Bool {
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
}

// MARK: - Window memory

final class WindowMemory: NSObject, NSMenuDelegate {
    private var store = Store()
    private var currentConfig = configKey()
    private var currentLiveConfig = liveConfigKey()
    private var configBeforeChange: String?
    private var paused = false
    private var pending: [String: WinInfo] = [:]   // restores to re-apply when the app activates
    private var settleWork: DispatchWorkItem?
    private var timers: [Timer] = []
    private var statusItem: NSStatusItem!

    override init() {
        super.init()
        load()
        setupStatusItem()
        registerHotKeys()

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // The WindowServer calls this before it reconfigures the displays (and
        // so before it moves any windows), which lets us stop saving in time.
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard let userInfo else { return }
            let memory = Unmanaged<WindowMemory>.fromOpaque(userInfo).takeUnretainedValue()
            let handle = {
                if flags.contains(.beginConfigurationFlag) {
                    memory.beginDisplayChange()
                } else {
                    memory.screensChanged()
                }
            }
            if Thread.isMainThread { handle() } else { DispatchQueue.main.sync(execute: handle) }
        }, Unmanaged.passUnretained(self).toOpaque())

        timers.append(Timer.scheduledTimer(withTimeInterval: saveInterval, repeats: true) { [weak self] _ in
            self?.snapshot()
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: persistInterval, repeats: true) { [weak self] _ in
            self?.save()
        })

        if !isAccessibilityTrusted(prompt: true) {
            log("Accessibility access not granted yet; waiting.")
        }
        snapshot()
        log("started; display setup =", currentConfig, "screens =", currentScreens().count)
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: storeURL),
           let s = try? JSONDecoder().decode(Store.self, from: data) {
            store = s
        }
        // Window IDs from an earlier login session may now belong to other windows.
        let session = loginSessionID()
        if store.session != session {
            for k in store.layouts.keys { store.layouts[k]?.byId = [:] }
            store.session = session
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(store).write(to: storeURL, options: .atomic)
        } catch {
            log("save failed:", error)
        }
    }

    // MARK: Snapshot

    func snapshot() {
        guard !paused else { return }
        // A window may be mid-drag: don't record (or rescale) it until it's dropped.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let screens = currentScreens()
        // Displays changed but we haven't been told yet: don't record the
        // positions macOS just shuffled around.
        guard setupUnchanged(screens) else { return }

        var layout = store.layouts[currentConfig] ?? Layout()
        for w in listWindows() where pending[w.pendingKey] == nil {
            guard let s = screen(for: w.frame, in: screens) else { continue }
            var frame = w.frame
            // Moved to another display since the last snapshot (by you or by
            // Stage Manager): keep it the same fraction of the new display.
            // Matched by window ID only, so a new window that merely shares a
            // title is never resized.
            if scaleOnScreenMove, let id = w.idKey, let old = layout.byId[id],
               let from = old.screen, from != s.uuid, screens.contains(where: { $0.uuid == from }) {
                let target = scaled(old, droppedAt: frame.origin, onto: s)
                axSetFrame(w.element, target)
                frame = axFrame(w.element) ?? target
            }
            let info = WinInfo(screen: s.uuid,
                               x: (frame.minX - s.frame.minX) / s.frame.width,
                               y: (frame.minY - s.frame.minY) / s.frame.height,
                               w: frame.width / s.frame.width,
                               h: frame.height / s.frame.height)
            if let id = w.idKey { layout.byId[id] = info }
            layout.byTitle[w.titleKey] = info
        }
        // Reading every window takes a moment; if the displays started changing
        // meanwhile, some of these frames may already be shuffled. Drop them all.
        guard !paused, setupUnchanged(screens) else { return }
        store.layouts[currentConfig] = layout
    }

    private func setupUnchanged(_ screens: [ScreenInfo]) -> Bool {
        configKey(screens) == currentConfig && liveConfigKey() == currentLiveConfig
    }

    // MARK: Restore

    private func lookup(_ layout: Layout?, _ w: Win) -> WinInfo? {
        guard let layout else { return nil }
        if let id = w.idKey, let info = layout.byId[id] { return info }
        return layout.byTitle[w.titleKey]
    }

    /// `old`'s size as a fraction of `s`, kept where the window was dropped but
    /// nudged so it fits on `s`.
    private func scaled(_ old: WinInfo, droppedAt origin: CGPoint, onto s: ScreenInfo) -> CGRect {
        let width = min(old.w * s.frame.width, s.frame.width)
        let height = min(old.h * s.frame.height, s.frame.height)
        let x = min(max(origin.x, s.frame.minX), s.frame.maxX - width)
        let y = min(max(origin.y, s.frame.minY), s.frame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height).integral
    }

    private func targetFrame(_ info: WinInfo, _ w: Win, _ screens: [ScreenInfo]) -> CGRect? {
        guard let s = screens.first(where: { $0.uuid == info.screen })
                ?? screen(for: w.frame, in: screens) ?? screens.first
        else { return nil }
        return CGRect(x: s.frame.minX + info.x * s.frame.width,
                      y: s.frame.minY + info.y * s.frame.height,
                      width: info.w * s.frame.width,
                      height: info.h * s.frame.height).integral
    }

    /// Applies `info` to `w`. Returns true if the window ended up where we asked.
    @discardableResult
    private func apply(_ info: WinInfo, to w: Win, _ screens: [ScreenInfo]) -> Bool {
        guard let target = targetFrame(info, w, screens) else { return true }
        axSetFrame(w.element, target)
        guard let now = axFrame(w.element) else { return false }
        return abs(now.minX - target.minX) < 4 && abs(now.minY - target.minY) < 4
            && abs(now.width - target.width) < 4 && abs(now.height - target.height) < 4
    }

    /// Restores the saved layout for the current display setup. Windows with no
    /// saved position here are scaled proportionally from `previous`.
    @discardableResult
    func restore(from previous: String?) -> Int {
        let screens = currentScreens()
        let layout = store.layouts[currentConfig]
        let prevLayout = previous.flatMap { store.layouts[$0] }
        pending = [:]
        var count = 0

        for w in listWindows() {
            var info = lookup(layout, w)
            if info == nil, var p = lookup(prevLayout, w) {
                p.screen = nil   // scale onto whichever screen it's on now
                info = p
            }
            guard let info else { continue }
            count += 1
            // Stage Manager may ignore moves for windows in background stages;
            // retry those when their app is activated.
            if !apply(info, to: w, screens) { pending[w.pendingKey] = info }
        }
        return count
    }

    // MARK: Events

    /// Stops saving until the display change has settled. Safe to call repeatedly.
    fileprivate func beginDisplayChange() {
        guard !paused else { return }
        paused = true
        configBeforeChange = currentConfig
        save()
    }

    @objc fileprivate func screensChanged() {
        if !paused && configKey() == currentConfig && liveConfigKey() == currentLiveConfig { return }
        beginDisplayChange()
        // macOS often fires several notifications per change; act once it settles.
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finishDisplayChange() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }

    private func finishDisplayChange() {
        currentConfig = configKey()
        currentLiveConfig = liveConfigKey()
        let previous = configBeforeChange == currentConfig ? nil : configBeforeChange
        let hadLayout = store.layouts[currentConfig] != nil
        let n = restore(from: previous)
        paused = false
        log("display setup changed ->", currentConfig,
            hadLayout ? "restored" : "scaled", n, "windows;", pending.count, "pending")
        flash(hadLayout ? "↺ \(n)" : "⤢ \(n)")
    }

    @objc private func appActivated(_ note: Notification) {
        guard !paused, !pending.isEmpty,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let pid = app.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let screens = currentScreens()
            for w in listWindows(pid: pid) {
                if let info = self.pending.removeValue(forKey: w.pendingKey) {
                    self.apply(info, to: w, screens)
                }
            }
        }
    }

    // MARK: Actions

    @objc func saveNow() {
        pending = [:]
        snapshot()
        save()
        flash("✓ saved")
    }

    @objc func restoreNow() {
        let n = restore(from: nil)
        flash("↺ \(n)")
    }

    @objc func forgetSetup() {
        store.layouts[currentConfig] = nil
        pending = [:]
        save()
        flash("forgot")
    }

    @objc func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func quit() {
        snapshot()
        save()
        NSApp.terminate(nil)
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                           accessibilityDescription: "Window Memory")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if !isAccessibilityTrusted(prompt: false) {
            menu.addItem(item("⚠︎ Grant Accessibility Access…", #selector(openAccessibilitySettings)))
            menu.addItem(.separator())
        }
        let screens = currentScreens().count
        let saved = store.layouts[currentConfig]?.byTitle.count ?? 0
        let info = NSMenuItem(title: "\(screens) display\(screens == 1 ? "" : "s") · \(saved) windows remembered",
                              action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(item("Save Layout Now  (⌃⌥⌘S)", #selector(saveNow)))
        menu.addItem(item("Restore Layout  (⌃⌥⌘R)", #selector(restoreNow)))
        menu.addItem(item("Forget This Display Setup  (⌃⌥⌘X)", #selector(forgetSetup)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Window Memory", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    /// Briefly shows a message next to the menu-bar icon.
    private func flash(_ text: String) {
        statusItem.button?.title = " " + text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.statusItem.button?.title = ""
        }
    }

    // MARK: Global hotkeys (Carbon; needs no extra permission)

    private func registerHotKeys() {
        hotKeyActions = [1: { [weak self] in self?.saveNow() },
                         2: { [weak self] in self?.restoreNow() },
                         3: { [weak self] in self?.forgetSetup() }]
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { hotKeyActions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)

        let mods = UInt32(controlKey | optionKey | cmdKey)
        for (id, key) in [(1, kVK_ANSI_S), (2, kVK_ANSI_R), (3, kVK_ANSI_X)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), mods,
                                EventHotKeyID(signature: OSType(0x574D454D), id: UInt32(id)),  // 'WMEM'
                                GetApplicationEventTarget(), 0, &ref)
        }
    }
}

var hotKeyActions: [UInt32: () -> Void] = [:]

// MARK: - Main

if CommandLine.arguments.contains("--status") {
    let screens = currentScreens()
    print("Display setup:", configKey(screens))
    print("WindowServer: ", liveConfigKey())
    for s in screens { print("  screen", s.uuid, s.frame) }
    print("Accessibility trusted:", isAccessibilityTrusted(prompt: false))
    if let data = try? Data(contentsOf: storeURL), let s = try? JSONDecoder().decode(Store.self, from: data) {
        for (k, l) in s.layouts { print("Saved setup \(k): \(l.byTitle.count) windows") }
    } else {
        print("No saved layouts yet at", storeURL.path)
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let windowMemory = WindowMemory()
signal(SIGTERM) { _ in DispatchQueue.main.async { windowMemory.quit() } }
app.run()

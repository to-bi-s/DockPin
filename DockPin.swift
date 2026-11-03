import Cocoa

// DockPin — keeps the macOS Dock on one display.
//
// How it works:
// A Dock set to the left edge always rests on the display whose CENTER is
// leftmost in the logical arrangement (verified empirically: edge positions
// don't matter), and macOS re-derives that on every Dock launch and display
// change. There is no API or preference to override it, and the "push the
// pointer against the edge" gesture is detected inside WindowServer from raw
// hardware input, so it can't be simulated either.
//
// DockPin therefore fixes the arrangement instead:
//   - If the pinned display is the main display (immovable — it anchors the
//     coordinate space), every display whose center lies left of it is moved
//     to the far right of the arrangement.
//   - Otherwise the pinned display itself is moved to the far left.
// Each moved display's real (physical) position is remembered, and a HID-level
// event tap teleports the pointer through "wormholes" at the old seams —
// pushing against an edge where a neighbor physically lives jumps the pointer
// there and back, with coordinates mapped between the physical and logical
// positions, so mouse travel feels exactly like the physical layout. Quitting
// DockPin restores the recorded arrangement.
//
// The tap also stops the pointer a few pixels short of the Dock edge and the
// bottom edge of every other display, so the Dock-move gesture can never
// relocate the Dock.
//
// Usage:
//   DockPin                        pin the Dock to the main display (the one with the menu bar)
//   DockPin --display "iMac"       pin it to the display whose name contains "iMac"
//   DockPin --margin 4             stop the pointer N px short of a blocked edge (default 3)

private let physicalOriginsKey = "PhysicalOrigins"
private let pinnedNameKey = "PinnedDisplayName"
private let pinnedSelectionKey = "PinnedSelection"

// Removed from the Swift SDK but still exported by CoreGraphics. Zeroing the
// interval removes the brief input stall that follows CGWarpMouseCursorPosition,
// which otherwise makes wormhole crossings feel like the cursor sticks.
@_silgen_name("CGSetLocalEventsSuppressionInterval")
private func CGSetLocalEventsSuppressionIntervalShim(_ seconds: Double) -> Int32

/// One direction of one seam: a trigger strip on a display's current edge that
/// teleports the pointer to where the physical neighbor now lives.
struct Wormhole {
    let vertical: Bool       // vertical seam (left/right edges) vs horizontal (top/bottom)
    let line: CGFloat        // the source edge (x for vertical, y for horizontal)
    let outward: CGFloat     // +1 = crossing increases the coordinate (right/down), -1 = decreases
    let lo, hi: CGFloat      // trigger range along the edge (y for vertical, x for horizontal)
    let perpShift: CGFloat   // added to the along-edge coordinate when landing
    let dstLine: CGFloat     // the destination edge
    let dstDir: CGFloat      // +1 = land at dstLine + carry, -1 = at dstLine - carry
}

final class DockPin {
    private(set) var pinnedID: CGDirectDisplayID = CGMainDisplayID()
    private(set) var pinnedName = "main display"
    private(set) var orientation = "bottom"
    private(set) var blockedCount = 0
    private(set) var crossingCount = 0
    private(set) var relocatedNames: [String] = []
    var paused = false
    var quitting = false
    /// Exact display name chosen in the menu; wins over the --display filter.
    var preferredName: String?

    private let displayFilter: String?
    private let margin: CGFloat
    private var allBounds: [CGRect] = []
    private var otherBounds: [CGRect] = []
    private var wormholes: [Wormhole] = []
    private var tap: CFMachPort?
    private var relocating = false
    private var lastWormholeSummary = ""
    private var appliedPinnedName: String?       // in-memory: immune to stale defaults reads
    private var lastConfigureAt = Date.distantPast
    private var lastMoveTarget = ""
    private var sameMoveCount = 0
    private(set) var relocationHalted = false
    private var lastDisplayChange = Date.distantPast   // ours or the system's
    private var refreshScheduled = false
    private var dockMissingChecks = 0
    private var dockRestartedForPin = false

    /// Display bounds update asynchronously after any reconfiguration, so
    /// arrangement decisions are only made once things have been quiet for a second.
    private var settled: Bool { Date().timeIntervalSince(lastDisplayChange) > 1.0 }

    func noteDisplayChange() { lastDisplayChange = Date() }

    private func scheduleRefresh(after seconds: Double) {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }
    private var vx: Double = 0   // smoothed pointer velocity, px per event
    private var vy: Double = 0
    private var justTeleported = false

    init(displayFilter: String?, margin: CGFloat) {
        self.displayFilter = displayFilter
        self.margin = margin
    }

    // MARK: display and Dock state

    private func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    private func storedOrigins() -> [String: [Double]] {
        UserDefaults.standard.dictionary(forKey: physicalOriginsKey) as? [String: [Double]] ?? [:]
    }

    func refresh() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        ids = Array(ids.prefix(Int(count)))

        pinnedID = CGMainDisplayID()
        pinnedName = "main display"
        if let name = preferredName,
           let screen = NSScreen.screens.first(where: { $0.localizedName == name }),
           let sid = screenID(screen) {
            pinnedID = sid
            pinnedName = screen.localizedName
        } else if let filter = displayFilter?.lowercased(),
           let screen = NSScreen.screens.first(where: { $0.localizedName.lowercased().contains(filter) }),
           let sid = screenID(screen) {
            pinnedID = sid
            pinnedName = screen.localizedName
        } else if let screen = NSScreen.screens.first(where: { screenID($0) == pinnedID }) {
            pinnedName = screen.localizedName
        }

        // A different pinned display means the remembered moves no longer fit:
        // put everything back to physical first and start from a clean slate.
        // The comparison is held in memory: a stale defaults read must never be
        // able to re-trigger this every refresh (that once strobed the displays).
        if appliedPinnedName == nil {
            appliedPinnedName = UserDefaults.standard.string(forKey: pinnedNameKey) ?? pinnedName
        }
        if appliedPinnedName != pinnedName {
            if !storedOrigins().isEmpty {
                NSLog("DockPin: pinned display changed to \(pinnedName) — resetting arrangement first")
                undoRelocations()
            }
            appliedPinnedName = pinnedName
            clearBackoff()
        }
        UserDefaults.standard.set(pinnedName, forKey: pinnedNameKey)

        // Everything below reads display bounds; wait for them to be stable.
        guard settled else { scheduleRefresh(after: 0.6); return }

        let moved = relocateForPinned()
        if moved { scheduleRefresh(after: 1.5); return }   // re-evaluate once applied

        allBounds = ids.map { CGDisplayBounds($0) }
        otherBounds = ids.filter { $0 != pinnedID }.map { CGDisplayBounds($0) }
        rebuildWormholes()
        verifyDockPlacement()

        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        orientation = (CFPreferencesCopyAppValue("orientation" as CFString,
                                                 "com.apple.dock" as CFString) as? String) ?? "bottom"
    }

    /// True if the Dock currently occupies the pinned display's Dock edge.
    func dockIsOnPinned() -> Bool {
        guard let screen = NSScreen.screens.first(where: { screenID($0) == pinnedID })
        else { return true }
        let f = screen.frame, v = screen.visibleFrame
        switch orientation {
        case "left":  return v.minX > f.minX
        case "right": return v.maxX < f.maxX
        default:      return v.minY > f.minY
        }
    }

    // MARK: arrangement

    /// Lets rearranging try again (after a user action or a real display change).
    func clearBackoff() {
        lastMoveTarget = ""
        sameMoveCount = 0
        relocationHalted = false
        dockMissingChecks = 0
        dockRestartedForPin = false
    }

    private func configureOrigin(_ id: CGDirectDisplayID, _ name: String, from: CGRect, to: CGPoint) {
        // Backoff: if the same move keeps being needed, WindowServer is
        // reverting it (or something else is fighting us). Repeating it every
        // refresh would strobe the displays, so stop trying until something
        // changes. Also never move displays more often than every 5 seconds.
        let target = "\(name)→(\(Int(to.x)),\(Int(to.y)))"
        guard !relocationHalted else { return }
        if target == lastMoveTarget {
            // Only RETRIES of one and the same move are spaced out and counted
            // toward the halt; a first-time move always runs at once, so
            // legitimate quick switching is never skipped.
            sameMoveCount += 1
            if sameMoveCount >= 4 {
                relocationHalted = true
                NSLog("DockPin: move \(target) did not stick after 3 attempts — halting rearrangement")
                return
            }
            guard Date().timeIntervalSince(lastConfigureAt) > 5 else { return }
        } else {
            lastMoveTarget = target
            sameMoveCount = 1
        }
        lastConfigureAt = Date()

        var origins = storedOrigins()
        if origins[name] == nil {
            origins[name] = [Double(from.minX), Double(from.minY)]
            UserDefaults.standard.set(origins, forKey: physicalOriginsKey)
        }
        relocating = true
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayOrigin(config, id, Int32(to.x), Int32(to.y))
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        relocating = false
        noteDisplayChange()
        NSLog("DockPin: moved \(name) from (\(Int(from.minX)), \(Int(from.minY))) to (\(Int(to.x)), \(Int(to.y))) — \(err == .success ? "ok" : String(describing: err))")
        relocatedNames = Array(storedOrigins().keys)
    }

    /// Rearranges displays so the pinned one has the strictly leftmost center,
    /// which is where a left-edge Dock rests.
    @discardableResult
    private func relocateForPinned() -> Bool {
        guard !relocating, !quitting else { return false }
        relocatedNames = Array(storedOrigins().keys)

        let pinnedBounds = CGDisplayBounds(pinnedID)
        let others: [(id: CGDirectDisplayID, name: String, bounds: CGRect)] = NSScreen.screens.compactMap {
            guard let id = screenID($0), id != pinnedID else { return nil }
            return (id, $0.localizedName, CGDisplayBounds(id))
        }
        guard let minOtherCenter = others.map({ $0.bounds.midX }).min(),
              minOtherCenter <= pinnedBounds.midX + 0.5 else { return false }

        if pinnedID == CGMainDisplayID() {
            // The main display can't be moved, so send every display whose
            // center lies left of it to the far right.
            for other in others where other.bounds.midX <= pinnedBounds.midX + 0.5 {
                let rightmost = ([pinnedBounds] + others.map { CGDisplayBounds($0.id) }).map { $0.maxX }.max()!
                configureOrigin(other.id, other.name, from: other.bounds,
                                to: CGPoint(x: rightmost, y: other.bounds.minY))
            }
        } else {
            // One move resolves everything: put the pinned display at the far left.
            let leftmost = others.min { $0.bounds.minX < $1.bounds.minX }!
            configureOrigin(pinnedID, pinnedName, from: pinnedBounds,
                            to: CGPoint(x: leftmost.bounds.minX - pinnedBounds.width,
                                        y: leftmost.bounds.minY))
        }
        return true
    }

    /// The arrangement is as intended, so the Dock should be on the pinned
    /// display. If it still isn't after two settled checks, the Dock kept a
    /// stale decision (seen after rapid switching): restart it once per pin so
    /// it re-derives its display from the current arrangement.
    private func verifyDockPlacement() {
        guard !paused, !quitting else { return }
        if dockIsOnPinned() { dockMissingChecks = 0; return }
        dockMissingChecks += 1
        guard dockMissingChecks >= 2, !dockRestartedForPin else { return }
        dockRestartedForPin = true
        NSLog("DockPin: arrangement is right but the Dock is not on \(pinnedName) — restarting the Dock so it re-derives")
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.terminate()
        scheduleRefresh(after: 3)
    }

    /// Puts every moved display back to its physical position and forgets it.
    /// One transaction, so the arrangement lands exactly as it was.
    func undoRelocations() {
        let origins = storedOrigins()
        guard !origins.isEmpty else { return }
        relocating = true
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        for (name, origin) in origins {
            guard origin.count == 2,
                  let screen = NSScreen.screens.first(where: { $0.localizedName == name }),
                  let id = screenID(screen) else { continue }
            CGConfigureDisplayOrigin(config, id, Int32(origin[0]), Int32(origin[1]))
            NSLog("DockPin: restoring \(name) to (\(Int(origin[0])), \(Int(origin[1])))")
        }
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        relocating = false
        noteDisplayChange()
        NSLog("DockPin: arrangement restored — \(err == .success ? "ok" : String(describing: err))")
        UserDefaults.standard.removeObject(forKey: physicalOriginsKey)
        relocatedNames = []
    }

    /// Builds two directional wormholes per physical seam whose displays no
    /// longer sit in their physical relationship. Coordinates are mapped
    /// between physical and logical positions on both sides, so this works no
    /// matter which display of a seam moved, and in which direction.
    private func rebuildWormholes() {
        wormholes = []
        let origins = storedOrigins()

        struct Info { let phys: CGRect; let cur: CGRect; let dx: CGFloat; let dy: CGFloat }
        var infos: [Info] = []
        for screen in NSScreen.screens {
            guard let id = screenID(screen) else { continue }
            let cur = CGDisplayBounds(id)
            var phys = cur
            if let o = origins[screen.localizedName], o.count == 2 {
                phys = CGRect(x: o[0], y: o[1], width: cur.width, height: cur.height)
            }
            infos.append(Info(phys: phys, cur: cur,
                              dx: cur.minX - phys.minX, dy: cur.minY - phys.minY))
        }

        for a in infos {
            for b in infos where !(a.cur == b.cur) {
                // the seam only needs wormholes if the pair's relative position changed
                guard abs(a.dx - b.dx) > 4 || abs(a.dy - b.dy) > 4 else { continue }

                // vertical seam: a's physical right edge against b's physical left edge
                if abs(a.phys.maxX - b.phys.minX) < 2 {
                    let lo = max(a.phys.minY, b.phys.minY), hi = min(a.phys.maxY, b.phys.maxY)
                    if hi - lo > 1 {
                        wormholes.append(Wormhole(vertical: true, line: a.cur.maxX, outward: 1,
                                                  lo: lo + a.dy, hi: hi + a.dy, perpShift: b.dy - a.dy,
                                                  dstLine: b.cur.minX, dstDir: 1))
                        wormholes.append(Wormhole(vertical: true, line: b.cur.minX, outward: -1,
                                                  lo: lo + b.dy, hi: hi + b.dy, perpShift: a.dy - b.dy,
                                                  dstLine: a.cur.maxX, dstDir: -1))
                    }
                }
                // horizontal seam: a's physical bottom edge against b's physical top edge
                if abs(a.phys.maxY - b.phys.minY) < 2 {
                    let lo = max(a.phys.minX, b.phys.minX), hi = min(a.phys.maxX, b.phys.maxX)
                    if hi - lo > 1 {
                        wormholes.append(Wormhole(vertical: false, line: a.cur.maxY, outward: 1,
                                                  lo: lo + a.dx, hi: hi + a.dx, perpShift: b.dx - a.dx,
                                                  dstLine: b.cur.minY, dstDir: 1))
                        wormholes.append(Wormhole(vertical: false, line: b.cur.minY, outward: -1,
                                                  lo: lo + b.dx, hi: hi + b.dx, perpShift: a.dx - b.dx,
                                                  dstLine: a.cur.maxY, dstDir: -1))
                    }
                }
            }
        }

        let summary = wormholes.map {
            "\($0.vertical ? "v" : "h") \(Int($0.lo))..\(Int($0.hi)) @\(Int($0.line))→\(Int($0.dstLine))"
        }.joined(separator: ", ")
        if summary != lastWormholeSummary {
            NSLog("DockPin: \(wormholes.count) wormhole(s): \(summary.isEmpty ? "none" : summary)")
        }
        lastWormholeSummary = summary
    }

    // MARK: pointer handling

    private func isDisplay(at p: CGPoint) -> Bool {
        allBounds.contains { $0.contains(p) }
    }

    /// Teleport target if `p` is pushing through a wormhole, else nil.
    /// The landing point carries the pointer's own momentum, so a fast flick
    /// continues into the far screen instead of parking at the seam.
    private func throughWormhole(_ p: CGPoint, dx: Int64, dy: Int64) -> CGPoint? {
        for w in wormholes {
            let along = w.vertical ? p.y : p.x
            guard along >= w.lo, along < w.hi else { continue }
            let across = w.vertical ? p.x : p.y
            let delta = w.vertical ? dx : dy
            let v = w.vertical ? vx : vy

            // Trigger strips reach past the clamp margin, since the gesture
            // guard may hold the pointer `margin` px short of a blocked edge.
            let pushing: Bool = w.outward > 0
                ? delta > 0 && across >= w.line - (margin + 2.5) && across < w.line
                : delta < 0 && across >= w.line && across <= w.line + margin + 1.5
            guard pushing else { continue }

            // Minimum carry of 8 lands the pointer outside all trigger strips.
            let carry = CGFloat(min(max(abs(Int(delta)), Int(abs(v)), 8), 300))
            let landing = w.dstLine + w.dstDir * carry
            return w.vertical ? CGPoint(x: landing, y: p.y + w.perpShift)
                              : CGPoint(x: p.x + w.perpShift, y: landing)
        }
        return nil
    }

    /// Corrected pointer position if `p` is inside a blocked Dock-gesture edge
    /// zone on a non-pinned display, else nil. Global CG coordinates.
    private func clamped(_ p: CGPoint) -> CGPoint? {
        for r in otherBounds where r.contains(p) {
            // The Dock-move gesture may fire on the Dock's own edge or on the
            // bottom edge, so block both on every non-pinned display.
            if orientation == "left", p.x < r.minX + margin, !isDisplay(at: CGPoint(x: r.minX - 1, y: p.y)) {
                return CGPoint(x: r.minX + margin, y: p.y)
            }
            if orientation == "right", p.x > r.maxX - 1 - margin, !isDisplay(at: CGPoint(x: r.maxX, y: p.y)) {
                return CGPoint(x: r.maxX - 1 - margin, y: p.y)
            }
            if p.y > r.maxY - 1 - margin, !isDisplay(at: CGPoint(x: p.x, y: r.maxY)) {
                return CGPoint(x: p.x, y: r.maxY - 1 - margin)
            }
            return nil
        }
        return nil
    }

    // MARK: event tap

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard !paused else { return Unmanaged.passUnretained(event) }
        let p = event.location
        let dx = event.getIntegerValueField(.mouseEventDeltaX)
        let dy = event.getIntegerValueField(.mouseEventDeltaY)

        // The first event after a warp can report the warp's own displacement
        // as a giant delta. Swallow it so it neither re-triggers a wormhole
        // nor reaches apps as a jerk.
        if justTeleported {
            justTeleported = false
            if abs(dx) > 500 || abs(dy) > 500 {
                event.setIntegerValueField(.mouseEventDeltaX, value: 0)
                event.setIntegerValueField(.mouseEventDeltaY, value: 0)
                return Unmanaged.passUnretained(event)
            }
        }
        vx = vx * 0.7 + Double(max(-200, min(200, dx))) * 0.3
        vy = vy * 0.7 + Double(max(-200, min(200, dy))) * 0.3

        if let q = throughWormhole(p, dx: dx, dy: dy) {
            crossingCount += 1
            justTeleported = true
            event.location = q      // deltas stay intact: motion continues across the seam
            CGWarpMouseCursorPosition(q)
            CGAssociateMouseAndMouseCursorPosition(1)
            return Unmanaged.passUnretained(event)
        }

        guard let q = clamped(p) else { return Unmanaged.passUnretained(event) }
        blockedCount += 1
        event.location = q
        if q.x != p.x { event.setIntegerValueField(.mouseEventDeltaX, value: 0) }
        if q.y != p.y { event.setIntegerValueField(.mouseEventDeltaY, value: 0) }
        CGWarpMouseCursorPosition(q)
        CGAssociateMouseAndMouseCursorPosition(1) // cancels the post-warp input suppression
        return Unmanaged.passUnretained(event)
    }

    func start() -> Bool {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask: CGEventMask = types.reduce(0) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let pin = Unmanaged<DockPin>.fromOpaque(refcon).takeUnretainedValue()
            return pin.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { NSLog("DockPin: CGEvent.tapCreate failed"); return false }
        _ = CGSetLocalEventsSuppressionIntervalShim(0.0)
        NSLog("DockPin: event tap installed, warp suppression interval zeroed")

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }
}

// MARK: - menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let pin: DockPin
    private var statusItem: NSStatusItem!
    private var running = false
    private var lastOnPinned: Bool?

    init(pin: DockPin) { self.pin = pin }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a second copy (e.g. opened from Finder while the
        // login item runs) exits at once — via exit(), not terminate(), so it
        // never runs the quit-time arrangement restore under the owner.
        let mine = ProcessInfo.processInfo.processIdentifier
        let twins = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.tobi.DockPin")
            .filter { $0.processIdentifier != mine }
        if !twins.isEmpty {
            NSLog("DockPin: another instance is already running (pid \(twins[0].processIdentifier)) — exiting")
            exit(0)
        }

        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        pin.preferredName = UserDefaults.standard.string(forKey: pinnedSelectionKey)
        pin.refresh()

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        NSLog("DockPin: launched, accessibility trusted=\(trusted), pinned=\(pin.pinnedName), orientation=\(pin.orientation), dockOnPinned=\(pin.dockIsOnPinned())")
        if trusted {
            startTap()
        } else {
            // Wait until the user grants Accessibility access, then start.
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.startTap()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.pin.noteDisplayChange()
                self?.reload()
            }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.reload() }
        updateInfo()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pin.quitting = true
        pin.undoRelocations()
    }

    private func startTap() {
        if pin.start() {
            running = true
        } else {
            let alert = NSAlert()
            alert.messageText = "DockPin could not install its event tap."
            alert.informativeText = "Grant DockPin access under System Settings → Privacy & Security → Accessibility, then start it again."
            alert.runModal()
            NSApp.terminate(nil)
        }
        updateInfo()
    }

    private func reload() {
        pin.refresh()
        updateInfo()
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockPin") {
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "⚓"
        }
        let menu = NSMenu()
        menu.delegate = self   // items are rebuilt in menuNeedsUpdate on every open
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false   // a disabled row would draw its dot grayed out
        let active = running && !pin.paused && !pin.relocationHalted

        // Clicking the status row toggles pause. It is a custom view so the
        // click does NOT close the menu (native items always dismiss); the dot
        // and text re-render in place. Dot x matches the state column, text x
        // matches the other rows' titles.
        let status = NSMenuItem(title: "DockPin status", action: nil, keyEquivalent: "")
        let row = StatusToggleView()
        row.render(active: active)
        row.onToggle = { [weak self] in
            guard let self = self else { return false }
            self.pin.paused.toggle()
            self.updateInfo()
            return self.running && !self.pin.paused && !self.pin.relocationHalted
        }
        status.view = row
        status.toolTip = "Dock pinned to \(pin.pinnedName)"
            + (running ? "" : " — waiting for Accessibility access")
            + (pin.relocationHalted ? " — rearranging halted (a move kept being reverted); pick a screen to retry" : "")
            + (pin.relocatedNames.isEmpty ? "" : " — rearranged: \(pin.relocatedNames.joined(separator: ", "))")
            + " — \(pin.crossingCount) crossings, \(pin.blockedCount) pushes blocked"
        menu.addItem(status)
        menu.addItem(.separator())

        for screen in NSScreen.screens {
            let name = screen.localizedName
            let item = NSMenuItem(title: name,
                                  action: #selector(selectScreen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == pin.pinnedName ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let info = NSMenuItem(title: "Info", action: #selector(openInfo), keyEquivalent: "")
        info.target = self
        menu.addItem(info)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func selectScreen(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, name != pin.pinnedName else { return }
        NSLog("DockPin: user selected \(name)")
        UserDefaults.standard.set(name, forKey: pinnedSelectionKey)
        pin.preferredName = name
        pin.clearBackoff()
        pin.refresh()   // resets the old arrangement and applies the new one
        updateInfo()
    }

    @objc private func openInfo() {
        if let url = URL(string: "https://github.com/to-bi-s/DockPin") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateInfo() {
        let onPinned = pin.dockIsOnPinned()
        if onPinned != lastOnPinned {
            NSLog("DockPin: dock is now \(onPinned ? "on" : "off") the pinned display")
            lastOnPinned = onPinned
        }
        statusItem.button?.appearsDisabled = pin.paused || !running
    }

    @objc private func togglePause() {
        pin.paused.toggle()
        updateInfo()
    }

    /// 16pt menu dot like Neutron Calendar Bridge's status icons.
    static func statusDot(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 10, height: 10)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - status row view

/// The menu's first row: dot + "DockPin active/inactive". A click toggles
/// pause and re-renders in place, without dismissing the menu.
final class StatusToggleView: NSView {
    private let dotView = NSImageView(frame: NSRect(x: 11, y: 3, width: 16, height: 16))
    private let label = NSTextField(labelWithString: "")
    var onToggle: (() -> Bool)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        autoresizingMask = [.width]
        label.frame = NSRect(x: 29, y: 3, width: 180, height: 16)
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.autoresizingMask = [.width]
        addSubview(dotView)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func render(active: Bool) {
        dotView.image = AppDelegate.statusDot(active ? NSColor(red: 48/255, green: 182/255, blue: 69/255, alpha: 1)
                                                     : NSColor(red: 255/255, green: 74/255, blue: 62/255, alpha: 1))
        label.stringValue = "DockPin \(active ? "active" : "inactive")"
    }

    override func mouseUp(with event: NSEvent) {
        if let toggle = onToggle { render(active: toggle()) }
    }
}

// MARK: - entry point

var displayFilter: String?
var margin: CGFloat = 3
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--display": displayFilter = args.next()
    case "--margin":  if let v = args.next(), let m = Double(v) { margin = CGFloat(m) }
    default: break
    }
}

let app = NSApplication.shared
let delegate = AppDelegate(pin: DockPin(displayFilter: displayFilter, margin: margin))
app.delegate = delegate
app.run()

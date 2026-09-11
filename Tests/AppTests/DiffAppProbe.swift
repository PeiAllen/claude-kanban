import AppKit
import SwiftUI
import Foundation
import Darwin
import OrchestraCore
@testable import OrchestraUI

/// Exercises the real board/inspector hierarchy, replacing only the daemon transport.
/// The external Python watchdog remains effective when a native mouse tracker wedges the main loop.
@MainActor final class DiffAppProbe {
    private let host: NSView
    private let window: NSWindow
    private let model: BoardModel
    private let client: ControlClient
    private let transport: DiffFixtureTransport
    private let mode = diffCheckArgument("--mode")
    private let gesture = diffCheckArgument("--gesture", default: "knob")
    private let cycles = Int(diffCheckArgument("--cycles", default: "3"))!
    private let initialSplit = CommandLine.arguments.contains("--split")
    private let fileCount: Int
    private var timer: Timer?
    private var dragTimer: Timer?
    private var churnTimer: Timer?
    private var outer: NSScrollView?
    private var phaseStarted = 0.0
    private var phaseCPU: UInt64 = 0
    private var lastTick = 0.0
    private var maxGap = 0.0
    private var expectedHeight = 0.0
    private var maxMounted = 0
    private var wheelReachedBottom = false
    private var wheelReturnedTop = false
    private var wheelEvents = 0
    private var wheelLegs = 0
    private var wheelMinY: CGFloat = 0
    private var wheelMaxY: CGFloat = 0
    private var readyTicks = 0
    private var lastLoadDiagnostic = 0.0
    private var dragging = false
    private var dragStep = 0
    private var mouseEventNumber = 0
    private var drags = 0
    private var wantsSplit = false
    private var nextActionAt = 0.0
    private var startedAt = 0.0
    private(set) var phase = "startup"

    init() throws {
        let fixture = try String(contentsOfFile: diffCheckArgument("--fixture"), encoding: .utf8)
        fileCount = DiffFileParser.parse(fixture).count
        guard fileCount > 0 else { throw ProbeFailure("Fixture did not contain any diff files") }
        transport = DiffFixtureTransport(fixture: fixture)
        client = ControlClient(transport: { [transport] in transport })
        model = BoardModel(platform: .noop)
        model.injectClientForTesting(client)
        try client.connect()
        let cards = (0..<9).map { i in
            OrchestraCore.Task(title: "Diff fixture card \(i)", repo: "/private/tmp/orchestra-diff-fixture",
                branch: "fixture-\(i)", cwd: "/private/tmp/orchestra-diff-fixture",
                model: AgentModel(id: i.isMultiple(of: 2) ? "gpt-6-astra" : "claude-opus-4-8"),
                startIn: .plan, column: i < 3 ? .plan : i < 6 ? .impl : .review,
                order: i, phase: .live(.running), initialPrompt: "Private UI fixture")
        }
        model.tasks = cards
        for card in cards { model.selectedId = card.id; model.inspectorMode = .diff }
        model.selectedId = cards[0].id
        model.inspectorMode = .documents
        model.showOnboarding = false
        model.connected = true
        let hosting = NSHostingView(rootView: ContentView().environmentObject(BoardZoom())
            .environmentObject(model)
            .environment(\.theme, Theme(scheme: .light, accent: .blue))
            .preferredColorScheme(.light)
            .frame(minWidth: 940, minHeight: 580))
        hosting.sizingOptions = []
        host = hosting
        // Inspection keeps a normal closable window; accessory fixtures are closed by the runner.
        let windowStyle: NSWindow.StyleMask = diffCheckArgument("--mode") == "inspect"
            ? [.titled, .closable, .resizable] : [.titled, .resizable]
        window = DiffProbeWindow(contentRect: NSRect(x: 0, y: 1, width: 2560, height: 1409),
                          styleMask: windowStyle, backing: .buffered, defer: false,
                          screen: NSScreen.screens.first)
        window.title = "Private Orchestra diff checks"
        window.isMovable = false
        window.contentView = hosting
        window.isReleasedWhenClosed = false
    }

    func start() {
        startedAt = ProcessInfo.processInfo.systemUptime
        lastTick = startedAt
        window.orderFront(nil)
        DispatchQueue.main.async { [weak self] in
            NSApplication.shared.activate(ignoringOtherApps: true)
            self?.window.makeKeyAndOrderFront(nil)
        }
        let heartbeat = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = heartbeat
        RunLoop.main.add(heartbeat, forMode: .common)
        RunLoop.main.add(heartbeat, forMode: .eventTracking)
        if CommandLine.arguments.contains("--churn") {
            let churn = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.tasks[1].ctxPct = self.model.tasks[1].ctxPct < 80
                        ? self.model.tasks[1].ctxPct + 1 : 1
                }
            }
            churnTimer = churn
            RunLoop.main.add(churn, forMode: .common)
            RunLoop.main.add(churn, forMode: .eventTracking)
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        maxGap = max(maxGap, now - lastTick)
        lastTick = now
        if phase == "startup", now - startedAt >= 1 {
            window.setFrame(NSRect(x: 0, y: 1, width: 2560, height: 1409), display: true)
            // SwiftUI updates the picker's window coordinates after the resize. Give that layout
            // a run-loop turn before posting a mouse event at the segment's new position.
            phase = "window_settling"
            nextActionAt = now + 0.3
        } else if phase == "window_settling", now >= nextActionAt {
            if NSApplication.shared.isActive && window.occlusionState.contains(.visible) {
                if mode != "inspect" { requireFixedWindowFrame() }
                beginLoad("open_unified", segment: "Diff", split: false)
            } else {
                require(now - startedAt < 10, "Private test window did not become active and visible")
                // LaunchServices can still be completing the preceding private process's exit.
                // Establish foreground readiness before starting the load timing, not during it.
                NSApplication.shared.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                nextActionAt = now + 0.3
            }
        } else if phase.hasPrefix("open_") || phase == "switch_split" || phase == "reopen_unified" {
            checkLoaded()
        } else if phase.hasPrefix("scroll_") {
            checkStableGeometry()
            if mode == "benchmark" || gesture == "wheel" {
                advanceScrolling(now)
            } else if !dragging && now >= nextActionAt {
                if drags >= cycles * 2 { finishScroll() }
                else { beginDrag(down: drags.isMultiple(of: 2)) }
            }
        } else if phase == "settling", now >= nextActionAt {
            beginScroll()
        } else if phase == "inspection", now >= nextActionAt {
            pass()
        }
    }

    private func beginLoad(_ name: String, segment: String, split: Bool) {
        phase = name
        phaseStarted = ProcessInfo.processInfo.systemUptime
        phaseCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        lastTick = phaseStarted
        maxGap = 0
        readyTicks = 0
        lastLoadDiagnostic = 0
        wantsSplit = split
        outer = nil
        diffCheckOutput(["event": "load_start", "phase": phase,
            "app_active": NSApplication.shared.isActive, "window_visible": window.isVisible,
            "window_unoccluded": window.occlusionState.contains(.visible),
            "window_frame": NSStringFromRect(window.frame)])
        guard activateSegment(segment, mouseEvents: mode != "benchmark") else {
            fail("Could not activate native segment \(segment)")
        }
    }

    private func checkLoaded() {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let texts = descendants(host).compactMap { $0 as? DiffTextView }
        diagnoseLoadingIfNeeded(texts)
        guard !texts.isEmpty, texts.allSatisfy({ $0.frame.height > 0 && $0.showsBothNumbers != wantsSplit }) else { return }
        guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first(where: {
            !($0.documentView is DiffTextView) && descendants($0).contains(where: { $0 is DiffTextView })
        }), let document = scroll.documentView, document.frame.height > 0 else { return }
        readyTicks += 1
        guard readyTicks >= 2 else { return }
        require(window.isVisible && window.occlusionState.contains(.visible), "Probe window is not visible")
        // Functional gesture runs can continue in a visible window after macOS returns focus to
        // another app. Benchmark and live-inspection loading still require foreground readiness.
        if mode != "scroll" {
            require(NSApplication.shared.isActive, "Probe app is not active; timing would include App Nap")
        }
        outer = scroll
        // Supplying many file records must not eagerly create an editor for each one.
        require(fileCount < 100 || texts.count < 50, "\(texts.count) live editors for \(fileCount) files")
        emitPhase(["text_views": texts.count, "document_height": document.frame.height,
                   "viewport_height": scroll.contentView.bounds.height])
        // Inspection observes the live window without first drawing it into an offscreen context.
        // Keep bitmap capture in scripted scroll runs, where it is retained as a separate artifact.
        if mode == "scroll" { captureVisibleDiff(scroll) }
        if initialSplit && phase == "open_unified" && mode != "benchmark" {
            beginLoad("open_split", segment: "Split", split: true)
            return
        }
        if mode == "inspect" {
            phase = "inspection"
            nextActionAt = ProcessInfo.processInfo.systemUptime + 75
            diffCheckOutput(["event": "inspection_ready", "window_number": window.windowNumber])
            return
        }
        if phase == "reopen_unified" { pass(); return }
        phase = "settling"
        nextActionAt = ProcessInfo.processInfo.systemUptime + 0.25
    }

    private func beginScroll() {
        guard let outer else { fail("Missing loaded scroll view") }
        scroll(to: boundary(bottom: false))
        outer.layoutSubtreeIfNeeded()
        phase = wantsSplit ? "scroll_split" : "scroll_unified"
        phaseStarted = ProcessInfo.processInfo.systemUptime
        phaseCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        lastTick = phaseStarted
        maxGap = 0
        maxMounted = 0
        wheelReachedBottom = false
        wheelReturnedTop = false
        wheelEvents = 0
        wheelLegs = 0
        wheelMinY = outer.contentView.bounds.minY
        wheelMaxY = wheelMinY
        drags = 0
        expectedHeight = outer.documentView!.frame.height
        if mode != "benchmark" && gesture == "wheel" {
            require(boundary(bottom: true) - boundary(bottom: false) > 6,
                    "Wheel fixture must have a scroll range larger than the endpoint tolerance")
        }
        // Overlay scrollers are otherwise hidden before the first user gesture. Reveal them before
        // attempting a hit-tested knob drag, as moving to the scrollbar would do in normal use.
        outer.flashScrollers()
        nextActionAt = phaseStarted + 0.1
        diffCheckOutput(["event": "scroll_start", "phase": phase, "document_height": expectedHeight,
                         "gesture": mode == "benchmark" ? "programmatic" : gesture])
    }

    private func checkStableGeometry() {
        guard let outer else { fail("Scroll view disappeared") }
        requireFixedWindowFrame()
        let actual = outer.documentView!.frame.height
        require(abs(actual - expectedHeight) < 1,
                "Static diff document height changed during scrolling: \(expectedHeight) -> \(actual)")
        let texts = descendants(outer).compactMap { $0 as? DiffTextView }
        maxMounted = max(maxMounted, texts.count)
        require(fileCount < 100 || texts.count < 50, "Scrolling eagerly mounted \(texts.count) editors")
    }

    private func requireFixedWindowFrame() {
        let expected = NSRect(x: 0, y: 1, width: 2560, height: 1409)
        require(window.frame == expected,
                "Private test window moved or resized: \(NSStringFromRect(window.frame)), expected \(NSStringFromRect(expected))")
    }

    private func advanceScrolling(_ now: Double) {
        let elapsed = now - phaseStarted
        if mode == "benchmark" {
            let duration = 2.0
            let f = min(1, elapsed / duration)
            let fraction = f < 0.5 ? f * 2 : (1 - f) * 2
            let top = boundary(bottom: false), bottom = boundary(bottom: true)
            scroll(to: top + (bottom - top) * fraction)
            if elapsed >= duration { finishScroll() }
        } else {
            let top = boundary(bottom: false), bottom = boundary(bottom: true)
            let actual = outer!.contentView.bounds.minY
            wheelMinY = min(wheelMinY, actual)
            wheelMaxY = max(wheelMaxY, actual)
            let down = wheelLegs.isMultiple(of: 2)
            if abs(actual - (down ? bottom : top)) < 3 {
                if down { wheelReachedBottom = true }
                else { wheelReturnedTop = true }
                wheelLegs += 1
                diffCheckOutput(["event": "wheel_leg_complete", "direction": down ? "down" : "up",
                                 "offset": actual, "events": wheelEvents,
                                 "document_height": outer!.documentView!.frame.height])
                if wheelLegs == cycles * 2 { finishScroll(); return }
            }
            // Native scrolling settles on subsequent run-loop turns. Complete each leg by its
            // observed endpoint, so a slow frame cannot silently shorten the gesture's distance.
            // The independent heartbeat and external total timeout still bound a broken route.
            let delta = Int32(max(100, ceil((bottom - top) / 100)))
            sendWheel(delta: wheelLegs.isMultiple(of: 2) ? -delta : delta)
            wheelEvents += 1
        }
    }

    private func beginDrag(down: Bool) {
        dragging = true
        outer?.flashScrollers()
        // Do not start producing drag/up events while this dispatch is still queued. Under heavy
        // model updates they could be consumed before mouse-down ever enters its native tracker.
        DispatchQueue.main.async { [weak self] in
            self?.dispatchDrag(down: down)
        }
    }

    private func dispatchDrag(down: Bool) {
        guard let outer, let scroller = outer.verticalScroller else { fail("No native vertical scroller") }
        outer.flashScrollers()
        let knob = scroller.rect(for: .knob), slot = scroller.rect(for: .knobSlot)
        require(knob.height > 0 && slot.height > knob.height, "Fixture does not expose a draggable scrollbar")
        let from = scroller.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
        let hitPoint = host.superview?.convert(from, from: nil) ?? from
        let hit = host.hitTest(hitPoint)
        let hitsScroller = hit === scroller || hit?.isDescendant(of: scroller) == true
        diffCheckOutput(["event": "drag_start", "knob": NSStringFromRect(knob),
            "slot": NSStringFromRect(slot), "point": NSStringFromPoint(from),
            "scroller_style": scroller.scrollerStyle == .overlay ? "overlay" : "legacy",
            "scroller_hidden": scroller.isHidden, "scroller_alpha": scroller.alphaValue,
            "hit_type": hit.map { String(describing: type(of: $0)) } ?? "nil",
            "hits_scroller": hitsScroller, "app_active": NSApplication.shared.isActive,
            "window_key": window.isKeyWindow, "pressed_buttons": NSEvent.pressedMouseButtons])
        require(hitsScroller, "The native scrollbar knob is not hit-testable at its reported location")
        let endY = (scroller.isFlipped == down) ? slot.maxY - knob.height / 2 : slot.minY + knob.height / 2
        let to = scroller.convert(NSPoint(x: knob.midX, y: endY), to: nil)
        dragStep = 0
        // This is a different Timer from tick(): AppKit runs a nested event loop inside mouseDown.
        let producer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dragStep += 1
                let fraction = min(1, Double(self.dragStep) / 120)
                let point = NSPoint(x: from.x + (to.x - from.x) * fraction,
                                    y: from.y + (to.y - from.y) * fraction)
                // Deliver the endpoint as a drag BEFORE mouse-up, rather than releasing short.
                self.postMouse(self.dragStep <= 120 ? .leftMouseDragged : .leftMouseUp, point: point)
                if self.dragStep > 120 {
                    self.dragTimer?.invalidate()
                }
            }
        }
        dragTimer = producer
        RunLoop.main.add(producer, forMode: .common)
        RunLoop.main.add(producer, forMode: .eventTracking)
        let mouseDown = mouseEvent(.leftMouseDown, point: from)
        // This method is outside tick's Timer callback, so tick can run inside AppKit's nested loop.
        // Geometry, hit testing, producer start and mouse-down stay together in this dispatch.
        NSApplication.shared.sendEvent(mouseDown)
        diffCheckOutput(["event": "drag_return", "generated_steps": dragStep,
            "app_active": NSApplication.shared.isActive, "window_key": window.isKeyWindow,
            "pressed_buttons": NSEvent.pressedMouseButtons,
            "offset": outer.contentView.bounds.minY])
        require(dragStep == 121, "Native knob tracking returned after \(dragStep) of 121 generated steps")
        let actual = outer.contentView.bounds.minY
        let target = boundary(bottom: down)
        require(abs(actual - target) < 3, "Native drag missed endpoint: \(actual), expected \(target)")
        drags += 1
        dragging = false
        nextActionAt = ProcessInfo.processInfo.systemUptime + 0.15
        diffCheckOutput(["event": "drag_complete", "direction": down ? "down" : "up",
                         "offset": actual, "document_height": outer.documentView!.frame.height])
    }

    /// Address a wheel event to this private window over a visible text pane. Sending it through
    /// NSWindow exercises hit testing and the nested pane's responder chain as well as outer scrolling.
    private func sendWheel(delta: Int32) {
        guard let outer,
              let text = descendants(outer).compactMap({ $0 as? DiffTextView })
                .first(where: { !$0.visibleRect.isEmpty }) else { fail("No visible text pane for wheel event") }
        let visible = text.visibleRect
        let point = text.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                         wheel1: delta, wheel2: 0, wheel3: 0)!
        let screenHeight = NSScreen.screens[0].frame.height
        // The CGEvent bridge creates an event without an associated NSWindow. Direct NSWindow
        // dispatch interprets its location as window coordinates, so normalize those explicitly.
        // This keeps the event inside this private window without global event-posting permissions.
        cg.location = NSPoint(x: point.x, y: screenHeight - point.y)
        let event = NSEvent(cgEvent: cg)!
        require(abs(event.locationInWindow.x - point.x) < 0.5 && abs(event.locationInWindow.y - point.y) < 0.5,
                "Wheel event has incorrect coordinates for the private test window")
        window.sendEvent(event)
    }

    private func finishScroll() {
        checkStableGeometry()
        if mode != "benchmark" && gesture == "wheel" {
            diffCheckOutput(["event": "wheel_summary", "events": wheelEvents,
                "min_y": wheelMinY, "max_y": wheelMaxY, "top": boundary(bottom: false),
                "bottom": boundary(bottom: true), "final_y": outer!.contentView.bounds.minY,
                "reached_bottom": wheelReachedBottom, "returned_top": wheelReturnedTop,
                "completed_legs": wheelLegs])
            require(wheelReachedBottom && wheelReturnedTop && wheelLegs == cycles * 2,
                    "Wheel scrolling did not reach the bottom and return to the top")
            require(wheelMaxY - wheelMinY >= boundary(bottom: true) - boundary(bottom: false) - 6,
                    "Wheel scrolling did not traverse the document's scroll range")
        }
        require(maxGap < 2, "Main loop paused for \(maxGap) seconds while scrolling")
        emitPhase(["max_mounted_text_views": maxMounted, "document_height": expectedHeight,
                   "completed_drags": drags, "completed_wheel_legs": wheelLegs])
        if mode != "benchmark" { pass(); return }
        if !wantsSplit {
            beginLoad("switch_split", segment: "Split", split: true)
        } else {
            require(activateSegment("Docs", mouseEvents: false), "Could not switch to Documents")
            phase = "between_loads"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.beginLoad("reopen_unified", segment: "Diff", split: false)
            }
        }
    }

    private func boundary(bottom: Bool) -> CGFloat {
        guard let outer else { fail("Missing scroll view") }
        var proposed = outer.contentView.bounds
        proposed.origin.y = bottom ? 1_000_000_000 : -1_000_000_000
        return outer.contentView.constrainBoundsRect(proposed).origin.y
    }

    private func scroll(to y: CGFloat) {
        outer!.contentView.scroll(to: NSPoint(x: 0, y: y))
        outer!.reflectScrolledClipView(outer!.contentView)
    }

    private func activateSegment(_ label: String, mouseEvents: Bool) -> Bool {
        for control in descendants(host).compactMap({ $0 as? NSSegmentedControl }) {
            guard let index = (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == label }) else { continue }
            if mouseEvents {
                let local = NSPoint(x: control.bounds.width * (Double(index) + 0.5) / Double(control.segmentCount),
                                    y: control.bounds.midY)
                let point = control.convert(local, to: nil)
                postMouse(.leftMouseDown, point: point)
                postMouse(.leftMouseUp, point: point)
                return true
            }
            control.selectedSegment = index
            return control.sendAction(control.action, to: control.target)
        }
        return false
    }

    private func postMouse(_ type: NSEvent.EventType, point: NSPoint) {
        NSApplication.shared.postEvent(mouseEvent(type, point: point), atStart: false)
    }

    private func mouseEvent(_ type: NSEvent.EventType, point: NSPoint) -> NSEvent {
        mouseEventNumber += 1
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: mouseEventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func diagnoseLoadingIfNeeded(_ texts: [DiffTextView]) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - phaseStarted > 2, now - lastLoadDiagnostic > 2 else { return }
        lastLoadDiagnostic = now
        let lists = descendants(host).compactMap { $0 as? DiffFileListView }
        let controls = descendants(host).compactMap { $0 as? NSSegmentedControl }
        diffCheckOutput(["event": "waiting_for_diff", "phase": phase,
            "inspector_mode": String(describing: model.inspectorMode),
            "app_active": NSApplication.shared.isActive, "window_visible": window.isVisible,
            "window_unoccluded": window.occlusionState.contains(.visible),
            "text_frames": texts.map { NSStringFromRect($0.frame) },
            "native_lists": lists.map { list -> [String: Any] in ["frame": NSStringFromRect(list.frame),
                "table": NSStringFromRect(list.tableView.frame), "rows": list.tableView.numberOfRows] },
            "pickers": controls.map { control -> [String: Any] in ["labels": (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" },
                "selected": control.selectedSegment] }])
        if mode == "scroll" { captureVisibleDiff(host) }
    }

    private func captureVisibleDiff(_ view: NSView) {
        let directory = diffCheckArgument("--artifact-dir")
        guard !directory.isEmpty,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(phase + ".png"))
    }

    private func emitPhase(_ extra: [String: Any]) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var fields: [String: Any] = ["event": "phase_end", "phase": phase, "files": fileCount,
            "elapsed_ms": (ProcessInfo.processInfo.systemUptime - phaseStarted) * 1000,
            "main_cpu_ms": Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - phaseCPU) / 1_000_000,
            "max_main_gap_ms": maxGap * 1000, "peak_rss_mib": Double(usage.ru_maxrss) / 1024 / 1024,
            "window_frame": NSStringFromRect(window.frame),
            "app_active": NSApplication.shared.isActive, "window_unoccluded": window.occlusionState.contains(.visible)]
        for (key, value) in extra { fields[key] = value }
        diffCheckOutput(fields)
    }

    private func require(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    private func fail(_ message: String) -> Never {
        diffCheckOutput(["event": "failure", "phase": phase, "message": message])
        exit(1)
    }

    private func pass() {
        timer?.invalidate()
        dragTimer?.invalidate()
        churnTimer?.invalidate()
        transport.shutdown()
        diffCheckOutput(["event": "pass", "mode": mode, "files": fileCount])
        exit(0)
    }

    private struct ProbeFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// AppKit exposes a disabled close widget even without `.closable`. Accessory fixtures have no close
/// action, so omit that accessibility attribute as well. AeroSpace v0.20.3 then treats them as popups
/// and leaves their fixed viewport in place. Normal inspection windows retain their close action.
@MainActor
private final class DiffProbeWindow: NSWindow {
    override func accessibilityCloseButton() -> Any? {
        diffCheckArgument("--mode") == "inspect" ? super.accessibilityCloseButton() : nil
    }
}

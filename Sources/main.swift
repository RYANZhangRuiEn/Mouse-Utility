import AppKit
import Foundation

func runSelfTests() {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }; checks += 1 }
    var wheel = WheelInterpreter()
    func wheelSample(_ delta:Double,precise:Bool = false,momentum:Bool = false) -> WheelSample {
        WheelSample(values:[precise ? "point":"line":delta],precise:precise,momentum:momentum)
    }
    let profile = WheelProfile()
    check(wheel.consume(wheelSample(1),profile:profile,time:1).steps == 1,"detented up")
    check(wheel.consume(wheelSample(-1),profile:profile,time:2).steps == -1,"detented down")
    check(wheel.consume(wheelSample(120),profile:profile,time:3).steps == 64,"extreme uncalibrated reports are bounded")
    wheel.reset()
    for i in 0..<7 { check(wheel.consume(wheelSample(1.5,precise:true),profile:profile,time:4+Double(i)*0.01).steps == 0,"high-resolution accumulation") }
    check(wheel.consume(wheelSample(1.5,precise:true),profile:profile,time:4.08).steps == 1,"one high-resolution detent")
    check(wheel.consume(wheelSample(60,precise:true,momentum:true),profile:profile,time:4.1).steps == 0,"momentum ignored")
    _ = wheel.consume(wheelSample(10,precise:true),profile:profile,time:5)
    check(wheel.consume(wheelSample(-12,precise:true),profile:profile,time:5.01).steps == -1,"direction reversal is immediate")
    check(wheel.consume(wheelSample(.infinity,precise:true),profile:profile,time:6).steps == 0,"invalid delta ignored")
    check(clamp(1.2) == 1 && clamp(-0.2) == 0 && clamp(0, 0.15) == 0.15, "volume and brightness safety bounds")
    for i in 0..<8 { check(RingGeometry.hit(RingGeometry.point(i)) == i, "all eight slots clickable") }
    check(RingGeometry.hit(RingGeometry.center) == nil, "center does not accidentally execute a slot")
    let screen = NSRect(x: -1920, y: 100, width: 1920, height: 1080)
    for point in [NSPoint(x: -1920, y: 100), NSPoint(x: -1, y: 1179)] { check(screen.contains(RingGeometry.frame(near: point, screen: screen)), "panel clamped on secondary screen") }
    let config = Configuration()
    let data = try! JSONEncoder().encode(config)
    let restored = try! JSONDecoder().decode(Configuration.self, from: data)
    check(restored.items == config.items && restored.mouseBindings == config.mouseBindings, "configuration round-trip")
    check(KeyBinding.command("C", code: 8).display == "⌘C" && KeyBinding.command("V", code: 9).display == "⌘V", "shortcut labels")
    check(config.mouseBindings.values.allSatisfy { $0 == "none" }, "mouse defaults preserve original buttons")
    // Sector coverage includes gaps and the inner edge; center and outer area remain inert.
    for slot in 0..<8 {
        for offset in [-0.38, -0.2, 0.0, 0.2, 0.38] {
            let angle = Double.pi / 2 - Double(slot) * .pi / 4 + offset
            for r in [55.0, 100.0, 160.0] {
                check(RingGeometry.hit(NSPoint(x: 260 + cos(angle) * r, y: 260 + sin(angle) * r)) == slot, "sector coverage including gaps")
            }
        }
    }
    check(RingGeometry.hit(NSPoint(x: 260, y: 300)) == 0, "inner wedge is actionable")
    check(RingGeometry.hit(NSPoint(x: 260, y: 430)) == nil, "outside ring remains inert")
    check(RingGeometry.isClose(RingGeometry.center), "center closes instead of executing a command")
    for minimum in [0.0, 0.05, 0.15] {
        for start in [minimum, 0.3, 0.98, 1.0] {
            let deltas = [0.2, -0.1, -0.8, -0.3, 0.1, 0.04]
            var batch = BoundedAdjustment(minimum: minimum), sequential = start
            for delta in deltas { batch.append(delta); sequential = clamp(sequential + delta, minimum) }
            check(abs(batch.apply(to: start) - sequential) < 0.000001, "coalescing preserves saturation and reversal")
        }
    }
    var early = BoundedAdjustment(minimum: 0.05)
    early.append(-1); early.append(0.1)
    check(abs(early.rebased(minimum: 0.15).apply(to: 1) - 0.25) < 0.000001, "rebased minimum preserves clamp order")
    // Secondary menu targets, including angular wrap on the left side.
    for parent in 0..<8 {
        for count in 1...8 {
            for child in 0..<count {
                let p = RingGeometry.childPoint(parent: parent, index: child, count: count)
                check(RingGeometry.childHit(p, parent: parent, count: count) == child, "all secondary items reachable")
                check(NSRect(origin: .zero, size: RingGeometry.size).contains(p), "secondary items fit reserved transparent area")
            }
            let a = Double.pi / 2 - Double(parent) * .pi / 4
            let bridge = NSPoint(x: 260 + cos(a) * 165, y: 260 + sin(a) * 165)
            check(RingGeometry.inBridge(bridge, parent: parent, count: count), "parent-child travel corridor")
        }
    }
    check(RingGeometry.childHit(RingGeometry.center, parent: 0, count: 3) == nil, "center cannot activate a submenu item")
    var personalized = Configuration()
    personalized.items[0] = MenuItem(.shortcut, name: "one", shortcut: .command("C", code: 8))
    personalized.items[1] = MenuItem(.shortcut, name: "two", shortcut: .command("V", code: 9))
    personalized.update(at: ItemLocation(root: 0, child: nil)) { $0.shortcut = .command("X", code: 7) }
    check(personalized.items[0].shortcut?.keyCode == 7 && personalized.items[1].shortcut?.keyCode == 9, "shortcuts are per item")
    personalized.items[2] = .media()
    let beforeChild = personalized.items[2].children[0]
    personalized.update(at: ItemLocation(root: 2, child: 1)) { $0.name = "custom play" }
    check(personalized.items[2].children[0] == beforeChild && personalized.items[2].children[1].name == "custom play", "child editing is isolated")
    let legacy = #"{"slots":["brightness","volume","mute","next","playPause","previous","shortcutA","shortcutB"],"shortcutA":{"name":"复制","keyCode":8,"modifiers":1048576,"keyLabel":"C"},"shortcutB":{"name":"粘贴","keyCode":9,"modifiers":1048576,"keyLabel":"V"},"mouseBindings":{"2":"shortcutA","3":"none","4":"showRing"},"step":0.04}"#.data(using: .utf8)!
    let migrated = try! JSONDecoder().decode(Configuration.self, from: legacy)
    check(migrated.items[6].action == .shortcut && migrated.items[6].shortcut?.keyCode == 8, "legacy copy becomes generic shortcut")
    check(migrated.items[7].shortcut?.keyCode == 9 && migrated.items[4].action == .submenu && migrated.items[4].children.count == 3, "legacy media and paste migrate")
    check(migrated.mouseBindings["2"] == "item:" + migrated.items[6].id.uuidString, "legacy mouse binding preserves target")
    let exported = String(data: try! JSONEncoder().encode(migrated), encoding: .utf8)!
    check(!exported.contains("\"shortcutA\":") && !exported.contains("\"slots\":"), "new files contain no shared A/B shortcut slots")
    var invalid = Configuration()
    invalid.items[0].children = Array(repeating: MenuItem(.submenu, children: [.media()]), count: 12)
    invalid.items[1].id = invalid.items[0].id
    invalid.appearance.scale = 999; invalid.appearance.accentHex = "invalid"
    let cleaned = invalid.sanitized()
    check(cleaned.items[0].children.count == 8 && cleaned.items[0].children.allSatisfy { $0.action != .submenu && $0.children.isEmpty }, "only two levels, maximum eight children")
    check(Set(cleaned.items.map { $0.id }).count == 8 && cleaned.appearance.scale == 1.25, "invalid identities and scale normalized")
    let memory = SettingsStore(persistent: false)
    memory.config = personalized
    let imported = SettingsStore(persistent: false)
    try! imported.importData(memory.exportData())
    check(imported.config == personalized, "portable configuration preserves independent nodes and appearance")
    print("PASS: \(checks) checks. Wheel integration, momentum, geometry, bounds, shortcuts, configuration.")
}

if CommandLine.arguments.contains("--self-test") { runSelfTests(); exit(0) }
if CommandLine.arguments.contains("--diagnose") {
    _ = NSApplication.shared
    print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("Accessibility: \(InputSender.trusted)")
    let audio = AudioController()
    do { let state = try audio.snapshot(); print("Audio: \(state.name), volume=\(state.value), mute=\(state.muted)") } catch { print("Audio: \(error.localizedDescription)") }
    let brightness = BrightnessController()
    for display in HardwareDisplay.online() {
        if let value = brightness.nativeValue(id: display.id) { print("Display: \(display.name), id=\(display.id), hardware brightness=\(value)") }
        else { print("Display: \(display.name), hardware brightness unavailable") }
    }
    print("Physical displays: \(HardwareDisplay.online().count)")
    exit(0)
}
let app = NSApplication.shared
let delegate = AppController(store: SettingsStore(persistent: !CommandLine.arguments.contains("--preview")))
app.delegate = delegate
app.run()

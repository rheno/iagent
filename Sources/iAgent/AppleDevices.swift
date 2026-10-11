import AppKit
import Foundation
import Network

enum AppleTools {
    static let all: [Tool] = [
        appleDevices, iosDevice, simulator, airdrop,
        reminders, calendar, contacts, notes, messages,
        shortcuts, mac, appleScript,
    ]

    static func actionSchema(_ actions: [String], _ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        var p = props
        p["action"] = ["type": "string", "enum": actions]
        return schema(p, required: ["action"] + required)
    }

    static func action(_ args: [String: Any]) -> String { args["action"] as? String ?? "" }

    /// Summary like `add: Buy milk` for action-based tools.
    static func summarize(_ keys: [String]) -> ([String: Any]) -> String {
        { args in
            let detail = keys.compactMap { args[$0].map { "\($0)" } }.first.map { ": \($0.prefix(80))" } ?? ""
            return action(args) + detail
        }
    }

    static func tempFile(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("iagent-\(UUID().uuidString.prefix(8)).\(ext)")
    }

    static func timestampedPath(_ name: String, _ ext: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/\(name)-\(df.string(from: Date())).\(ext)").path
    }
}

// MARK: - apple_devices: discovery across the ecosystem

extension AppleTools {
    static let appleDevices = Tool(
        name: "apple_devices",
        description: """
        Discover the user's Apple devices: this Mac (model/chip/macOS), iPhone/iPad/Apple Watch/Apple TV paired over USB \
        or Wi-Fi (via Xcode devicectl or libimobiledevice), booted iOS simulators, Bluetooth accessories (AirPods, \
        keyboards, ... with battery levels), and Apple devices visible on the local network via Bonjour (iPhone, iPad, \
        Mac, Apple TV, HomePod, AirPlay receivers). Call this first to learn device names/identifiers.
        """,
        schema: schema([
            "scan_seconds": ["type": "number", "description": "How long to scan the local network (default 3)"],
        ], required: []),
        approval: { _, _ in .none },
        summary: { _ in "scan" },
        run: { args, _ in
            let seconds = min(max(Double(int(args, "scan_seconds") ?? 3), 1), 15)
            async let mac = macSection()
            async let paired = pairedDevicesSection()
            async let sims = simulatorSection()
            async let bt = bluetoothSection()
            async let lan = networkSection(seconds: seconds)
            return await [mac, paired, sims, bt, lan].joined(separator: "\n\n")
        })

    private static func macSection() async -> String {
        var lines = ["## This Mac"]
        if let out = try? await runChecked(["system_profiler", "SPHardwareDataType", "-json"]),
           let hw = (JSON.object(out)?["SPHardwareDataType"] as? [[String: Any]])?.first {
            let model = [hw["machine_name"], hw["machine_model"]].compactMap { $0 as? String }.joined(separator: " ")
            lines.append("- \(model), \(hw["chip_type"] as? String ?? hw["cpu_type"] as? String ?? "?"), \(hw["physical_memory"] as? String ?? "?") RAM")
        }
        if let v = try? await runChecked(["sw_vers", "-productVersion"]) { lines.append("- macOS \(v)") }
        lines.append("- Host name: \(ProcessInfo.processInfo.hostName)")
        return lines.joined(separator: "\n")
    }

    private static func pairedDevicesSection() async -> String {
        var lines = ["## iPhone / iPad / Watch / Apple TV (paired for development or USB)"]
        if await ToolAvailability.shared.has("devicectl") {
            let devices = await DeviceCtl.listDevices()
            if devices.isEmpty { lines.append("- none found (connect via USB, unlock, and tap Trust)") }
            for d in devices { lines.append("- \(d.summary)") }
        } else if await ToolAvailability.shared.has("idevice_id") {
            let usb = (try? await runChecked(["idevice_id", "-l"])) ?? ""
            let net = (try? await runChecked(["idevice_id", "-n"])) ?? ""
            let ids = Set((usb + "\n" + net).split(separator: "\n").map(String.init).filter { !$0.isEmpty })
            if ids.isEmpty { lines.append("- none found (connect via USB, unlock, and tap Trust)") }
            for id in ids.sorted() {
                let name = (try? await runChecked(["ideviceinfo", "-u", id, "-k", "DeviceName"])) ?? "?"
                let type = (try? await runChecked(["ideviceinfo", "-u", id, "-k", "ProductType"])) ?? "?"
                let ver = (try? await runChecked(["ideviceinfo", "-u", id, "-k", "ProductVersion"])) ?? "?"
                lines.append("- \(name) (\(type), iOS \(ver)) udid=\(id) via \(usb.contains(id) ? "USB" : "Wi-Fi")")
            }
        } else {
            lines.append("- unavailable: install Xcode (for `xcrun devicectl`) or `brew install libimobiledevice`")
        }
        return lines.joined(separator: "\n")
    }

    private static func simulatorSection() async -> String {
        guard await ToolAvailability.shared.has("simctl"),
              let out = try? await runChecked(["xcrun", "simctl", "list", "devices", "available", "--json"]),
              let runtimes = JSON.object(out)?["devices"] as? [String: [[String: Any]]] else {
            return "## Simulators\n- unavailable (requires Xcode)"
        }
        var booted: [String] = []
        var total = 0
        for (runtime, devices) in runtimes {
            total += devices.count
            let os = runtime.components(separatedBy: ".").last ?? runtime
            for d in devices where d["state"] as? String == "Booted" {
                booted.append("- \(d["name"] as? String ?? "?") (\(os)) udid=\(d["udid"] as? String ?? "?") — booted")
            }
        }
        return (["## Simulators", "- \(total) available, \(booted.count) booted"] + booted).joined(separator: "\n")
    }

    private static func bluetoothSection() async -> String {
        var lines = ["## Bluetooth devices"]
        guard let out = try? await runChecked(["system_profiler", "SPBluetoothDataType", "-json"], timeout: 30),
              let bt = (JSON.object(out)?["SPBluetoothDataType"] as? [[String: Any]])?.first else {
            return lines.joined(separator: "\n") + "\n- unavailable"
        }
        for (key, label) in [("device_connected", "connected"), ("device_not_connected", "paired, not connected")] {
            for entry in bt[key] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    let props = value as? [String: Any] ?? [:]
                    let kind = props["device_minorType"] as? String ?? ""
                    let battery = props.filter { $0.key.contains("battery") }.sorted { $0.key < $1.key }
                        .map { "\($0.key.replacingOccurrences(of: "device_batteryLevel", with: "battery")): \($0.value)" }
                    lines.append("- \(name)\(kind.isEmpty ? "" : " [\(kind)]") — \(label)\(battery.isEmpty ? "" : " (\(battery.joined(separator: ", ")))")")
                }
            }
        }
        if lines.count == 1 { lines.append("- none") }
        return lines.joined(separator: "\n")
    }

    private static func networkSection(seconds: Double) async -> String {
        let found = await Bonjour.browse(types: ["_companion-link._tcp", "_airplay._tcp", "_device-info._tcp"], seconds: seconds)
        var lines = ["## Apple devices on the local network (Bonjour)"]
        for (name, info) in found.sorted(by: { $0.key < $1.key }) {
            let model = info.txt["model"] ?? info.txt["rpMd"] ?? info.txt["am"]
            // _device-info alone is advertised by many non-Apple services; only list it with a recognizable model.
            if info.types == ["_device-info._tcp"] && Bonjour.kind(model) == nil { continue }
            // Only Apple devices advertise companion-link; AirPlay alone can be a third-party TV/speaker.
            let kind = Bonjour.kind(model) ?? (info.types.contains("_companion-link._tcp") ? "Apple device" : "AirPlay receiver")
            let services = info.types.map { $0.replacingOccurrences(of: "._tcp", with: "").replacingOccurrences(of: "_", with: "") }.sorted()
            lines.append("- \(name): \(kind)\(model.map { " (\($0))" } ?? "") — \(services.joined(separator: ", "))")
        }
        if lines.count == 1 {
            lines.append("- none seen in \(Int(seconds))s (devices may be asleep, or Local Network access is off for your terminal in System Settings → Privacy & Security)")
        }
        return lines.joined(separator: "\n")
    }
}

enum Bonjour {
    struct Entry { var types: Set<String> = []; var txt: [String: String] = [:] }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var found: [String: Entry] = [:]
        var browsers: [NWBrowser] = []
    }

    static func browse(types: [String], seconds: Double) async -> [String: Entry] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: Entry], Never>) in
            let box = Box()
            let queue = DispatchQueue(label: "iagent.bonjour")
            for type in types {
                let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: "local."), using: NWParameters())
                browser.browseResultsChangedHandler = { results, _ in
                    box.lock.lock(); defer { box.lock.unlock() }
                    for r in results {
                        guard case let .service(name, svcType, _, _) = r.endpoint else { continue }
                        var e = box.found[name] ?? Entry()
                        e.types.insert(svcType.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                        if case let .bonjour(txt) = r.metadata { e.txt.merge(txt.dictionary) { a, _ in a } }
                        box.found[name] = e
                    }
                }
                browser.start(queue: queue)
                box.browsers.append(browser)
            }
            queue.asyncAfter(deadline: .now() + seconds) {
                box.lock.lock(); defer { box.lock.unlock() }
                box.browsers.forEach { $0.cancel() }
                cont.resume(returning: box.found)
            }
        }
    }

    static func kind(_ model: String?) -> String? {
        guard let m = model else { return nil }
        let table: [(String, String)] = [
            ("iPhone", "iPhone"), ("iPad", "iPad"), ("Watch", "Apple Watch"), ("AppleTV", "Apple TV"),
            ("AudioAccessory", "HomePod"), ("MacBook", "Mac"), ("iMac", "Mac"), ("Macmini", "Mac"),
            ("MacPro", "Mac"), ("Mac", "Mac"), ("RealityDevice", "Apple Vision Pro"),
        ]
        return table.first { m.hasPrefix($0.0) }?.1
    }
}

// MARK: - ios_device: physical iPhone / iPad / Watch / Apple TV

enum DeviceCtl {
    struct Device {
        let identifier: String
        let name: String
        let model: String
        let os: String
        let state: String
        var summary: String { "\(name) (\(model), \(os)) id=\(identifier) — \(state)" }
    }

    static func listDevices() async -> [Device] {
        let out = AppleTools.tempFile("json")
        defer { try? FileManager.default.removeItem(at: out) }
        guard (try? await runCommand(["xcrun", "devicectl", "list", "devices", "--json-output", out.path], timeout: 60)) != nil,
              let data = try? Data(contentsOf: out),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let devices = (obj["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
        return devices.map { d in
            let props = d["deviceProperties"] as? [String: Any] ?? [:]
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            let platform = hw["platform"] as? String ?? ""
            return Device(identifier: d["identifier"] as? String ?? hw["udid"] as? String ?? "?",
                          name: props["name"] as? String ?? "?",
                          model: hw["marketingName"] as? String ?? hw["productType"] as? String ?? "?",
                          os: "\(platform) \(props["osVersionNumber"] as? String ?? "")".trimmingCharacters(in: .whitespaces),
                          state: [conn["transportType"], conn["tunnelState"], conn["pairingState"]]
                            .compactMap { $0 as? String }.joined(separator: ", "))
        }
    }

    /// Uses the given device, or the only connected one.
    static func resolve(_ device: String?) async throws -> String {
        if let device, !device.isEmpty { return device }
        let devices = await listDevices()
        switch devices.count {
        case 0: throw AgentError("No devices found. Connect an iPhone/iPad via USB (unlocked, trusted) or pair it in Xcode → Devices.")
        case 1: return devices[0].identifier
        default: throw AgentError("Several devices found; pass `device`:\n" + devices.map { "- " + $0.summary }.joined(separator: "\n"))
        }
    }
}

extension AppleTools {
    private static let deviceActions = ["list", "info", "apps", "processes", "launch", "terminate", "install", "uninstall",
                                        "copy_to", "copy_from", "screenshot", "syslog", "raw"]

    static let iosDevice = Tool(
        name: "ios_device",
        description: """
        Manage a physical iPhone, iPad, Apple Watch or Apple TV over USB/Wi-Fi. Backends: Xcode's `xcrun devicectl` \
        (preferred) or libimobiledevice. Actions: list; info; apps (installed apps); processes; launch/terminate \
        (bundle_id; terminate needs pid with devicectl); install (path to .app/.ipa); uninstall (bundle_id); \
        copy_to/copy_from (files in an app's data container: bundle_id, source, destination); screenshot (path; \
        libimobiledevice); syslog (seconds, filter; libimobiledevice); raw (args passed to `xcrun devicectl`). \
        `device` is a name, UDID or identifier; omit it when only one device is connected.
        """,
        schema: actionSchema(deviceActions, [
            "device": ["type": "string", "description": "Device name, UDID or identifier"],
            "bundle_id": ["type": "string", "description": "App bundle identifier, e.g. com.example.app"],
            "path": ["type": "string", "description": "Local path: app to install, or screenshot output"],
            "pid": ["type": "integer", "description": "Process id (terminate)"],
            "source": ["type": "string", "description": "copy source path"],
            "destination": ["type": "string", "description": "copy destination path"],
            "seconds": ["type": "integer", "description": "syslog capture duration (default 10)"],
            "filter": ["type": "string", "description": "syslog: only lines containing this text"],
            "args": ["type": "array", "items": ["type": "string"], "description": "raw: arguments after `xcrun devicectl`"],
        ]),
        // Paths on this Mac follow the read_file/write_file rules: secret files stay blocked, outside paths are scoped.
        approval: { args, ctx in
            switch action(args) {
            case "list", "info", "apps", "processes": return .none
            case "copy_to", "install":
                return .strictest(.ask, PathPolicy.readApproval(args[action(args) == "install" ? "path" : "source"] as? String, ctx))
            case "copy_from": return .strictest(.ask, PathPolicy.writeApproval(args["destination"] as? String, ctx))
            case "screenshot": return (args["path"] as? String).map { .strictest(.ask, PathPolicy.writeApproval($0, ctx)) } ?? .ask
            default: return .ask
            }
        },
        summary: summarize(["bundle_id", "path", "device"]),
        run: { args, ctx in
            let act = action(args)
            let device = try (args["device"] as? String).map { try operand($0, "device") }
            let bundle = try (args["bundle_id"] as? String).map { try operand($0, "bundle_id") }
            if await ToolAvailability.shared.has("devicectl") {
                func dc(_ rest: [String], timeout: Double = 120) async throws -> String {
                    let r = try await runCommand(["xcrun", "devicectl"] + rest, timeout: timeout)
                    guard r.ok else { throw AgentError("devicectl failed (exit \(r.status)): \(r.combined) \(r.note)") }
                    return r.combined.isEmpty ? "OK" : r.combined
                }
                switch act {
                case "list":
                    let devices = await DeviceCtl.listDevices()
                    return devices.isEmpty ? "No devices found." : devices.map { "- " + $0.summary }.joined(separator: "\n")
                case "raw":
                    let raw = args["args"] as? [String] ?? []
                    guard !raw.isEmpty else { throw AgentError("raw needs args") }
                    return try await dc(raw, timeout: 300)
                case "screenshot", "syslog":
                    break   // devicectl can't; fall through to libimobiledevice below
                default:
                    let id = try await DeviceCtl.resolve(device)
                    switch act {
                    case "info": return try await dc(["device", "info", "details", "--device", id])
                    case "apps": return try await dc(["device", "info", "apps", "--device", id])
                    case "processes": return try await dc(["device", "info", "processes", "--device", id])
                    case "launch":
                        guard let bundle else { throw AgentError("launch needs bundle_id") }
                        return try await dc(["device", "process", "launch", "--device", id, "--terminate-existing", bundle])
                    case "terminate":
                        guard let pid = int(args, "pid") else { throw AgentError("terminate needs pid (see action processes)") }
                        return try await dc(["device", "process", "terminate", "--device", id, "--pid", String(pid)])
                    case "install":
                        return try await dc(["device", "install", "app", "--device", id, ctx.resolve(try str(args, "path")).path], timeout: 600)
                    case "uninstall":
                        guard let bundle else { throw AgentError("uninstall needs bundle_id") }
                        return try await dc(["device", "uninstall", "app", "--device", id, bundle])
                    case "copy_to", "copy_from":
                        guard let b = bundle else { throw AgentError("\(act) needs bundle_id") }
                        var src = try operand(try str(args, "source"), "source"), dst = try operand(try str(args, "destination"), "destination")
                        if act == "copy_to" { src = ctx.resolve(src).path } else { dst = ctx.resolve(dst).path }
                        return try await dc(["device", "copy", act == "copy_to" ? "to" : "from", "--device", id,
                                             "--domain-type", "appDataContainer", "--domain-identifier", b,
                                             "--source", src, "--destination", dst], timeout: 600)
                    default:
                        throw AgentError("Unknown action '\(act)'")
                    }
                }
            }

            guard await ToolAvailability.shared.has("idevice_id") else {
                throw AgentError("No device tooling found. Install Xcode (for `xcrun devicectl`) or run `brew install libimobiledevice`.")
            }
            let udid = device.map { ["-u", $0] } ?? []
            switch act {
            case "list":
                let usb = (try? await runChecked(["idevice_id", "-l"])) ?? ""
                let net = (try? await runChecked(["idevice_id", "-n"])) ?? ""
                let all = [usb, net].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return all.isEmpty ? "No devices found." : "USB:\n\(usb)\nWi-Fi:\n\(net)"
            case "info":
                let general = try await runChecked(["ideviceinfo"] + udid)
                let battery = (try? await runChecked(["ideviceinfo"] + udid + ["-q", "com.apple.mobile.battery"])) ?? ""
                return general + (battery.isEmpty ? "" : "\n\n# Battery\n" + battery)
            case "apps":
                if let r = try? await runChecked(["ideviceinstaller"] + udid + ["list"]) { return r }
                return try await runChecked(["ideviceinstaller"] + udid + ["-l"])
            case "install":
                return try await runChecked(["ideviceinstaller"] + udid + ["-i", ctx.resolve(try str(args, "path")).path], timeout: 600)
            case "uninstall":
                guard let bundle else { throw AgentError("uninstall needs bundle_id") }
                return try await runChecked(["ideviceinstaller"] + udid + ["-U", bundle])
            case "screenshot":
                let path = (args["path"] as? String).map { ctx.resolve($0).path } ?? timestampedPath("iphone-screenshot", "png")
                _ = try await runChecked(["idevicescreenshot"] + udid + [path], timeout: 60)
                return "Saved screenshot to \(path)"
            case "syslog":
                let seconds = Double(min(int(args, "seconds") ?? 10, 120))
                var argv = ["idevicesyslog"] + udid
                if let f = args["filter"] as? String { argv += ["-m", f] }
                let r = try await runCommand(argv, timeout: seconds)
                return truncate(r.stdout.isEmpty ? r.stderr : r.stdout, max: 20_000)
            default:
                throw AgentError("Action '\(act)'\(bundle.map { " for \($0)" } ?? "") needs Xcode's devicectl (install Xcode).")
            }
        })
}

// MARK: - simulator: iOS / iPadOS / watchOS / tvOS / visionOS simulators

extension AppleTools {
    private static let simActions = ["list", "boot", "shutdown", "install", "uninstall", "launch", "terminate", "openurl",
                                     "screenshot", "push", "appearance", "location", "raw"]

    static let simulator = Tool(
        name: "simulator",
        description: """
        Control Xcode simulators via `xcrun simctl` (requires Xcode). Actions: list; boot (also opens Simulator.app); \
        shutdown; install (path); uninstall/launch/terminate (bundle_id); openurl (url); screenshot (path); \
        push (bundle_id, payload JSON); appearance (mode light|dark); location (latitude, longitude); \
        raw (args after `xcrun simctl`). `device` is a UDID, name, or "booted" (default).
        """,
        schema: actionSchema(simActions, [
            "device": ["type": "string", "description": "Simulator UDID or name (default: booted)"],
            "bundle_id": ["type": "string"], "path": ["type": "string"], "url": ["type": "string"],
            "payload": ["type": "string", "description": "APNs payload JSON for push"],
            "mode": ["type": "string", "enum": ["light", "dark"]],
            "latitude": ["type": "number"], "longitude": ["type": "number"],
            "args": ["type": "array", "items": ["type": "string"]],
        ]),
        approval: { args, ctx in
            switch action(args) {
            case "list": return .none
            // A simulator has the Mac's network: each URL is approved on its own, like a fetch.
            case "openurl": return .askScoped("url " + (args["url"] as? String ?? ""))
            case "install": return .strictest(.ask, PathPolicy.readApproval(args["path"] as? String, ctx))
            case "screenshot": return (args["path"] as? String).map { .strictest(.ask, PathPolicy.writeApproval($0, ctx)) } ?? .ask
            default: return .ask
            }
        },
        summary: summarize(["bundle_id", "url", "device"]),
        run: { args, ctx in
            guard await ToolAvailability.shared.has("simctl") else {
                throw AgentError("simctl not found: install Xcode and run `sudo xcode-select -s /Applications/Xcode.app`.")
            }
            let d = try operand(args["device"] as? String ?? "booted", "device")
            func bundleID() throws -> String { try operand(try str(args, "bundle_id"), "bundle_id") }
            func sim(_ rest: [String], timeout: Double = 120) async throws -> String {
                let r = try await runCommand(["xcrun", "simctl"] + rest, timeout: timeout)
                guard r.ok else { throw AgentError("simctl failed (exit \(r.status)): \(r.combined) \(r.note)") }
                return r.combined.isEmpty ? "OK" : r.combined
            }
            switch action(args) {
            case "list": return try await sim(["list", "devices", "available"])
            case "boot":
                let out = try await sim(["boot", d])
                _ = try? await runCommand(["open", "-a", "Simulator"])
                return out
            case "shutdown": return try await sim(["shutdown", d == "booted" ? "all" : d])
            case "install": return try await sim(["install", d, ctx.resolve(try str(args, "path")).path], timeout: 600)
            case "uninstall": return try await sim(["uninstall", d, try bundleID()])
            case "launch": return try await sim(["launch", d, try bundleID()])
            case "terminate": return try await sim(["terminate", d, try bundleID()])
            case "openurl": return try await sim(["openurl", d, try operand(try str(args, "url"), "url")])
            case "screenshot":
                let path = (args["path"] as? String).map { ctx.resolve($0).path } ?? timestampedPath("simulator", "png")
                _ = try await sim(["io", d, "screenshot", path])
                return "Saved screenshot to \(path)"
            case "push":
                let file = tempFile("apns")
                defer { try? FileManager.default.removeItem(at: file) }
                try (try str(args, "payload")).write(to: file, atomically: true, encoding: .utf8)
                return try await sim(["push", d, try bundleID(), file.path])
            case "appearance":
                let mode = try str(args, "mode")
                guard ["light", "dark"].contains(mode) else { throw AgentError("mode must be light or dark") }
                return try await sim(["ui", d, "appearance", mode])
            case "location":
                guard let lat = args["latitude"] as? Double ?? (args["latitude"] as? Int).map(Double.init),
                      let lon = args["longitude"] as? Double ?? (args["longitude"] as? Int).map(Double.init) else {
                    throw AgentError("location needs numeric latitude and longitude")
                }
                return try await sim(["location", d, "set", "\(lat),\(lon)"])
            case "raw":
                let raw = args["args"] as? [String] ?? []
                guard !raw.isEmpty else { throw AgentError("raw needs args") }
                return try await sim(raw, timeout: 300)
            default: throw AgentError("Unknown action '\(action(args))'")
            }
        })
}

// MARK: - airdrop

extension AppleTools {
    static let airdrop = Tool(
        name: "airdrop",
        description: "Send files or URLs to a nearby iPhone/iPad/Mac with AirDrop. Opens the macOS AirDrop picker; the user chooses the recipient device. Waits until sent or cancelled.",
        schema: schema(["items": ["type": "array", "items": ["type": "string"], "description": "File paths and/or http(s) URLs"]],
                       required: ["items"]),
        approval: { _, _ in .ask },
        summary: { (($0["items"] as? [String]) ?? []).joined(separator: ", ") },
        run: { args, ctx in
            let items = (args["items"] as? [String] ?? []).map { $0.hasPrefix("http") ? $0 : ctx.resolve($0).path }
            guard !items.isEmpty else { throw AgentError("items is empty") }
            for p in items where !p.hasPrefix("http") && !FileManager.default.fileExists(atPath: p) {
                throw AgentError("No such file: \(p)")
            }
            guard let exe = Bundle.main.executablePath else { throw AgentError("Cannot locate own executable") }
            // AppKit sharing needs a running NSApplication, so it runs in a helper process (see AirDropHelper).
            let r = try await runCommand([exe, AirDropHelper.flag] + items, timeout: 600)
            let out = r.combined
            guard r.ok else { throw AgentError(out.isEmpty ? "AirDrop failed \(r.note)" : out) }
            return out
        })
}

@MainActor
final class AirDropHelper: NSObject, NSApplicationDelegate, NSSharingServiceDelegate {
    static let flag = "__airdrop"
    private let items: [Any]

    init(items: [Any]) { self.items = items }

    static func run(_ args: [String]) -> Never {
        let items: [Any] = args.map { $0.hasPrefix("http") ? (URL(string: $0) ?? URL(fileURLWithPath: $0)) : URL(fileURLWithPath: $0) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AirDropHelper(items: items)
        app.delegate = delegate
        app.run()
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: items) else {
            fputs("AirDrop is not available (check that Wi-Fi and Bluetooth are on).\n", stderr)
            exit(1)
        }
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: items)
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        print("AirDrop: sent \(items.count) item(s).")
        exit(0)
    }

    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let cancelled = (error as NSError).code == NSUserCancelledError
        fputs(cancelled ? "AirDrop cancelled by the user.\n" : "AirDrop failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

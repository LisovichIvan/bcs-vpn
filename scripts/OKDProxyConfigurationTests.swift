import AppKit
import Darwin
import Foundation

// Do not write test diagnostics into the installed application's log.
enum DiagnosticLogger {
    static func info(_ message: String) {}
    static func error(_ message: String) {}
}

@main
private enum OKDProxyConfigurationTests {
    private static let fixture = #"""
    {
      "second": {"protocol":"tcp", "localport":15427, "forwardIp":"second.example.invalid", "forwardPort":5432},
      "first": {"protocol":"tcp", "localport":15424, "forwardIp":"first.example.invalid", "forwardPort":1433},
      "alias": {"protocol":"tcp", "localport":15424, "forwardIp":"first.example.invalid", "forwardPort":1433},
      "_disabled": null,
      "datagram": {"protocol":"udp"}
    }
    """#

    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "api" {
            try runFakeGLab()
            return
        }
        precondition(CommandLine.arguments.count == 2)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try testParser()
        try testSettings(directory: directory)
        try testLoader(directory: directory)
        try testManager(directory: directory)
        try testWindow(directory: directory)
        print("OKD configuration: parsing, legacy settings, glab arguments, failures, timeout/cancellation, startup and settings preview passed")
    }

    private static func decode(_ text: String) throws -> OKDProxyConfiguration {
        try JSONDecoder().decode(OKDProxyConfiguration.self, from: Data(text.utf8))
    }

    private static func testParser() throws {
        let configuration = try decode(fixture)
        precondition(configuration.ports == "15424 15427")
        precondition(configuration.forwards.map(\.name) == ["alias", "first", "second"])
        precondition(configuration.forwards[1].description == "first\n127.0.0.1:15424 → pod:15424 → first.example.invalid:1433 (TCP)")
        let boundaries = try decode(#"{"low":{"protocol":"tcp","localport":1,"forwardIp":"::1","forwardPort":65535}}"#)
        precondition(boundaries.ports == "1")
        precondition(boundaries.forwards[0].description.contains("[::1]:65535"))
        let invalidConfigurations = [
            "<html>login</html>", "[]", "null", "{}",
            #"{"_disabled":{},"datagram":{"protocol":"udp"}}"#,
            fixture.replacingOccurrences(of: "15427", with: "0"),
            fixture.replacingOccurrences(of: "15427", with: "65536"),
            fixture.replacingOccurrences(of: "15427", with: "15427.5"),
            fixture.replacingOccurrences(of: "15427", with: "\"15427\""),
            fixture.replacingOccurrences(of: "15427", with: "true"),
            fixture.replacingOccurrences(of: "5432", with: "0"),
            fixture.replacingOccurrences(of: "5432", with: "65536"),
            fixture.replacingOccurrences(of: "second.example.invalid", with: ""),
            fixture.replacingOccurrences(of: "second.example.invalid", with: "bad host"),
            fixture.replacingOccurrences(of: "second.example.invalid", with: #"bad\nhost"#),
            #"{"incomplete":{"protocol":"tcp","localport":15424}}"#,
        ]
        for text in invalidConfigurations {
            do {
                _ = try decode(text)
                preconditionFailure("Invalid configuration was accepted")
            } catch {}
        }
        let tooManyPorts = (1...101).map { port in
            "\"service-\(port)\":{\"protocol\":\"tcp\",\"localport\":\(port),\"forwardIp\":\"example.invalid\",\"forwardPort\":1433}"
        }.joined(separator: ",")
        do {
            _ = try decode("{\(tooManyPorts)}")
            preconditionFailure("More than 100 unique ports were accepted")
        } catch {}
    }

    private static func settings() -> OKDProxySettings {
        OKDProxySettings(
            serverURL: "https://okd.example.invalid", token: "synthetic-token", username: "", password: "",
            namespace: "test-namespace", podSelector: "app=test-proxy"
        )
    }

    private static func testSettings(directory: URL) throws {
        let store = OKDProxySettingsStore(dataDirectory: directory)
        let legacy: [String: String] = [
            "serverURL": "https://okd.example.invalid", "token": "synthetic-token",
            "namespace": "test-namespace", "podSelector": "app=test-proxy", "ports": "not-used-anymore",
        ]
        let legacyData = try PropertyListSerialization.data(fromPropertyList: legacy, format: .xml, options: 0)
        precondition(FileManager.default.createFile(atPath: store.configurationFileURL.path, contents: legacyData, attributes: [.posixPermissions: 0o600]))
        let loadedSettings = try store.load()
        precondition(loadedSettings == settings())
        _ = try store.save(settings())
        let savedData = try Data(contentsOf: store.configurationFileURL)
        let saved = try PropertyListSerialization.propertyList(from: savedData, format: nil) as! [String: String]
        precondition(saved["ports"] == nil)
        let runtime = OKDProxyRuntimeConfiguration(settings: settings(), ports: "15424 15427")
        let runtimeData = try PropertyListEncoder().encode(runtime)
        let values = try PropertyListSerialization.propertyList(from: runtimeData, format: nil) as! [String: String]
        precondition(values["ports"] == "15424 15427")
        precondition(values["namespace"] == "test-namespace" && values["token"] == "synthetic-token")
    }

    private static func loader(mode: String, directory: URL, timeout: TimeInterval = 5) -> OKDProxyConfigurationLoader {
        setenv("BCS_TEST_GLAB_MODE", mode, 1)
        setenv("BCS_TEST_GLAB_DIRECTORY", directory.path, 1)
        return OKDProxyConfigurationLoader(executableURL: URL(fileURLWithPath: CommandLine.arguments[0]), timeout: timeout)
    }

    private static func waitUntil(_ description: String, predicate: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 8)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        precondition(predicate(), "Timed out: \(description)")
    }

    private static func testLoader(directory: URL) throws {
        let successfulLoader = loader(mode: "success", directory: directory)
        setenv("GLAB_DEBUG_HTTP", "true", 1)
        defer { unsetenv("GLAB_DEBUG_HTTP") }
        var result: Result<OKDProxyConfiguration, Error>?
        successfulLoader.load { result = $0 }
        waitUntil("configuration loaded") { result != nil }
        let configuration = try result!.get()
        precondition(configuration.ports == "15424 15427")
        for mode in ["failure", "invalid"] {
            let failingLoader = loader(mode: mode, directory: directory)
            result = nil
            failingLoader.load { result = $0 }
            waitUntil("\(mode) reported") { result != nil }
            guard case let .failure(error) = result else { preconditionFailure("Failure was accepted") }
            precondition(!error.localizedDescription.contains("synthetic-sensitive-output"))
        }
        result = nil
        let missingLoader = OKDProxyConfigurationLoader(executableURL: nil)
        missingLoader.load { result = $0 }
        guard case .failure(OKDProxyConfigurationError.missingGLab) = result else { preconditionFailure("Missing glab not reported") }

        let marker = directory.appendingPathComponent("glab-pid")
        let stalledLoader = loader(mode: "stalled", directory: directory, timeout: 2)
        result = nil
        stalledLoader.load { result = $0 }
        waitUntil("glab started") { FileManager.default.fileExists(atPath: marker.path) }
        let processIdentifier = pid_t(try String(contentsOf: marker, encoding: .utf8))!
        waitUntil("timeout reported") { result != nil }
        guard case .failure(OKDProxyConfigurationError.timedOut) = result else { preconditionFailure("Timeout not reported") }
        waitUntil("unresponsive glab killed") { Darwin.kill(processIdentifier, 0) != 0 && errno == ESRCH }
        try FileManager.default.removeItem(at: marker)

        let cancelledLoader = loader(mode: "stalled", directory: directory)
        var completed = false
        cancelledLoader.load { _ in completed = true }
        waitUntil("cancellable glab started") { FileManager.default.fileExists(atPath: marker.path) }
        let cancelledIdentifier = pid_t(try String(contentsOf: marker, encoding: .utf8))!
        cancelledLoader.cancel()
        waitUntil("cancelled glab killed") { Darwin.kill(cancelledIdentifier, 0) != 0 && errno == ESRCH }
        precondition(!completed, "Cancelled operation must not complete or launch forwarding")
        try FileManager.default.removeItem(at: marker)
        // Reusing the loader must not receive the cancelled request's completion.
        setenv("BCS_TEST_GLAB_MODE", "success", 1)
        result = nil
        cancelledLoader.load { result = $0 }
        waitUntil("loader reused") { result != nil }
        let reloadedConfiguration = try result!.get()
        precondition(reloadedConfiguration.ports == "15424 15427")
    }

    private static func testManager(directory: URL) throws {
        let scripts = directory.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = scripts.appendingPathComponent("okd-proxy.sh")
        try #"""
        /usr/bin/plutil -extract ports raw -o "$BCS_VPN_DATA_DIRECTORY/received-ports" "$1"
        exec /bin/sleep 60
        """#.write(to: script, atomically: true, encoding: .utf8)
        let capturedPorts = directory.appendingPathComponent("received-ports")
        let failingManager = OKDProxyManager(
            resourceDirectory: directory, dataDirectory: directory,
            configurationLoader: loader(mode: "failure", directory: directory),
            ocExecutableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        var failure: Error?
        try failingManager.start { failure = $0 }
        waitUntil("manager rejects unavailable config") { failure != nil }
        precondition(failingManager.status == .failed)
        precondition(!FileManager.default.fileExists(atPath: capturedPorts.path))
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("run/okd-proxy-runtime.plist").path))

        let manager = OKDProxyManager(
            resourceDirectory: directory, dataDirectory: directory,
            configurationLoader: loader(mode: "success", directory: directory),
            ocExecutableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        var started = false
        try manager.start { error in precondition(error == nil); started = true }
        precondition(manager.status == .starting)
        manager.refreshStatus()
        precondition(manager.status == .starting)
        waitUntil("wrapper receives current ports") { started && FileManager.default.fileExists(atPath: capturedPorts.path) }
        let receivedPorts = try String(contentsOf: capturedPorts, encoding: .utf8)
        precondition(receivedPorts.trimmingCharacters(in: .whitespacesAndNewlines) == "15424 15427")
        let runtimeURL = directory.appendingPathComponent("run/okd-proxy-runtime.plist")
        let attributes = try FileManager.default.attributesOfItem(atPath: runtimeURL.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        manager.stop()
        waitUntil("manager stopped") { manager.status == .stopped }
        precondition(!FileManager.default.fileExists(atPath: runtimeURL.path))
        // A new connection must fetch again, never reuse the successful list.
        try FileManager.default.removeItem(at: capturedPorts)
        setenv("BCS_TEST_GLAB_MODE", "failure", 1)
        failure = nil
        try manager.start { failure = $0 }
        waitUntil("reconnection fetches again") { failure != nil }
        precondition(manager.status == .failed)
        precondition(!FileManager.default.fileExists(atPath: capturedPorts.path))
        precondition(!FileManager.default.fileExists(atPath: runtimeURL.path))

        let cancelledManager = OKDProxyManager(
            resourceDirectory: directory, dataDirectory: directory,
            configurationLoader: loader(mode: "stalled", directory: directory),
            ocExecutableURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        var completed = false
        try cancelledManager.start { _ in completed = true }
        let marker = directory.appendingPathComponent("glab-pid")
        waitUntil("manager loading") { FileManager.default.fileExists(atPath: marker.path) }
        let processIdentifier = pid_t(try String(contentsOf: marker, encoding: .utf8))!
        cancelledManager.stop()
        waitUntil("manager cancels fetch") { Darwin.kill(processIdentifier, 0) != 0 && errno == ESRCH }
        cancelledManager.refreshStatus()
        precondition(cancelledManager.status == .stopped && !completed)
        precondition(!FileManager.default.fileExists(atPath: capturedPorts.path))
        precondition(!FileManager.default.fileExists(atPath: runtimeURL.path))
    }

    private static func testWindow(directory: URL) throws {
        _ = NSApplication.shared
        let controller = OKDProxySettingsWindowController(
            dataDirectory: directory, configurationLoader: loader(mode: "success", directory: directory)
        )
        controller.open()
        defer { controller.close() }
        let content = controller.window!.contentView!
        let textView = descendants(in: content).compactMap { $0 as? CopyableTextView }.first!
        waitUntil("settings preview loaded") { textView.string.contains("first.example.invalid:1433") }
        precondition(textView.string.contains("127.0.0.1:15424 → pod:15424 → first.example.invalid:1433 (TCP)"))
        precondition(!textView.string.contains("_disabled") && !textView.string.contains("datagram"))
        let labels = descendants(in: content).compactMap { ($0 as? NSTextField)?.stringValue }
        precondition(labels.contains { $0.contains(OKDProxyConfiguration.sourceURL) })
        precondition(!textView.isEditable && textView.isSelectable)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        precondition(textView.enclosingScrollView!.frame.height >= 200)
        precondition(textView.frame.width > 500, "Preview must have a visible text container")
        let refreshButton = descendants(in: content).compactMap { $0 as? NSButton }.first { $0.title == "Обновить пробросы" }!
        setenv("BCS_TEST_GLAB_MODE", "failure", 1)
        precondition(refreshButton.sendAction(refreshButton.action, to: refreshButton.target))
        waitUntil("settings error displayed") { refreshButton.isEnabled }
        precondition(textView.string.isEmpty, "Stale preview must be cleared after failure")
        precondition(descendants(in: content).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Не удалось загрузить") })
    }

    private static func descendants(in parent: NSView) -> [NSView] {
        [parent] + parent.subviews.flatMap { descendants(in: $0) }
    }

    private static func runFakeGLab() throws {
        precondition(Array(CommandLine.arguments.dropFirst()) == ["api", "--hostname", "gitlab.gitlab.bcs.ru", OKDProxyConfiguration.apiEndpoint])
        precondition(ProcessInfo.processInfo.environment["GLAB_DEBUG_HTTP"] == nil)
        switch ProcessInfo.processInfo.environment["BCS_TEST_GLAB_MODE"] {
        case "success": print(fixture)
        case "failure": print("synthetic-sensitive-output"); exit(1)
        case "invalid": print("<html>synthetic-sensitive-output</html>")
        case "stalled":
            Darwin.signal(SIGTERM, SIG_IGN)
            let directory = ProcessInfo.processInfo.environment["BCS_TEST_GLAB_DIRECTORY"]!
            try String(getpid()).write(toFile: directory + "/glab-pid", atomically: true, encoding: .utf8)
            while true { Thread.sleep(forTimeInterval: 0.05) }
        default: preconditionFailure("Unknown fake glab mode")
        }
    }
}

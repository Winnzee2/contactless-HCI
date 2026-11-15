// A Finder-launchable entry point for the prepared local product.
import AppKit
import Foundation

final class Launcher: NSObject, NSApplicationDelegate {
    var process: Process?
    var errorLog: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let location = Bundle.main.url(forResource: "project-root", withExtension: "txt") else {
                throw NSError(domain: "Jarvis", code: 1, userInfo: [NSLocalizedDescriptionKey: "Project location is missing. Rebuild with scripts/build_product.sh."])
            }
            let path = try String(contentsOf: location, encoding: .utf8).trimmingCharacters(in: .newlines)
            let root = URL(fileURLWithPath: path, isDirectory: true)
            let script = root.appendingPathComponent("desktop.py")
            guard FileManager.default.fileExists(atPath: script.path) else {
                throw NSError(domain: "Jarvis", code: 2, userInfo: [NSLocalizedDescriptionKey: "The project was moved. Run scripts/build_product.sh from its new location."])
            }
            let log = root.appendingPathComponent(".build/jarvis-errors.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            errorLog = log
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.arguments = ["-u", script.path]
            child.currentDirectoryURL = root
            child.standardInput = FileHandle.nullDevice
            // Do not persist recognized speech. Window status is the normal UI.
            child.standardOutput = FileHandle.nullDevice
            child.standardError = try FileHandle(forWritingTo: log)
            child.terminationHandler = { [weak self] done in
                DispatchQueue.main.async {
                    if done.terminationStatus != 0 {
                        self?.showError("Jarvis stopped. Check local model readiness with python3 desktop.py --check. Diagnostic log: \(log.path)")
                    }
                    NSApp.terminate(nil)
                }
            }
            process = child
            try child.run()
        } catch {
            showError(error.localizedDescription)
            NSApp.terminate(nil)
        }
    }

    func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Jarvis could not start"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let child = process, child.isRunning { child.interrupt() }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Launcher()
app.delegate = delegate
app.run()

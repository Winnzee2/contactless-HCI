import AppKit

func writeJarvisNote(_ text: String, id: String, folder: URL) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("Jarvis-\(id).txt")
    try Data((text + "\n").utf8).write(to: file, options: [.withoutOverwriting])
    return file
}

/// A local, nonactivating dictation window. No keystrokes or network access.
final class NotesPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let textView = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var sessionID: String?
    private var content = ""
    private var finished = false
    private var completionReason = ""
    private var saved = false
    private var unsaved: [String: String] = [:]
    var onStop: (() -> Void)?
    private var folder: URL {
        if let path = UserDefaults.standard.string(forKey: "notesFolder") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Local Control Notes", isDirectory: true)
    }

    @objc func chooseFolder() {
        let picker = NSOpenPanel()
        picker.title = "Choose where Jarvis saves text notes"
        picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.canCreateDirectories = true; picker.allowsMultipleSelection = false
        picker.directoryURL = folder
        picker.begin { [weak self] response in
            guard let self, response == .OK, let url = picker.url else { return }
            UserDefaults.standard.set(url.path, forKey: "notesFolder")
            self.status.stringValue = "Notes folder: \(url.path)"
            if self.finished && (!self.saved || !self.unsaved.isEmpty) { self.save() }
        }
    }
    @objc private func stop() { onStop?() }
    @objc private func retrySave() { if finished { save() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !finished { onStop?(); return false }
        if !saved || !unsaved.isEmpty { save() }
        return saved && unsaved.isEmpty
    }
    private func makePanel() {
        guard panel == nil else { return }
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 460, height: 340),
                             styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.title = "Jarvis · Local notes"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        window.level = .floating; window.delegate = self
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        textView.isEditable = false; textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.backgroundColor = NSColor(srgbRed: 0.09, green: 0.1, blue: 0.12, alpha: 1)
        textView.textColor = NSColor(srgbRed: 0.9, green: 0.92, blue: 0.95, alpha: 1)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        status.textColor = NSColor(srgbRed: 0.7, green: 0.75, blue: 0.8, alpha: 1)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        let choose = NSButton(title: "Notes folder…", target: self, action: #selector(chooseFolder))
        let stop = NSButton(title: "Stop recording", target: self, action: #selector(stop))
        let retry = NSButton(title: "Retry save", target: self, action: #selector(retrySave))
        let buttons = NSStackView(views: [choose, stop, retry])
        buttons.spacing = 8
        let stack = NSStackView(views: [scroll, status, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(srgbRed: 0.055, green: 0.06, blue: 0.075, alpha: 1).cgColor
        window.contentView = root; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.minSize = NSSize(width: 460, height: 340)
        window.center()
        panel = window
    }
    func update(_ json: [String: Any]) {
        guard let id = json["session_id"] as? String,
              id.count == 32, id.allSatisfy({ $0.isHexDigit }),
              let text = json["text"] as? String,
              let final = json["final"] as? Bool,
              let recording = json["recording"] as? Bool else { return }
        makePanel()
        if sessionID != id {
            // Keep failed notes in memory across sessions so a later folder
            // selection / retry can save all of them without dropping text.
            if let previous = sessionID, !saved, !content.isEmpty {
                unsaved[previous] = content
            }
            sessionID = id; saved = false
            panel?.orderFrontRegardless()
        }
        content = text; finished = final
        completionReason = json["message"] as? String ?? ""
        textView.string = text
        textView.scrollToEndOfDocument(nil)
        panel?.title = recording ? "Jarvis · Recording" : "Jarvis · Finishing"
        status.stringValue = "\(json["message"] as? String ?? "")\nFolder: \(folder.path)"
        if final { save() }
    }
    func saveBeforeExit() { finished = true; save() }

    private func save() {
        guard let id = sessionID else { return }
        if !saved {
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                unsaved[id] = content
            } else {
                saved = true
                status.stringValue = "No speech to save."
                panel?.title = "Jarvis · Finished"
            }
        }
        var failures: [String] = []
        for (key, text) in Array(unsaved) {
            do {
                let file = try writeJarvisNote(text, id: key, folder: folder)
                unsaved.removeValue(forKey: key)
                if key == id {
                    saved = true
                    status.stringValue = "\(completionReason)\nSaved: \(file.path)"
                    panel?.title = "Jarvis · Saved"
                }
            } catch { failures.append(error.localizedDescription) }
        }
        if let error = failures.first {
            status.stringValue = "Could not save \(unsaved.count) note(s): \(error)\nChoose another folder or Retry save. Text is kept until the app exits."
            panel?.title = "Jarvis · Save failed"
            panel?.orderFrontRegardless()
        }
    }
}

import Foundation

/// Runs scripts/create-vm.sh and turns its output into progress for the UI.
@MainActor
final class Creator: ObservableObject {
    @Published var step = 0
    @Published var steps = 6
    @Published var title = ""
    @Published var detail = ""
    @Published var failed: String?
    @Published var warning: String?
    @Published var finished = false
    private var process: Process?
    private var buffer = ""

    func start(config: VMConfig, password: String) {
        failed = nil; finished = false; step = 0
        title = "Preparing"
        do {
            try config.write()
        } catch {
            failed = "Could not write the VM settings: \(error.localizedDescription)"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Paths.scripts.appendingPathComponent("create-vm.sh").path, config.folder.path]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        let logURL = config.folder.appendingPathComponent("create.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            log?.write(data)
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.consume(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                output.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                if status == 0 {
                    self.finished = true
                } else if self.failed == nil {
                    self.failed = "The build stopped (exit \(status)). Log: \(logURL.path)"
                }
            }
        }
        do {
            try p.run()
            input.fileHandleForWriting.write((password + "\n").data(using: .utf8)!)
            try? input.fileHandleForWriting.close()
            process = p
        } catch {
            failed = "Could not start the build: \(error.localizedDescription)"
        }
    }

    func cancel() { process?.terminate() }

    private func consume(_ text: String) {
        buffer += text
        // curl's progress bar ends its updates with \r, the rest with \n.
        while let r = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<r]).trimmingCharacters(in: .whitespaces)
            buffer = String(buffer[buffer.index(after: r)...])
            handle(line)
        }
        if buffer.count > 4096 { buffer = String(buffer.suffix(512)) }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("STEP ") {
            // STEP n/N title
            let parts = line.dropFirst(5).split(separator: " ", maxSplits: 1)
            if let nums = parts.first?.split(separator: "/"), nums.count == 2 {
                step = Int(nums[0]) ?? step
                steps = Int(nums[1]) ?? steps
            }
            title = parts.count > 1 ? String(parts[1]) : ""
            detail = ""
        } else if line.hasPrefix("==>") {
            detail = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\u{1B}[1;32m", with: "")
                .replacingOccurrences(of: "\u{1B}[0m", with: "")
        } else if line.hasPrefix("WARN:") {
            warning = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            detail = warning ?? ""
        } else if line.hasPrefix("ERROR:") {
            failed = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if let pct = line.split(separator: " ").last, pct.hasSuffix("%"),
                  line.contains("#") {
            detail = "Downloading \(pct)"
        }
    }
}

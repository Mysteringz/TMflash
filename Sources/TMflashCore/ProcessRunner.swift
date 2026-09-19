import Foundation

public enum ProcessRunner {
    /// Runs a tool, calling `onLine` for each line of stdout and stderr (merged;
    /// esptool uses `\r` for progress, which counts as a line end too).
    /// Returns the exit status. Cancelling the task terminates the tool.
    public static func run(_ exe: String, _ args: [String], environment: [String: String] = [:],
                           onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PLATFORMIO_NO_ANSI"] = "true"
        env["NO_COLOR"] = "1"
        // An app launched from Finder has a minimal PATH; pio needs git et al.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        for (k, v) in environment { env[k] = v }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice

        let splitter = LineSplitter(onLine)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { splitter.feed(d) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Int32, Error>) in
                p.terminationHandler = { proc in
                    // Collect what is left in the pipe before reporting.
                    pipe.fileHandleForReading.readabilityHandler = nil
                    splitter.feed(pipe.fileHandleForReading.readDataToEndOfFile())
                    splitter.flush()
                    c.resume(returning: proc.terminationStatus)
                }
                do { try p.run() } catch {
                    p.terminationHandler = nil
                    c.resume(throwing: SerialError("cannot run \(exe): \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }
}

final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(_ onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func feed(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...i)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { onLine(line) }
        }
    }

    func flush() {
        lock.lock(); defer { lock.unlock() }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        if !line.trimmingCharacters(in: .whitespaces).isEmpty { onLine(line) }
    }
}

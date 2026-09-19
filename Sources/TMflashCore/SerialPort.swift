import Darwin
import Foundation

public struct SerialError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// A raw 8N1 serial port. Blocking I/O with timeouts; callers run it off the
/// main thread.
public final class SerialPort {
    public let path: String
    private var fd: Int32 = -1
    private var pending = Data()

    public init(path: String, baud: speed_t = 115200) throws {
        self.path = path
        // O_NONBLOCK so open() does not wait for carrier detect; cleared below.
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            let why = String(cString: strerror(errno))
            throw SerialError(errno == EBUSY ? "\(path) is in use by another program (a serial monitor?)" : "cannot open \(path): \(why)")
        }
        // Exclusive: two TMflash jobs, or a serial monitor, on one board would
        // interleave commands.
        _ = ioctl(fd, TIOCEXCL)
        _ = fcntl(fd, F_SETFL, 0)
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { close(); throw SerialError("\(path) is not a serial port") }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CRTSCTS)
        cfsetspeed(&t, baud)
        guard tcsetattr(fd, TCSANOW, &t) == 0 else { close(); throw SerialError("cannot configure \(path)") }
        // Let the board run: on the ESP32 auto-reset circuit an asserted RTS
        // holds EN (reset) low and DTR pulls GPIO0 (boot mode). Harmless
        // failure on a pseudo-terminal.
        var lines: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, TIOCMBIC, &lines)
        tcflush(fd, TCIOFLUSH)
    }

    deinit { close() }

    public func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    public func write(_ s: String) throws {
        var bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeMutableBytes { Darwin.write(fd, $0.baseAddress! + off, $0.count - off) }
            if n < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw SerialError("write to \(path) failed: \(String(cString: strerror(errno)))")
            }
            off += n
        }
    }

    /// The next complete line (without CR/LF), or nil after `timeout` seconds.
    public func readLine(timeout: TimeInterval) throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let i = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<i]
                pending.removeSubrange(pending.startIndex...i)
                var s = String(decoding: line, as: UTF8.self)
                while s.hasSuffix("\r") { s.removeLast() }
                return s
            }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, Int32(min(left, 0.25) * 1000) + 1)
            if r < 0 {
                if errno == EINTR { continue }
                throw SerialError("read from \(path) failed: \(String(cString: strerror(errno)))")
            }
            if r == 0 { continue }
            if p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 && p.revents & Int16(POLLIN) == 0 {
                throw SerialError("\(path) disconnected")
            }
            var buf = [UInt8](repeating: 0, count: 1024)
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 { pending.append(contentsOf: buf[0..<n]) }
            else if n == 0 { throw SerialError("\(path) disconnected") }
            else if errno != EINTR && errno != EAGAIN { throw SerialError("read from \(path) failed: \(String(cString: strerror(errno)))") }
        }
    }

    /// Throw away whatever arrives for `seconds`.
    public func drain(for seconds: TimeInterval) throws {
        let end = Date().addingTimeInterval(seconds)
        while end.timeIntervalSinceNow > 0 { _ = try readLine(timeout: end.timeIntervalSinceNow) }
        pending.removeAll()
    }
}

import Darwin
import Foundation

struct VPNSessionTimeDisplay {
    let countdown: String
    let menuTitle: String
}

enum VPNSessionTime {
    static func expiration(from content: String) -> Date? {
        let timestamp = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !timestamp.isEmpty,
              timestamp.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let seconds = UInt64(timestamp),
              seconds > 0, seconds <= 9_999_999_999 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    static func readExpiration(at fileURL: URL) throws -> Date? {
        let fileDescriptor = fileURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fileDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let fileHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        defer { try? fileHandle.close() }

        var fileInformation = stat()
        guard fstat(fileDescriptor, &fileInformation) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard fileInformation.st_mode & S_IFMT == S_IFREG,
              fileInformation.st_uid == getuid(),
              fileInformation.st_size > 0, fileInformation.st_size <= 64 else {
            return nil
        }
        let data = try fileHandle.read(upToCount: 65) ?? Data()
        guard data.count <= 64 else {
            return nil
        }
        return expiration(from: String(decoding: data, as: UTF8.self))
    }

    static func display(expiration: Date, now: Date) -> VPNSessionTimeDisplay {
        let remainingMinutes = Int(ceil(max(0, expiration.timeIntervalSince(now)) / 60))
        let countdown = String(format: "%02d:%02d", remainingMinutes / 60, remainingMinutes % 60)
        return VPNSessionTimeDisplay(
            countdown: countdown,
            menuTitle: remainingMinutes == 0
                ? "Лимит сессии истёк"
                : "До отключения: \(countdown)"
        )
    }
}

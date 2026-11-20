import Foundation

public enum Formatters {
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file)
    }

    public static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 1 else { return "—" }
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        return "\(formatted)/s"
    }

    public static func eta(remainingBytes: Int64, bytesPerSecond: Double) -> String {
        guard remainingBytes > 0, bytesPerSecond > 1 else { return "—" }
        let seconds = Int((Double(remainingBytes) / bytesPerSecond).rounded())
        guard seconds >= 0 && seconds < 86400 * 7 else { return "—" }
        if seconds < 60 {
            return "\(seconds)s"
        } else if seconds < 3600 {
            let m = seconds / 60
            let s = seconds % 60
            return String(format: "%dm %02ds", m, s)
        } else {
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return String(format: "%dh %02dm", h, m)
        }
    }

    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public static func timeString(_ date: Date) -> String {
        logTimeFormatter.string(from: date)
    }
}

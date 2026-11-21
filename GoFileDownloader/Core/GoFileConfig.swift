import Foundation

public enum GoFileConfig {
    public static let apiBase = "https://api.gofile.io"
    public static let accountsEndpoint = "\(apiBase)/accounts"

    public static let userAgent = "Mozilla/5.0"
    public static let locale = "en-US"
    public static let tokenWindowSeconds: Int64 = 14400
    public static let tokenSecret = "12af056dacea0b"

    public static let defaultMaxWorkers = 3
    public static let defaultMaxRetries = 3

    public static let maxPathComponentUTF8Bytes = 220
    public static let maxFolderRecursionDepth = 32
    public static let maxPaginationPages = 100

    public static let kb = 1024
    public static let mb = 1024 * kb

    public static let chunkThresholds: [(threshold: Int64, chunkSize: Int)] = [
        (Int64(1 * mb), 8 * kb),
        (Int64(10 * mb), 16 * kb),
        (Int64(50 * mb), 64 * kb),
        (Int64(100 * mb), 128 * kb),
        (Int64(250 * mb), 256 * kb),
    ]
    public static let largeFileChunkSize = 512 * kb

    public static func chunkSize(for fileSize: Int64) -> Int {
        guard fileSize >= 0 else { return largeFileChunkSize }
        for (threshold, size) in chunkThresholds {
            if fileSize < threshold {
                return size
            }
        }
        return largeFileChunkSize
    }

    public static var commonHeaders: [String: String] {
        [
            "User-Agent": userAgent,
            "Accept-Encoding": "gzip",
            "Accept": "*/*",
        ]
    }

    public static var extendedHeaders: [String: String] {
        var headers = commonHeaders
        headers["Sec-Fetch-Dest"] = "empty"
        headers["Sec-Fetch-Mode"] = "cors"
        headers["Sec-Fetch-Site"] = "same-site"
        headers["Pragma"] = "no-cache"
        headers["Cache-Control"] = "no-cache"
        return headers
    }

    public static var downloadHeaders: [String: String] {
        var headers = extendedHeaders
        headers["Accept-Encoding"] = "identity"
        return headers
    }
}

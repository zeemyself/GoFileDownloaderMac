import CryptoKit
import Foundation

public struct RemoteFile: Sendable, Equatable, Identifiable {
    public let id: String
    public var filename: String
    public let downloadLink: String
    public let relativeDirectory: [String]
    public let expectedSize: Int64?

    public init(
        id: String = UUID().uuidString,
        filename: String,
        downloadLink: String,
        relativeDirectory: [String],
        expectedSize: Int64? = nil
    ) {
        self.id = id
        self.filename = filename
        self.downloadLink = downloadLink
        self.relativeDirectory = relativeDirectory
        self.expectedSize = expectedSize
    }

    public var relativePath: String {
        (relativeDirectory + [filename]).joined(separator: "/")
    }
}

public enum GoFileError: LocalizedError, Equatable {
    case invalidURL(String)
    case accountCreationFailed
    case passwordRequired
    case apiError(String)
    case httpError(Int)
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "\(url) is not a valid GoFile URL."
        case .accountCreationFailed:
            return "Failed to create a GoFile guest account token."
        case .passwordRequired:
            return "The URL requires a valid password. Please provide one to proceed."
        case .apiError(let status):
            return "GoFile API returned an error (\(status))."
        case .httpError(let code):
            return "Server returned HTTP status \(code)."
        case .networkError(let details):
            return details
        }
    }
}

public actor GoFileAPI {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Pure helpers

    /// Extracts the content ID from a GoFile URL (`.../d/<id>`).
    public static func contentID(from url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[parts.count - 2] == "d" else {
            return nil
        }
        let id = parts[parts.count - 1]
        return id.isEmpty ? nil : id
    }

    /// SHA-256 hex digest of a plain password string.
    public static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Generates the dynamic `X-Website-Token` matching Python's `generate_website_token`.
    public static func websiteToken(accountToken: String, timestamp: Int64? = nil) -> String {
        let unixSeconds = timestamp ?? Int64(Date().timeIntervalSince1970)
        let timeWindow = unixSeconds / GoFileConfig.tokenWindowSeconds
        let seed = "\(GoFileConfig.userAgent)::\(GoFileConfig.locale)::\(accountToken)::\(timeWindow)::\(GoFileConfig.tokenSecret)"
        return sha256Hex(seed)
    }

    /// Builds the `/contents/<id>` URL with optional already-hashed password.
    public static func contentURL(contentID: String, hashedPassword: String? = nil) -> URL? {
        var urlString = "\(GoFileConfig.apiBase)/contents/\(contentID)?cache=true&sortField=createTime&sortDirection=1"
        if let hashedPassword, !hashedPassword.isEmpty {
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&+=?")
            let encoded = hashedPassword.addingPercentEncoding(withAllowedCharacters: allowed) ?? hashedPassword
            urlString += "&password=\(encoded)"
        }
        return URL(string: urlString)
    }

    /// Builds request headers matching `Downloader._prepare_headers`.
    public static func headers(
        accountToken: String,
        url: String? = nil,
        includeAuth: Bool = false,
        timestamp: Int64? = nil
    ) -> [String: String] {
        var headers = GoFileConfig.extendedHeaders
        if includeAuth {
            headers["Authorization"] = "Bearer \(accountToken)"
            headers["X-Website-Token"] = websiteToken(accountToken: accountToken, timestamp: timestamp)
            headers["X-BL"] = GoFileConfig.locale
        } else {
            if let url, !url.isEmpty {
                let adjusted = url.hasSuffix("/") ? url : (url + "/")
                headers["Referer"] = adjusted
                headers["Origin"] = url
            }
            headers["Cookie"] = "accountToken=\(accountToken)"
        }
        return headers
    }

    // MARK: - API Calls

    /// Requests a guest account token (`POST https://api.gofile.io/accounts`).
    public func createAccountToken() async throws -> String {
        guard let url = URL(string: GoFileConfig.accountsEndpoint) else {
            throw GoFileError.accountCreationFailed
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        for (key, value) in GoFileConfig.commonHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, _) = try await session.data(for: request)
        let decoded = try JSONDecoder().decode(AccountResponse.self, from: data)
        guard decoded.status == "ok", let token = decoded.data?.token, !token.isEmpty else {
            throw GoFileError.accountCreationFailed
        }
        return token
    }

    /// Recursively resolves all files inside a GoFile content ID, preserving folder hierarchy
    /// and deduplicating filenames within each folder (matching `Downloader.initialize_download`).
    public func resolveFiles(
        contentID: String,
        plainPassword: String?,
        accountToken: String
    ) async throws -> [RemoteFile] {
        let hashedPassword: String? = {
            guard let plainPassword, !plainPassword.isEmpty else { return nil }
            return Self.sha256Hex(plainPassword)
        }()

        var rawFiles: [RemoteFile] = []
        try await parseLinks(
            identifier: contentID,
            hashedPassword: hashedPassword,
            accountToken: accountToken,
            currentPath: [],
            into: &rawFiles
        )

        // Deduplicate filenames per relative directory using FilenameResolver.
        var usedByDir: [[String]: Set<String>] = [:]
        var resolved: [RemoteFile] = []
        resolved.reserveCapacity(rawFiles.count)

        for var file in rawFiles {
            var set = usedByDir[file.relativeDirectory, default: Set<String>()]
            file.filename = FilenameResolver.resolveUniqueFilename(file.filename, usedNames: &set)
            usedByDir[file.relativeDirectory] = set
            resolved.append(file)
        }

        return resolved
    }

    private func parseLinks(
        identifier: String,
        hashedPassword: String?,
        accountToken: String,
        currentPath: [String],
        into files: inout [RemoteFile]
    ) async throws {
        guard let url = Self.contentURL(contentID: identifier, hashedPassword: hashedPassword) else {
            throw GoFileError.invalidURL(identifier)
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        let reqHeaders = Self.headers(accountToken: accountToken, includeAuth: true)
        for (k, v) in reqHeaders {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw GoFileError.networkError("Failed to request \(url.absoluteString): \(error.localizedDescription)")
        }

        let response: ContentsResponse
        do {
            response = try JSONDecoder().decode(ContentsResponse.self, from: data)
        } catch {
            throw GoFileError.apiError("Failed to decode response from \(url.absoluteString)")
        }

        guard response.status == "ok", let node = response.data else {
            throw GoFileError.apiError("Failed to get a link as response from \(url.absoluteString).")
        }

        if node.requiresPassword && node.passwordStatus != "passwordOk" {
            throw GoFileError.passwordRequired
        }

        if node.type == "folder" {
            let folderName = sanitizePathComponent(node.name ?? identifier)
            let nextPath = currentPath + [folderName]
            if let children = node.children {
                // Sort keys deterministically by createTime or name if available, else key order
                let sortedChildren = children.values.sorted { lhs, rhs in
                    switch (lhs.createTime, rhs.createTime) {
                    case let (l?, r?) where l != r:
                        return l < r
                    default:
                        return (lhs.name ?? "") < (rhs.name ?? "")
                    }
                }
                for child in sortedChildren {
                    if child.type == "folder", let childID = child.id {
                        try await parseLinks(
                            identifier: childID,
                            hashedPassword: hashedPassword,
                            accountToken: accountToken,
                            currentPath: nextPath,
                            into: &files
                        )
                    } else if let name = child.name, let link = child.link {
                        files.append(
                            RemoteFile(
                                id: child.id ?? UUID().uuidString,
                                filename: sanitizePathComponent(name),
                                downloadLink: link,
                                relativeDirectory: nextPath,
                                expectedSize: child.size
                            )
                        )
                    }
                }
            }
        } else if let name = node.name, let link = node.link {
            files.append(
                RemoteFile(
                    id: node.id ?? identifier,
                    filename: sanitizePathComponent(name),
                    downloadLink: link,
                    relativeDirectory: currentPath,
                    expectedSize: node.size
                )
            )
        }
    }

    private func sanitizePathComponent(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty ? "unnamed" : cleaned
    }
}

// MARK: - DTOs

private struct AccountResponse: Decodable {
    let status: String
    let data: AccountData?

    struct AccountData: Decodable {
        let token: String?
    }
}

private struct ContentsResponse: Decodable {
    let status: String
    let data: ContentNode?
}

private struct ContentNode: Decodable {
    let id: String?
    let type: String?
    let name: String?
    let link: String?
    let size: Int64?
    let createTime: Int64?
    let password: Bool?
    let passwordStatus: String?
    let children: [String: ContentNode]?

    var requiresPassword: Bool {
        password != nil
    }

    enum CodingKeys: String, CodingKey {
        case id, type, name, link, size, createTime, password, passwordStatus, children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        link = try container.decodeIfPresent(String.self, forKey: .link)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        createTime = try container.decodeIfPresent(Int64.self, forKey: .createTime)
        passwordStatus = try container.decodeIfPresent(String.self, forKey: .passwordStatus)
        children = try container.decodeIfPresent([String: ContentNode].self, forKey: .children)

        // GoFile may return `password: true` or a string/int when password-protected
        if container.contains(.password) {
            if let boolVal = try? container.decode(Bool.self, forKey: .password) {
                password = boolVal
            } else if (try? container.decodeNil(forKey: .password)) == true {
                password = nil
            } else {
                password = true
            }
        } else {
            password = nil
        }
    }
}

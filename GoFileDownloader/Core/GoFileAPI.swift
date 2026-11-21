import CryptoKit
import Foundation

public struct RemoteFile: Sendable, Equatable, Identifiable {
    public let id: String
    public var filename: String
    public let downloadLink: String
    public let relativeDirectory: [String]
    public let expectedSize: Int64?
    public let md5: String?

    public init(
        id: String = UUID().uuidString,
        filename: String,
        downloadLink: String,
        relativeDirectory: [String],
        expectedSize: Int64? = nil,
        md5: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.downloadLink = downloadLink
        self.relativeDirectory = relativeDirectory
        self.expectedSize = expectedSize
        self.md5 = md5
    }

    public var relativePath: String {
        (relativeDirectory + [filename]).joined(separator: "/")
    }
}

public enum GoFileError: LocalizedError, Equatable, Sendable {
    case invalidURL(String)
    case accountCreationFailed
    case passwordRequired
    case wrongPassword
    case notFound(String)
    case notPublic(String)
    case unsafePath(String)
    case integrityMismatch(String)
    case checksumMismatch(expected: String, actual: String)
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
        case .wrongPassword:
            return "The provided password is incorrect. Please check and try again."
        case .notFound(let id):
            return "GoFile link '\(id)' was not found or has expired."
        case .notPublic(let id):
            return "GoFile link '\(id)' is not publicly accessible."
        case .unsafePath(let path):
            return "Blocked unsafe file path '\(path)' outside the destination folder."
        case .integrityMismatch(let details):
            return details
        case .checksumMismatch(let expected, let actual):
            return "File integrity check failed (MD5 expected \(expected), got \(actual))."
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

    /// Extracts the content ID from a valid GoFile URL (`https://[*.]gofile.io/d/<id>`).
    public static func contentID(from url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              host == "gofile.io" || host.hasSuffix(".gofile.io") else {
            return nil
        }
        let pathSegments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard pathSegments.count == 2, pathSegments[0] == "d" else {
            return nil
        }
        let id = pathSegments[1]
        guard Self.isValidContentID(id) else {
            return nil
        }
        return id
    }

    private static func isValidContentID(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
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
    public static func contentURL(contentID: String, hashedPassword: String? = nil, page: Int = 1) -> URL? {
        guard Self.isValidContentID(contentID),
              var components = URLComponents(string: "\(GoFileConfig.apiBase)/contents/\(contentID)") else {
            return nil
        }
        var queryItems = [
            URLQueryItem(name: "cache", value: "true"),
            URLQueryItem(name: "sortField", value: "createTime"),
            URLQueryItem(name: "sortDirection", value: "1"),
        ]
        if page > 1 {
            queryItems.append(URLQueryItem(name: "page", value: String(page)))
        }
        if let hashedPassword, !hashedPassword.isEmpty {
            queryItems.append(URLQueryItem(name: "password", value: hashedPassword))
        }
        components.queryItems = queryItems
        return components.url
    }

    /// Strips query strings, fragments, and credentials from URLs before surfacing in errors or logs.
    public static func redactedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.path.isEmpty ? "invalid-url" : url.path
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? url.path
    }

    /// Sanitizes an untrusted remote path component against traversal, control/bidi characters, and overlong names.
    public static func sanitizePathComponent(_ name: String) -> String {
        let bidiScalars: Set<UInt32> = [
            0x061C, 0x200E, 0x200F,
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0x2066, 0x2067, 0x2068, 0x2069,
        ]
        var filtered = String.UnicodeScalarView()
        filtered.reserveCapacity(name.unicodeScalars.count)
        for scalar in name.unicodeScalars {
            if scalar.value == 0 || CharacterSet.controlCharacters.contains(scalar) || bidiScalars.contains(scalar.value) {
                continue
            }
            switch scalar.value {
            case 0x2F, 0x5C, 0x3A: // '/', '\', ':'
                filtered.append("_")
            default:
                filtered.append(scalar)
            }
        }
        var cleaned = String(filtered)
        let trimmedForCheck = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedForCheck.isEmpty || trimmedForCheck == "." || trimmedForCheck == ".." {
            cleaned = "unnamed"
        }
        cleaned = FilenameResolver.truncatePreservingExtension(
            cleaned,
            maxBytes: GoFileConfig.maxPathComponentUTF8Bytes
        )
        let postTruncCheck = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if postTruncCheck.isEmpty || postTruncCheck == "." || postTruncCheck == ".." {
            return "unnamed"
        }
        return cleaned
    }

    /// Builds request headers matching `Downloader._prepare_headers`.
    public static func headers(
        accountToken: String,
        url: String? = nil,
        includeAuth: Bool = false,
        timestamp: Int64? = nil
    ) -> [String: String] {
        var headers = includeAuth ? GoFileConfig.extendedHeaders : GoFileConfig.downloadHeaders
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GoFileError.networkError("Failed to create account token: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw GoFileError.networkError("Invalid HTTP response from \(Self.redactedURLString(url)).")
        }
        guard (200...299).contains(http.statusCode) else {
            throw GoFileError.httpError(http.statusCode)
        }

        let decoded: AccountResponse
        do {
            decoded = try JSONDecoder().decode(AccountResponse.self, from: data)
        } catch {
            throw GoFileError.apiError("Failed to decode account response")
        }

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
        var visitedFolderIDs = Set<String>()
        var seenFileIDs = Set<String>()
        var reservedNamesByDir: [[String]: Set<String>] = [
            []: [FilenameResolver.caseFoldKey(GoFileConfig.partialStagingDirectoryName)]
        ]

        try await parseLinks(
            identifier: contentID,
            hashedPassword: hashedPassword,
            accountToken: accountToken,
            currentPath: [],
            depth: 0,
            resolvedFolderName: nil,
            visitedFolderIDs: &visitedFolderIDs,
            seenFileIDs: &seenFileIDs,
            reservedNamesByDir: &reservedNamesByDir,
            into: &rawFiles
        )

        // Deduplicate filenames per casefolded relative directory using FilenameResolver.
        var usedByDir: [[String]: Set<String>] = [:]
        var resolved: [RemoteFile] = []
        resolved.reserveCapacity(rawFiles.count)

        for var file in rawFiles {
            let dirKey = file.relativeDirectory.map(FilenameResolver.caseFoldKey)
            var set = usedByDir[dirKey] ?? reservedNamesByDir[dirKey] ?? Set<String>()
            file.filename = FilenameResolver.resolveUniqueFilename(file.filename, usedNames: &set)
            usedByDir[dirKey] = set
            resolved.append(file)
        }

        return resolved
    }

    private func parseLinks(
        identifier: String,
        hashedPassword: String?,
        accountToken: String,
        currentPath: [String],
        depth: Int,
        resolvedFolderName: String?,
        visitedFolderIDs: inout Set<String>,
        seenFileIDs: inout Set<String>,
        reservedNamesByDir: inout [[String]: Set<String>],
        into files: inout [RemoteFile]
    ) async throws {
        guard depth <= GoFileConfig.maxFolderRecursionDepth else {
            throw GoFileError.apiError(
                "Folder nesting exceeds maximum depth (\(GoFileConfig.maxFolderRecursionDepth))."
            )
        }
        guard visitedFolderIDs.insert(identifier).inserted else { return }

        var rootNode: ContentNode?
        var allChildren: [String: ContentNode] = [:]
        var hasMorePagesAfterCap = false

        for page in 1...GoFileConfig.maxPaginationPages {
            try Task.checkCancellation()

            guard let url = Self.contentURL(contentID: identifier, hashedPassword: hashedPassword, page: page) else {
                throw GoFileError.invalidURL(identifier)
            }

            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "GET"
            let reqHeaders = Self.headers(accountToken: accountToken, includeAuth: true)
            for (k, v) in reqHeaders {
                request.setValue(v, forHTTPHeaderField: k)
            }

            let data: Data
            let urlResponse: URLResponse
            do {
                (data, urlResponse) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            } catch {
                throw GoFileError.networkError(
                    "Failed to request \(Self.redactedURLString(url)): \(error.localizedDescription)"
                )
            }

            guard let http = urlResponse as? HTTPURLResponse else {
                throw GoFileError.networkError("Invalid HTTP response from \(Self.redactedURLString(url)).")
            }
            guard (200...299).contains(http.statusCode) else {
                throw GoFileError.httpError(http.statusCode)
            }

            let response: ContentsResponse
            do {
                response = try JSONDecoder().decode(ContentsResponse.self, from: data)
            } catch {
                throw GoFileError.apiError("Failed to decode response from \(Self.redactedURLString(url))")
            }

            guard response.status == "ok" else {
                switch response.status {
                case "error-notFound":
                    throw GoFileError.notFound(identifier)
                case "error-notPublic":
                    throw GoFileError.notPublic(identifier)
                case "error-passwordRequired":
                    throw GoFileError.passwordRequired
                case "error-passwordWrong":
                    throw GoFileError.wrongPassword
                default:
                    throw GoFileError.apiError(response.status)
                }
            }

            guard let node = response.data else {
                throw GoFileError.apiError("Missing content data from \(Self.redactedURLString(url)).")
            }

            if node.passwordStatus == "passwordWrong" {
                throw GoFileError.wrongPassword
            }
            if node.requiresPassword && node.passwordStatus != "passwordOk" {
                throw GoFileError.passwordRequired
            }

            if rootNode == nil {
                rootNode = node
            }

            if node.type != "folder" {
                break
            }

            let pageChildren = node.children ?? [:]
            for (key, value) in pageChildren {
                allChildren[key] = value
            }

            guard response.metadata?.hasNextPage == true, !pageChildren.isEmpty else {
                break
            }
            if page == GoFileConfig.maxPaginationPages {
                hasMorePagesAfterCap = true
            }
        }

        if hasMorePagesAfterCap {
            throw GoFileError.apiError(
                "Folder '\(rootNode?.name ?? identifier)' exceeds maximum pagination limit (\(GoFileConfig.maxPaginationPages) pages)."
            )
        }

        guard let node = rootNode else { return }

        if node.type == "folder" {
            let folderName: String
            if let resolvedFolderName {
                folderName = resolvedFolderName
            } else {
                let foldedParentDir = currentPath.map(FilenameResolver.caseFoldKey)
                var reserved = reservedNamesByDir[foldedParentDir, default: Set<String>()]
                folderName = FilenameResolver.resolveUniqueFilename(
                    Self.sanitizePathComponent(node.name ?? identifier),
                    usedNames: &reserved
                )
                reservedNamesByDir[foldedParentDir] = reserved
            }
            let nextPath = currentPath + [folderName]
            let foldedNextDir = nextPath.map(FilenameResolver.caseFoldKey)

            let sortedChildren = allChildren.sorted { lhs, rhs in
                let lTime = lhs.value.createTime ?? Int64.max
                let rTime = rhs.value.createTime ?? Int64.max
                if lTime != rTime { return lTime < rTime }
                let lName = lhs.value.name ?? ""
                let rName = rhs.value.name ?? ""
                if lName != rName { return lName < rName }
                return (lhs.value.id ?? lhs.key) < (rhs.value.id ?? rhs.key)
            }

            for (childKey, child) in sortedChildren {
                if child.type == "folder", let childID = child.id {
                    guard !visitedFolderIDs.contains(childID) else { continue }
                    var reserved = reservedNamesByDir[foldedNextDir, default: Set<String>()]
                    let uniqueSubfolder = FilenameResolver.resolveUniqueFilename(
                        Self.sanitizePathComponent(child.name ?? childID),
                        usedNames: &reserved
                    )
                    reservedNamesByDir[foldedNextDir] = reserved

                    try await parseLinks(
                        identifier: childID,
                        hashedPassword: hashedPassword,
                        accountToken: accountToken,
                        currentPath: nextPath,
                        depth: depth + 1,
                        resolvedFolderName: uniqueSubfolder,
                        visitedFolderIDs: &visitedFolderIDs,
                        seenFileIDs: &seenFileIDs,
                        reservedNamesByDir: &reservedNamesByDir,
                        into: &files
                    )
                } else if let name = child.name, let link = child.link {
                    let fileID = child.id ?? (childKey.isEmpty ? UUID().uuidString : "\(depth)-\(childKey)")
                    guard seenFileIDs.insert(fileID).inserted else { continue }
                    files.append(
                        RemoteFile(
                            id: fileID,
                            filename: Self.sanitizePathComponent(name),
                            downloadLink: link,
                            relativeDirectory: nextPath,
                            expectedSize: child.size,
                            md5: child.md5
                        )
                    )
                }
            }
        } else if let name = node.name, let link = node.link {
            let fileID = node.id ?? identifier
            guard seenFileIDs.insert(fileID).inserted else { return }
            files.append(
                RemoteFile(
                    id: fileID,
                    filename: Self.sanitizePathComponent(name),
                    downloadLink: link,
                    relativeDirectory: currentPath,
                    expectedSize: node.size,
                    md5: node.md5
                )
            )
        }
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
    let metadata: PageMetadata?
}

private struct PageMetadata: Decodable {
    let hasNextPage: Bool?
}

private struct ContentNode: Decodable {
    let id: String?
    let type: String?
    let name: String?
    let link: String?
    let size: Int64?
    let md5: String?
    let createTime: Int64?
    let password: Bool?
    let passwordStatus: String?
    let children: [String: ContentNode]?

    var requiresPassword: Bool {
        password == true
    }

    enum CodingKeys: String, CodingKey {
        case id, type, name, link, size, md5, createTime, password, passwordStatus, children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        link = try container.decodeIfPresent(String.self, forKey: .link)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        md5 = try container.decodeIfPresent(String.self, forKey: .md5)
        createTime = try container.decodeIfPresent(Int64.self, forKey: .createTime)
        passwordStatus = try container.decodeIfPresent(String.self, forKey: .passwordStatus)
        children = try container.decodeIfPresent([String: ContentNode].self, forKey: .children)

        // GoFile may return `password: true/false` or a string/int when password-protected
        if container.contains(.password) {
            if let boolVal = try? container.decode(Bool.self, forKey: .password) {
                password = boolVal
            } else if (try? container.decodeNil(forKey: .password)) == true {
                password = nil
            } else if let intVal = try? container.decode(Int.self, forKey: .password) {
                password = intVal != 0
            } else if let strVal = try? container.decode(String.self, forKey: .password) {
                let trimmed = strVal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                password = !trimmed.isEmpty && trimmed != "false" && trimmed != "0"
            } else {
                password = true
            }
        } else {
            password = nil
        }
    }
}

//
//  GoogleDriveService.swift
//  ForceFinder
//
//  Google Drive REST API v3 + OAuth2 지원
//

import Foundation
import AuthenticationServices

// MARK: - OAuth2 Token

struct GoogleOAuthToken: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt }
}

// MARK: - Google Drive API 응답 모델

private struct DriveFileList: Decodable {
    let files: [DriveFile]
    let nextPageToken: String?
}

private struct DriveFile: Decodable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let modifiedTime: String?
    let owners: [DriveOwner]?

    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
}

private struct DriveOwner: Decodable {
    let displayName: String?
    let emailAddress: String?
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
    let token_type: String
}

private struct UserInfo: Decodable {
    let email: String
    let name: String?
}

// MARK: - Google Drive Service

actor GoogleDriveService {
    static let shared = GoogleDriveService()

    private let baseURL = "https://www.googleapis.com/drive/v3"
    private let uploadURL = "https://www.googleapis.com/upload/drive/v3"
    private let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    private let userInfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"

    private let scopes = "https://www.googleapis.com/auth/drive"

    // 토큰 캐시: connectionID → token
    private var tokens: [UUID: GoogleOAuthToken] = [:]
    // 폴더 ID 캐시: "connectionID:path" → folderId
    private var folderIdCache: [String: String] = [:]

    // MARK: - Client Credentials

    static var clientId: String {
        get { UserDefaults.standard.string(forKey: "googleDrive.clientId") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "googleDrive.clientId") }
    }

    static var clientSecret: String {
        get { UserDefaults.standard.string(forKey: "googleDrive.clientSecret") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "googleDrive.clientSecret") }
    }

    // MARK: - OAuth2 Flow

    /// 브라우저 기반 OAuth2 인증 (loopback redirect)
    func authenticate() async throws -> (token: GoogleOAuthToken, email: String) {
        let clientId = Self.clientId
        let clientSecret = Self.clientSecret
        guard !clientId.isEmpty, !clientSecret.isEmpty else {
            throw GoogleDriveError.noCredentials
        }

        let (code, redirectURI) = try await getAuthorizationCode(clientId: clientId)
        let token = try await exchangeCodeForToken(
            code: code, clientId: clientId,
            clientSecret: clientSecret, redirectURI: redirectURI)

        let email = try await fetchUserEmail(accessToken: token.accessToken)
        return (token, email)
    }

    private func getAuthorizationCode(clientId: String) async throws -> (code: String, redirectURI: String) {
        let port = try findAvailablePort()
        let redirectURI = "http://localhost:\(port)/callback"

        var components = URLComponents(string: authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        let authURL = components.url!

        return try await withCheckedThrowingContinuation { continuation in
            // 로컬 HTTP 서버로 콜백 수신
            let server = LoopbackServer(port: port)
            server.start { result in
                switch result {
                case .success(let code):
                    continuation.resume(returning: (code, redirectURI))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            // 브라우저 열기
            DispatchQueue.main.async {
                NSWorkspace.shared.open(authURL)
            }
        }
    }

    private func exchangeCodeForToken(code: String, clientId: String,
                                       clientSecret: String, redirectURI: String) async throws -> GoogleOAuthToken {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code=\(code.urlEncoded)",
            "client_id=\(clientId.urlEncoded)",
            "client_secret=\(clientSecret.urlEncoded)",
            "redirect_uri=\(redirectURI.urlEncoded)",
            "grant_type=authorization_code"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GoogleDriveError.authFailed(errMsg)
        }

        let tokenResp = try JSONDecoder().decode(TokenResponse.self, from: data)
        return GoogleOAuthToken(
            accessToken: tokenResp.access_token,
            refreshToken: tokenResp.refresh_token ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResp.expires_in - 60))
        )
    }

    private func refreshAccessToken(connection: Connection) async throws -> GoogleOAuthToken {
        let clientId = Self.clientId
        let clientSecret = Self.clientSecret
        guard !clientId.isEmpty, !clientSecret.isEmpty else {
            throw GoogleDriveError.noCredentials
        }

        let refreshToken = connection.password // refresh token은 password 필드에 저장
        guard !refreshToken.isEmpty else {
            throw GoogleDriveError.authFailed("Refresh token이 없습니다. 다시 로그인해주세요.")
        }

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id=\(clientId.urlEncoded)",
            "client_secret=\(clientSecret.urlEncoded)",
            "refresh_token=\(refreshToken.urlEncoded)",
            "grant_type=refresh_token"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GoogleDriveError.authFailed("토큰 갱신 실패: \(errMsg)")
        }

        let tokenResp = try JSONDecoder().decode(TokenResponse.self, from: data)
        let token = GoogleOAuthToken(
            accessToken: tokenResp.access_token,
            refreshToken: tokenResp.refresh_token ?? refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResp.expires_in - 60))
        )
        tokens[connection.id] = token
        return token
    }

    private func fetchUserEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: userInfoURL)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        let info = try JSONDecoder().decode(UserInfo.self, from: data)
        return info.email
    }

    // MARK: - Token Management

    func setToken(_ token: GoogleOAuthToken, for connectionId: UUID) {
        tokens[connectionId] = token
    }

    private func validToken(for connection: Connection) async throws -> String {
        if let cached = tokens[connection.id], !cached.isExpired {
            return cached.accessToken
        }
        let refreshed = try await refreshAccessToken(connection: connection)
        return refreshed.accessToken
    }

    // MARK: - Path → Folder ID Resolution

    /// 경로를 Google Drive 폴더 ID로 변환
    /// "/" → "root", "/Documents/Photos" → 해당 폴더의 ID
    func resolveFolderId(connection: Connection, path: String) async throws -> String {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized.isEmpty { return "root" }

        let cacheKey = "\(connection.id):\(path)"
        if let cached = folderIdCache[cacheKey] { return cached }

        let components = normalized.components(separatedBy: "/")
        var currentId = "root"

        for component in components {
            let parentCacheKey = "\(connection.id):\(currentId)/\(component)"
            if let cached = folderIdCache[parentCacheKey] {
                currentId = cached
                continue
            }

            let accessToken = try await validToken(for: connection)
            let query = "'\(currentId)' in parents and name = '\(component.escapedForQuery)' and trashed = false"
            var urlComponents = URLComponents(string: "\(baseURL)/files")!
            urlComponents.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "files(id,name,mimeType)"),
                URLQueryItem(name: "pageSize", value: "1"),
            ]

            var request = URLRequest(url: urlComponents.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            try checkResponse(response, data: data)

            let result = try JSONDecoder().decode(DriveFileList.self, from: data)
            guard let file = result.files.first else {
                throw GoogleDriveError.notFound("'\(component)' 을(를) 찾을 수 없습니다.")
            }

            folderIdCache[parentCacheKey] = file.id
            currentId = file.id
        }

        folderIdCache[cacheKey] = currentId
        return currentId
    }

    // MARK: - File Operations

    func listFiles(connection: Connection, path: String) async throws -> [RemoteItem] {
        let folderId = try await resolveFolderId(connection: connection, path: path)
        let accessToken = try await validToken(for: connection)

        var allFiles: [DriveFile] = []
        var pageToken: String? = nil

        repeat {
            let query = "'\(folderId)' in parents and trashed = false"
            var urlComponents = URLComponents(string: "\(baseURL)/files")!
            var queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime,owners)"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "orderBy", value: "folder,name"),
            ]
            if let token = pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: token))
            }
            urlComponents.queryItems = queryItems

            var request = URLRequest(url: urlComponents.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            try checkResponse(response, data: data)

            let result = try JSONDecoder().decode(DriveFileList.self, from: data)
            allFiles.append(contentsOf: result.files)
            pageToken = result.nextPageToken
        } while pageToken != nil

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return allFiles.map { file in
            let modified: Date
            if let timeStr = file.modifiedTime {
                modified = dateFormatter.date(from: timeStr) ?? Date()
            } else {
                modified = Date()
            }
            let owner = file.owners?.first?.emailAddress ?? ""
            return RemoteItem(
                name: file.name,
                isDirectory: file.isFolder,
                size: Int64(file.size ?? "0") ?? 0,
                modified: modified,
                permissions: file.isFolder ? "drwxr-xr-x" : "-rw-r--r--",
                owner: owner,
                group: "",
                fullPath: file.id  // fullPath에 file ID 저장
            )
        }
    }

    func createFolder(connection: Connection, path: String) async throws {
        let parentPath = (path as NSString).deletingLastPathComponent
        let folderName = (path as NSString).lastPathComponent
        let parentId = try await resolveFolderId(connection: connection, path: parentPath)
        let accessToken = try await validToken(for: connection)

        var request = URLRequest(url: URL(string: "\(baseURL)/files")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "name": folderName,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parentId]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)

        // 캐시 무효화
        invalidateCache(for: connection, path: parentPath)
    }

    func deleteFile(connection: Connection, path: String, fileId: String?) async throws {
        let resolvedId: String
        if let id = fileId, !id.isEmpty {
            resolvedId = id
        } else {
            resolvedId = try await resolveFileId(connection: connection, path: path)
        }
        let accessToken = try await validToken(for: connection)

        var request = URLRequest(url: URL(string: "\(baseURL)/files/\(resolvedId)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 204 && http.statusCode != 200 {
            let errMsg = String(data: data, encoding: .utf8) ?? ""
            throw GoogleDriveError.apiFailed("삭제 실패: \(errMsg)")
        }

        let parentPath = (path as NSString).deletingLastPathComponent
        invalidateCache(for: connection, path: parentPath)
    }

    func renameFile(connection: Connection, fileId: String?, oldPath: String, newName: String) async throws {
        let resolvedId: String
        if let id = fileId, !id.isEmpty {
            resolvedId = id
        } else {
            resolvedId = try await resolveFileId(connection: connection, path: oldPath)
        }
        let accessToken = try await validToken(for: connection)

        var request = URLRequest(url: URL(string: "\(baseURL)/files/\(resolvedId)")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["name": newName]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)

        let parentPath = (oldPath as NSString).deletingLastPathComponent
        invalidateCache(for: connection, path: parentPath)
    }

    /// 파일 다운로드 → 로컬 경로에 저장
    func downloadFile(connection: Connection, fileId: String?, remotePath: String,
                      localPath: String, onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        let resolvedId: String
        if let id = fileId, !id.isEmpty {
            resolvedId = id
        } else {
            resolvedId = try await resolveFileId(connection: connection, path: remotePath)
        }
        let accessToken = try await validToken(for: connection)

        var request = URLRequest(url: URL(string: "\(baseURL)/files/\(resolvedId)?alt=media")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw GoogleDriveError.apiFailed("다운로드 실패 (HTTP \(http.statusCode))")
        }

        try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: localPath))
        let size = (try? FileManager.default.attributesOfItem(atPath: localPath)[.size] as? Int64) ?? 0
        onProgress(size)
    }

    /// 로컬 파일 → Google Drive에 업로드
    func uploadFile(connection: Connection, localPath: String, remotePath: String,
                    onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        let parentPath = (remotePath as NSString).deletingLastPathComponent
        let fileName = (remotePath as NSString).lastPathComponent
        let parentId = try await resolveFolderId(connection: connection, path: parentPath)
        let accessToken = try await validToken(for: connection)

        let fileData = try Data(contentsOf: URL(fileURLWithPath: localPath))
        let boundary = UUID().uuidString

        var request = URLRequest(url: URL(string: "\(uploadURL)/files?uploadType=multipart")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let metadata: [String: Any] = [
            "name": fileName,
            "parents": [parentId]
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataData)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)

        onProgress(Int64(fileData.count))
        invalidateCache(for: connection, path: parentPath)
    }

    // MARK: - Helpers

    private func resolveFileId(connection: Connection, path: String) async throws -> String {
        let parentPath = (path as NSString).deletingLastPathComponent
        let fileName = (path as NSString).lastPathComponent
        let parentId = try await resolveFolderId(connection: connection, path: parentPath)
        let accessToken = try await validToken(for: connection)

        let query = "'\(parentId)' in parents and name = '\(fileName.escapedForQuery)' and trashed = false"
        var urlComponents = URLComponents(string: "\(baseURL)/files")!
        urlComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id)"),
            URLQueryItem(name: "pageSize", value: "1"),
        ]

        var request = URLRequest(url: urlComponents.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkResponse(response, data: data)

        let result = try JSONDecoder().decode(DriveFileList.self, from: data)
        guard let file = result.files.first else {
            throw GoogleDriveError.notFound("'\(fileName)' 을(를) 찾을 수 없습니다.")
        }
        return file.id
    }

    private func invalidateCache(for connection: Connection, path: String) {
        let prefix = "\(connection.id):"
        folderIdCache = folderIdCache.filter { !$0.key.hasPrefix(prefix) || $0.key == "\(prefix)/" }
    }

    func clearCache(for connectionId: UUID) {
        let prefix = "\(connectionId):"
        folderIdCache = folderIdCache.filter { !$0.key.hasPrefix(prefix) }
        tokens.removeValue(forKey: connectionId)
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let errMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GoogleDriveError.apiFailed("HTTP \(http.statusCode): \(errMsg)")
        }
    }

    private func findAvailablePort() throws -> UInt16 {
        // 임시 소켓으로 사용 가능한 포트 찾기
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw GoogleDriveError.authFailed("소켓 생성 실패") }
        defer { close(socket) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // OS가 자동 할당
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw GoogleDriveError.authFailed("포트 바인드 실패") }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &addrLen)
            }
        }
        return UInt16(bigEndian: boundAddr.sin_port)
    }
}

// MARK: - Loopback HTTP Server (OAuth callback)

private class LoopbackServer {
    let port: UInt16
    private var serverSocket: Int32 = -1
    private var completion: ((Result<String, Error>) -> Void)?

    init(port: UInt16) {
        self.port = port
    }

    func start(completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion

        DispatchQueue.global().async { [self] in
            do {
                let sock = socket(AF_INET, SOCK_STREAM, 0)
                guard sock >= 0 else {
                    throw GoogleDriveError.authFailed("서버 소켓 생성 실패")
                }
                serverSocket = sock

                var reuse: Int32 = 1
                setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

                let bindResult = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                guard bindResult == 0 else {
                    close(sock)
                    throw GoogleDriveError.authFailed("포트 \(port) 바인드 실패")
                }

                listen(sock, 1)

                // 타임아웃 설정 (120초)
                var timeout = timeval(tv_sec: 120, tv_usec: 0)
                setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

                let client = accept(sock, nil, nil)
                defer {
                    close(client)
                    close(sock)
                }

                guard client >= 0 else {
                    throw GoogleDriveError.authFailed("인증 시간 초과")
                }

                var buffer = [UInt8](repeating: 0, count: 4096)
                let bytesRead = recv(client, &buffer, buffer.count, 0)
                guard bytesRead > 0 else {
                    throw GoogleDriveError.authFailed("요청 수신 실패")
                }

                let requestStr = String(bytes: buffer[..<bytesRead], encoding: .utf8) ?? ""

                // GET /callback?code=xxx HTTP/1.1 파싱
                guard let firstLine = requestStr.components(separatedBy: "\r\n").first,
                      let urlPart = firstLine.split(separator: " ").dropFirst().first,
                      let components = URLComponents(string: String(urlPart)),
                      let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {

                    // 에러 응답
                    if let errorParam = URLComponents(string: String(requestStr.split(separator: " ").dropFirst().first ?? ""))?
                        .queryItems?.first(where: { $0.name == "error" })?.value {
                        let html = "<!DOCTYPE html><html><body><h2>인증 실패</h2><p>\(errorParam)</p><p>이 창을 닫아도 됩니다.</p></body></html>"
                        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(html)"
                        _ = response.withCString { send(client, $0, strlen($0), 0) }
                        throw GoogleDriveError.authFailed("사용자가 인증을 거부했습니다: \(errorParam)")
                    }

                    let html = "<!DOCTYPE html><html><body><h2>인증 실패</h2><p>인증 코드를 받지 못했습니다.</p></body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(html)"
                    _ = response.withCString { send(client, $0, strlen($0), 0) }
                    throw GoogleDriveError.authFailed("인증 코드를 받지 못했습니다.")
                }

                // 성공 응답
                let html = "<!DOCTYPE html><html><body><h2>인증 성공!</h2><p>ForceFinder로 돌아가세요. 이 창을 닫아도 됩니다.</p></body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(html)"
                _ = response.withCString { send(client, $0, strlen($0), 0) }

                self.completion?(.success(code))
            } catch {
                self.completion?(.failure(error))
            }
        }
    }
}

// MARK: - Errors

enum GoogleDriveError: LocalizedError {
    case noCredentials
    case authFailed(String)
    case notFound(String)
    case apiFailed(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "Google Drive API 자격 증명이 설정되지 않았습니다. 설정에서 Client ID와 Secret을 입력해주세요."
        case .authFailed(let msg):
            return "Google 인증 실패: \(msg)"
        case .notFound(let msg):
            return "파일을 찾을 수 없음: \(msg)"
        case .apiFailed(let msg):
            return "Google Drive API 오류: \(msg)"
        }
    }
}

// MARK: - String Extensions

private extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "+", with: "%2B")
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: "=", with: "%3D") ?? self
    }

    var escapedForQuery: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }
}

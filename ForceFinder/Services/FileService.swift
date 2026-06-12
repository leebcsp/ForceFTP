//
//  FileService.swift
//  ForceFinder
//
//  실제 파일 시스템 및 원격 서버 접속 지원
//  - Local: FileManager
//  - SFTP: ssh/scp (Process)
//  - FTP/FTPS: curl (Process)
//

import Foundation

actor FileService {
    static let shared = FileService()

    // MARK: - Public ops

    func list(connection: Connection, path: String) async throws -> [RemoteItem] {
        var items: [RemoteItem]
        switch connection.proto {
        case .local:
            return try listLocal(path: path)
        case .sftp:
            items = try await listSFTP(connection: connection, path: path)
        case .ftp, .ftps:
            items = try await listFTP(connection: connection, path: path)
        case .googleDrive:
            return try await GoogleDriveService.shared.listFiles(connection: connection, path: path)
        default:
            throw FileServiceError.notSupported("\(connection.proto.displayName)은 아직 지원되지 않습니다.")
        }
        // 서버 파일에 TagStore 태그 적용
        for i in items.indices {
            let fullPath = (path as NSString).appendingPathComponent(items[i].name)
            if let color = TagStore.shared.tag(connection: connection, path: fullPath) {
                items[i].tagColorName = color
            }
        }
        return items
    }

    func mkdir(connection: Connection, path: String) async throws {
        switch connection.proto {
        case .local:
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        case .sftp:
            try await runSSH(connection: connection, command: "mkdir \(shellEscape(path))")
        case .ftp, .ftps:
            try await runCurl(connection: connection, args: ["-Q", "MKD \(path)", "\(ftpURL(connection, path: "/"))"])
        case .googleDrive:
            try await GoogleDriveService.shared.createFolder(connection: connection, path: path)
        default:
            throw FileServiceError.notSupported("mkdir: \(connection.proto.displayName) 미지원")
        }
    }

    func remove(connection: Connection, path: String, isDirectory: Bool) async throws {
        switch connection.proto {
        case .local:
            try FileManager.default.removeItem(atPath: path)
        case .sftp:
            let cmd = isDirectory ? "rm -rf \(shellEscape(path))" : "rm \(shellEscape(path))"
            try await runSSH(connection: connection, command: cmd)
        case .ftp, .ftps:
            let cmd = isDirectory ? "RMD \(path)" : "DELE \(path)"
            try await runCurl(connection: connection, args: ["-Q", cmd, "\(ftpURL(connection, path: "/"))"])
        case .googleDrive:
            // Google Drive에서는 fullPath에 fileId가 저장됨
            try await GoogleDriveService.shared.deleteFile(connection: connection, path: path, fileId: nil)
        default:
            throw FileServiceError.notSupported("remove: \(connection.proto.displayName) 미지원")
        }
    }

    func rename(connection: Connection, from oldPath: String, to newPath: String) async throws {
        switch connection.proto {
        case .local:
            try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
        case .sftp:
            try await runSSH(connection: connection,
                             command: "mv \(shellEscape(oldPath)) \(shellEscape(newPath))")
        case .googleDrive:
            let newName = (newPath as NSString).lastPathComponent
            try await GoogleDriveService.shared.renameFile(
                connection: connection, fileId: nil, oldPath: oldPath, newName: newName)
        default:
            throw FileServiceError.notSupported("rename: \(connection.proto.displayName) 미지원")
        }
    }

    /// 같은 서버 내 파일 이동 (mv)
    func moveFile(connection: Connection, from sourcePath: String, to destPath: String) async throws {
        switch connection.proto {
        case .local:
            try FileManager.default.moveItem(atPath: sourcePath, toPath: destPath)
        case .sftp:
            try await runSSH(connection: connection,
                             command: "mv \(shellEscape(sourcePath)) \(shellEscape(destPath))")
        case .googleDrive:
            // Google Drive에서는 rename으로 처리
            let newName = (destPath as NSString).lastPathComponent
            try await GoogleDriveService.shared.renameFile(
                connection: connection, fileId: nil, oldPath: sourcePath, newName: newName)
        default:
            throw FileServiceError.notSupported("move: \(connection.proto.displayName) 미지원")
        }
    }

    func chmod(connection: Connection, path: String,
               octal: String, recursive: Bool) async throws {
        switch connection.proto {
        case .local:
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/chmod")
            proc.arguments = recursive ? ["-R", octal, path] : [octal, path]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw FileServiceError.notSupported("chmod 실패 (exit \(proc.terminationStatus))")
            }
        case .sftp:
            let flag = recursive ? "-R " : ""
            try await runSSH(connection: connection, command: "chmod \(flag)\(octal) \(shellEscape(path))")
        default:
            throw FileServiceError.notSupported("chmod: \(connection.proto.displayName) 미지원")
        }
    }

    func chown(connection: Connection, path: String, owner: String, group: String) async throws {
        switch connection.proto {
        case .local:
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/chown")
            proc.arguments = ["\(owner):\(group)", path]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw FileServiceError.notSupported("chown 실패 (exit \(proc.terminationStatus))")
            }
        case .sftp:
            try await runSSH(connection: connection, command: "chown \(owner):\(group) \(shellEscape(path))")
        default:
            throw FileServiceError.notSupported("chown: \(connection.proto.displayName) 미지원")
        }
    }

    func copyAcross(source: Connection, sourcePath: String,
                    dest: Connection, destPath: String,
                    totalBytes: Int64,
                    isDirectory: Bool = false,
                    onFileProgress: ((@Sendable (String, Int, Int) -> Void))? = nil,
                    onProgress: @escaping @Sendable (Int64) -> Void) async throws {

        // Google Drive → Local (download)
        if source.proto == .googleDrive && dest.proto == .local {
            if isDirectory {
                // 디렉토리 다운로드: 재귀적으로 파일 목록 가져온 후 개별 다운로드
                try FileManager.default.createDirectory(atPath: destPath, withIntermediateDirectories: true)
                let items = try await GoogleDriveService.shared.listFiles(connection: source, path: sourcePath)
                let totalCount = items.count
                var completed = 0
                for item in items {
                    let childDest = (destPath as NSString).appendingPathComponent(item.name)
                    let childSource = (sourcePath as NSString).appendingPathComponent(item.name)
                    if item.isDirectory {
                        try await copyAcross(source: source, sourcePath: childSource,
                                             dest: dest, destPath: childDest,
                                             totalBytes: 0, isDirectory: true,
                                             onFileProgress: onFileProgress, onProgress: { _ in })
                    } else {
                        onFileProgress?(item.name, totalCount, completed)
                        try await GoogleDriveService.shared.downloadFile(
                            connection: source, fileId: item.fullPath,
                            remotePath: childSource, localPath: childDest, onProgress: { _ in })
                        completed += 1
                        onProgress(totalBytes * Int64(completed) / max(1, Int64(totalCount)))
                    }
                }
            } else {
                try await GoogleDriveService.shared.downloadFile(
                    connection: source, fileId: nil,
                    remotePath: sourcePath, localPath: destPath, onProgress: onProgress)
            }
            return
        }

        // Local → Google Drive (upload)
        if source.proto == .local && dest.proto == .googleDrive {
            if isDirectory {
                try await GoogleDriveService.shared.createFolder(connection: dest, path: destPath)
                let fm = FileManager.default
                let contents = try fm.contentsOfDirectory(atPath: sourcePath)
                let fileContents = contents.filter { name in
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: (sourcePath as NSString).appendingPathComponent(name), isDirectory: &isDir)
                    return !isDir.boolValue
                }
                let totalCount = fileContents.count
                var completed = 0
                for name in contents {
                    let childLocal = (sourcePath as NSString).appendingPathComponent(name)
                    let childRemote = (destPath as NSString).appendingPathComponent(name)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: childLocal, isDirectory: &isDir)
                    if isDir.boolValue {
                        try await copyAcross(source: source, sourcePath: childLocal,
                                             dest: dest, destPath: childRemote,
                                             totalBytes: 0, isDirectory: true,
                                             onFileProgress: onFileProgress, onProgress: { _ in })
                    } else {
                        onFileProgress?(name, totalCount, completed)
                        try await GoogleDriveService.shared.uploadFile(
                            connection: dest, localPath: childLocal,
                            remotePath: childRemote, onProgress: { _ in })
                        completed += 1
                        onProgress(totalBytes * Int64(completed) / max(1, Int64(totalCount)))
                    }
                }
            } else {
                try await GoogleDriveService.shared.uploadFile(
                    connection: dest, localPath: sourcePath,
                    remotePath: destPath, onProgress: onProgress)
            }
            return
        }

        // Local → Local
        if source.proto == .local && dest.proto == .local {
            try FileManager.default.copyItem(atPath: sourcePath, toPath: destPath)
            onProgress(totalBytes)
            return
        }

        // Local → SFTP (upload via scp)
        if source.proto == .local && dest.proto == .sftp {
            if isDirectory {
                try await scpTransferDirectory(
                    connection: dest, localPath: sourcePath,
                    remotePath: destPath, upload: true,
                    totalBytes: totalBytes,
                    onFileProgress: onFileProgress,
                    onProgress: onProgress)
            } else {
                try await scpTransfer(connection: dest, localPath: sourcePath,
                                      remotePath: destPath, upload: true,
                                      totalBytes: totalBytes, onProgress: onProgress)
            }
            return
        }

        // SFTP → Local (download via scp)
        if source.proto == .sftp && dest.proto == .local {
            if isDirectory {
                try await scpTransferDirectory(
                    connection: source, localPath: destPath,
                    remotePath: sourcePath, upload: false,
                    totalBytes: totalBytes,
                    onFileProgress: onFileProgress,
                    onProgress: onProgress)
            } else {
                try await scpTransfer(connection: source, localPath: destPath,
                                      remotePath: sourcePath, upload: false,
                                      totalBytes: totalBytes, onProgress: onProgress)
            }
            return
        }

        // Local → FTP (upload via curl)
        if source.proto == .local && (dest.proto == .ftp || dest.proto == .ftps) {
            try await curlFTPTransfer(connection: dest, localPath: sourcePath,
                                      remotePath: destPath, upload: true,
                                      totalBytes: totalBytes,
                                      onFileProgress: onFileProgress,
                                      onProgress: onProgress)
            return
        }

        // FTP → Local (download via curl)
        if (source.proto == .ftp || source.proto == .ftps) && dest.proto == .local {
            let remoteSrc = isDirectory && !sourcePath.hasSuffix("/")
                ? sourcePath + "/" : sourcePath
            try await curlFTPTransfer(connection: source, localPath: destPath,
                                      remotePath: remoteSrc, upload: false,
                                      totalBytes: totalBytes,
                                      onFileProgress: onFileProgress,
                                      onProgress: onProgress)
            return
        }

        // Same SFTP server → server-side cp
        if source.proto == .sftp && dest.proto == .sftp &&
           source.host == dest.host && source.port == dest.port &&
           source.username == dest.username {
            if isDirectory {
                // 디렉토리: 원격에서 파일 목록 수집 후 개별 cp
                try await runSSH(connection: source,
                                 command: "mkdir -p \(shellEscape(destPath))")
                var entries: [DirFileEntry] = []
                try await collectRemoteFiles(connection: source,
                                              remotePath: sourcePath, localPath: destPath,
                                              relativePrefix: "", into: &entries)
                let fileEntries = entries.filter { !$0.isDir }
                let totalCount = fileEntries.count
                var completed = 0
                for entry in entries {
                    if entry.isDir {
                        let destChild = (destPath as NSString).appendingPathComponent(entry.relativeName)
                        try await runSSH(connection: source,
                                         command: "mkdir -p \(shellEscape(destChild))")
                    } else {
                        onFileProgress?(entry.relativeName, totalCount, completed)
                        let destChild = (destPath as NSString).appendingPathComponent(entry.relativeName)
                        try await runSSH(connection: source,
                                         command: "cp \(shellEscape(entry.remotePath)) \(shellEscape(destChild))")
                        completed += 1
                        onProgress(totalBytes * Int64(completed) / max(1, Int64(totalCount)))
                    }
                }
            } else {
                try await runSSH(connection: source,
                                 command: "cp \(shellEscape(sourcePath)) \(shellEscape(destPath))")
                onProgress(totalBytes)
            }
            return
        }

        // Server → Server (로컬 임시 파일 경유)
        if source.proto != .local && dest.proto != .local {
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ForceFinder_\(UUID().uuidString)")
            let tmpPath = tmpDir.appendingPathComponent(
                (sourcePath as NSString).lastPathComponent).path
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            if isDirectory {
                // 디렉토리: 소스에서 파일 목록 수집 → 개별 다운로드 → 개별 업로드
                try FileManager.default.createDirectory(atPath: tmpPath, withIntermediateDirectories: true)

                var entries: [DirFileEntry] = []
                if source.proto == .sftp {
                    try await collectRemoteFiles(connection: source,
                                                  remotePath: sourcePath, localPath: tmpPath,
                                                  relativePrefix: "", into: &entries)
                } else {
                    try await collectFTPFiles(connection: source,
                                              remotePath: sourcePath, localPath: tmpPath,
                                              relativePrefix: "", into: &entries)
                }
                let fileEntries = entries.filter { !$0.isDir }
                let totalCount = fileEntries.count
                var completed = 0

                for entry in entries {
                    if entry.isDir {
                        try FileManager.default.createDirectory(
                            atPath: entry.localPath, withIntermediateDirectories: true)
                    } else {
                        onFileProgress?(entry.relativeName, totalCount, completed)
                        if source.proto == .sftp {
                            try await scpTransfer(connection: source,
                                                  localPath: entry.localPath,
                                                  remotePath: entry.remotePath,
                                                  upload: false, totalBytes: 0, onProgress: { _ in })
                        } else {
                            let url = ftpURL(source, path: entry.remotePath)
                            var args = ["-o", entry.localPath, url, "-s"]
                            if !source.anonymous {
                                args += ["-u", "\(source.username):\(source.password)"]
                            }
                            if source.proto == .ftps { args += ["--ssl-reqd"] }
                            _ = try await runCurlOutput(args: args)
                        }

                        let destChild = (destPath as NSString).appendingPathComponent(entry.relativeName)
                        let destDir = (destChild as NSString).deletingLastPathComponent
                        if dest.proto == .sftp {
                            try? await runSSH(connection: dest,
                                              command: "mkdir -p \(shellEscape(destDir))")
                            try await scpTransfer(connection: dest,
                                                  localPath: entry.localPath,
                                                  remotePath: destChild,
                                                  upload: true, totalBytes: 0, onProgress: { _ in })
                        } else {
                            try? await runCurl(connection: dest,
                                               args: ["-Q", "MKD \(destDir)",
                                                      "\(ftpURL(dest, path: "/"))"])
                            let url = ftpURL(dest, path: destChild)
                            var args = ["-T", entry.localPath, url, "-s"]
                            if !dest.anonymous {
                                args += ["-u", "\(dest.username):\(dest.password)"]
                            }
                            if dest.proto == .ftps { args += ["--ssl-reqd"] }
                            _ = try await runCurlOutput(args: args)
                        }

                        completed += 1
                        onProgress(totalBytes * Int64(completed) / max(1, Int64(totalCount)))
                    }
                }
            } else {
                // 단일 파일
                if source.proto == .sftp {
                    try await scpTransfer(connection: source, localPath: tmpPath,
                                          remotePath: sourcePath, upload: false,
                                          totalBytes: totalBytes) { bytes in
                        onProgress(bytes / 2)
                    }
                } else {
                    try await curlFTPTransfer(connection: source, localPath: tmpPath,
                                              remotePath: sourcePath, upload: false,
                                              totalBytes: totalBytes) { bytes in
                        onProgress(bytes / 2)
                    }
                }
                if dest.proto == .sftp {
                    try await scpTransfer(connection: dest, localPath: tmpPath,
                                          remotePath: destPath, upload: true,
                                          totalBytes: totalBytes) { _ in
                        onProgress(totalBytes)
                    }
                } else {
                    try await curlFTPTransfer(connection: dest, localPath: tmpPath,
                                              remotePath: destPath, upload: true,
                                              totalBytes: totalBytes) { _ in
                        onProgress(totalBytes)
                    }
                }
            }
            return
        }

        throw FileServiceError.notSupported("이 전송 조합은 아직 지원되지 않습니다.")
    }

    // MARK: - Local file listing

    private func listLocal(path: String) throws -> [RemoteItem] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .tagNamesKey
        ]
        let resourceURLs = try fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [])
        var items: [RemoteItem] = []
        items.reserveCapacity(resourceURLs.count)

        for fileURL in resourceURLs {
            do {
                let vals = try fileURL.resourceValues(forKeys: keys)
                let name = fileURL.lastPathComponent
                let ext = (name as NSString).pathExtension.lowercased()
                let isDir = (vals.isDirectory ?? false) && ext != "app"
                let size = Int64(vals.fileSize ?? 0)
                let modified = vals.contentModificationDate ?? Date()
                let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
                let owner = (attrs?[.ownerAccountName] as? String) ?? ""
                let group = (attrs?[.groupOwnerAccountName] as? String) ?? ""
                let posix = (attrs?[.posixPermissions] as? Int) ?? 0o644
                let perms = formatPosixPermissions(posix, isDirectory: isDir)

                var tagColor: String? = nil
                if let tags = vals.tagNames, !tags.isEmpty {
                    tagColor = Self.parseTagColor(tags)
                }

                items.append(RemoteItem(name: name, isDirectory: isDir,
                                       size: size, modified: modified,
                                       permissions: perms,
                                       owner: owner, group: group,
                                       tagColorName: tagColor))
            } catch {
                continue
            }
        }
        return items
    }

    /// tagNames 배열에서 색상 이름 파싱
    private static func parseTagColor(_ tags: [String]) -> String? {
        for tag in tags {
            let parts = tag.components(separatedBy: "\n")
            if parts.count >= 2, let num = Int(parts[1]),
               let color = tagColorMap[num] {
                return color
            }
            let lower = parts[0].lowercased()
            if tagColorMap.values.contains(lower) {
                return lower
            }
        }
        return nil
    }

    private func formatPosixPermissions(_ posix: Int, isDirectory: Bool) -> String {
        let head = isDirectory ? "d" : "-"
        let setuid = posix & 0o4000 != 0
        let setgid = posix & 0o2000 != 0
        let sticky = posix & 0o1000 != 0

        var s = head
        // Owner
        let oBits = (posix >> 6) & 0x7
        s += (oBits & 4 != 0) ? "r" : "-"
        s += (oBits & 2 != 0) ? "w" : "-"
        if setuid {
            s += (oBits & 1 != 0) ? "s" : "S"
        } else {
            s += (oBits & 1 != 0) ? "x" : "-"
        }
        // Group
        let gBits = (posix >> 3) & 0x7
        s += (gBits & 4 != 0) ? "r" : "-"
        s += (gBits & 2 != 0) ? "w" : "-"
        if setgid {
            s += (gBits & 1 != 0) ? "s" : "S"
        } else {
            s += (gBits & 1 != 0) ? "x" : "-"
        }
        // Others
        let tBits = posix & 0x7
        s += (tBits & 4 != 0) ? "r" : "-"
        s += (tBits & 2 != 0) ? "w" : "-"
        if sticky {
            s += (tBits & 1 != 0) ? "t" : "T"
        } else {
            s += (tBits & 1 != 0) ? "x" : "-"
        }
        return s
    }

    // MARK: - Finder Tags

    /// macOS Finder 태그 컬러 번호 → colorName 매핑
    private static let tagColorMap: [Int: String] = [
        1: "gray", 2: "green", 3: "purple", 4: "blue",
        5: "yellow", 6: "red", 7: "orange"
    ]

    private static let colorToTagNumber: [String: Int] = [
        "gray": 1, "green": 2, "purple": 3, "blue": 4,
        "yellow": 5, "red": 6, "orange": 7
    ]

    /// 파일의 Finder 태그 컬러 읽기
    static func readFinderTagColor(atPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let vals = try? url.resourceValues(forKeys: [.tagNamesKey]),
              let tags = vals.tagNames, !tags.isEmpty else { return nil }
        // Finder 태그 형식: "Red\n6" 또는 "Red"
        for tag in tags {
            let parts = tag.components(separatedBy: "\n")
            if parts.count >= 2, let num = Int(parts[1]),
               let color = tagColorMap[num] {
                return color
            }
            // 이름만 있는 경우
            let lower = parts[0].lowercased()
            if tagColorMap.values.contains(lower) {
                return lower
            }
        }
        return nil
    }

    /// 파일에 Finder 태그 컬러 설정 (nil이면 제거) — xattr 직접 사용
    func setFinderTagColor(atPath path: String, colorName: String?) throws {
        let url = URL(fileURLWithPath: path)
        if let colorName = colorName,
           let num = Self.colorToTagNumber[colorName] {
            let displayName = String(colorName.prefix(1)).uppercased() + colorName.dropFirst()
            // plist 형식으로 태그 배열 생성
            let tagArray = ["\(displayName)\n\(num)"] as NSArray
            let plistData = try PropertyListSerialization.data(
                fromPropertyList: tagArray, format: .binary, options: 0)
            // com.apple.metadata:_kMDItemUserTags xattr 설정
            let result = plistData.withUnsafeBytes { bytes in
                setxattr(url.path, "com.apple.metadata:_kMDItemUserTags",
                         bytes.baseAddress, bytes.count, 0, 0)
            }
            if result != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } else {
            // 태그 제거
            removexattr(url.path, "com.apple.metadata:_kMDItemUserTags", 0)
        }
    }

    /// 특정 태그 컬러가 지정된 파일 검색 (Spotlight)
    func findFilesWithTag(colorName: String, inPath searchPath: String) -> [String] {
        guard let num = Self.colorToTagNumber[colorName] else { return [] }
        let displayName = colorName.prefix(1).uppercased() + colorName.dropFirst()

        // Spotlight 쿼리로 태그된 파일 검색
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        proc.arguments = [
            "-onlyin", searchPath,
            "kMDItemUserTags == '\(displayName)' || kMDItemUserTags == '\(displayName)\n\(num)'"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    // MARK: - SFTP (ssh)

    private func listSFTP(connection: Connection, path: String) async throws -> [RemoteItem] {
        let output = try await runSSHOutput(
            connection: connection,
            command: "ls -la \(shellEscape(path))"
        )
        return parseLsOutput(output)
    }

    /// SSH ControlMaster 소켓 경로
    private func controlPath(for connection: Connection) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForceFinder_ssh").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/\(connection.host)_\(connection.port)_\(connection.username)"
    }

    /// SSH 공통 옵션 (ControlMaster 재사용)
    private func sshCommonArgs(for connection: Connection) -> [String] {
        let cp = controlPath(for: connection)
        return ["-o", "StrictHostKeyChecking=no",
                "-o", "ConnectTimeout=10",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(cp)",
                "-o", "ControlPersist=60"]
    }

    private func runSSHOutput(connection: Connection, command: String) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args = sshCommonArgs(for: connection)
        if connection.port != 22 {
            args += ["-p", "\(connection.port)"]
        }
        args += ["\(connection.username)@\(connection.host)", command]
        proc.arguments = args

        // 비밀번호가 있으면 sshpass 시도, 없으면 키 기반 인증
        if !connection.password.isEmpty {
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/sshpass") ||
               FileManager.default.fileExists(atPath: "/usr/local/bin/sshpass") {
                let sshpassPath = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/sshpass")
                    ? "/opt/homebrew/bin/sshpass"
                    : "/usr/local/bin/sshpass"
                proc.executableURL = URL(fileURLWithPath: sshpassPath)
                proc.arguments = ["-p", connection.password, "/usr/bin/ssh"] + args
            }
        }

        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let errOutput = String(data: errData, encoding: .utf8) ?? ""

                if proc.terminationStatus != 0 {
                    continuation.resume(throwing: FileServiceError.notSupported(
                        "SSH 오류: \(errOutput.isEmpty ? "exit \(proc.terminationStatus)" : errOutput.trimmingCharacters(in: .whitespacesAndNewlines))"
                    ))
                } else {
                    continuation.resume(returning: output)
                }
            }
            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func runSSH(connection: Connection, command: String) async throws {
        _ = try await runSSHOutput(connection: connection, command: command)
    }

    private func parseLsOutput(_ output: String) -> [RemoteItem] {
        let lines = output.components(separatedBy: "\n")
        var items: [RemoteItem] = []
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("total") else { continue }
            if let item = parseUnixFTPLine(trimmed, username: "", dateFormatter: dateFormatter) {
                items.append(item)
            }
        }
        return items
    }

    // MARK: - SCP transfer

    private func scpTransfer(connection: Connection, localPath: String,
                             remotePath: String, upload: Bool,
                             totalBytes: Int64,
                             onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/scp")

        let cp = controlPath(for: connection)
        var args = ["-r",
                    "-o", "StrictHostKeyChecking=no",
                    "-o", "ControlMaster=auto",
                    "-o", "ControlPath=\(cp)",
                    "-o", "ControlPersist=60"]
        if connection.port != 22 {
            args += ["-P", "\(connection.port)"]
        }
        let remote = "\(connection.username)@\(connection.host):\(remotePath)"
        if upload {
            args += [localPath, remote]
        } else {
            args += [remote, localPath]
        }
        proc.arguments = args

        if !connection.password.isEmpty {
            if let sshpassPath = findSshpass() {
                proc.executableURL = URL(fileURLWithPath: sshpassPath)
                proc.arguments = ["-p", connection.password, "/usr/bin/scp"] + args
            }
        }

        let errPipe = Pipe()
        proc.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            proc.terminationHandler = { _ in
                if proc.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let detail = errMsg.isEmpty ? "exit \(proc.terminationStatus)" : errMsg
                    continuation.resume(throwing: FileServiceError.notSupported(
                        "SCP 전송 실패: \(detail)"
                    ))
                } else {
                    onProgress(totalBytes)
                    continuation.resume(returning: ())
                }
            }
            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// SFTP 디렉토리 재귀 전송 — 먼저 전체 파일 목록을 모은 후 순서대로 전송
    private func scpTransferDirectory(connection: Connection, localPath: String,
                                       remotePath: String, upload: Bool,
                                       totalBytes: Int64,
                                       onFileProgress: ((@Sendable (String, Int, Int) -> Void))?,
                                       onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        // 1) 최상위 디렉토리 생성
        if upload {
            try await runSSH(connection: connection,
                             command: "mkdir -p \(shellEscape(remotePath))")
        } else {
            try FileManager.default.createDirectory(
                atPath: localPath, withIntermediateDirectories: true)
        }

        // 2) 전체 파일/디렉토리 목록 수집 (재귀)
        var entries: [DirFileEntry] = []

        if upload {
            collectLocalFiles(atPath: localPath, remotePath: remotePath,
                              relativePrefix: "", into: &entries)
        } else {
            try await collectRemoteFiles(connection: connection,
                                          remotePath: remotePath, localPath: localPath,
                                          relativePrefix: "", into: &entries)
        }

        // 3) 디렉토리 먼저 일괄 생성
        let dirEntries = entries.filter { $0.isDir }
        let fileEntries = entries.filter { !$0.isDir }
        let totalCount = fileEntries.count

        if upload {
            // 원격 디렉토리 일괄 생성 (한 번의 SSH로)
            if !dirEntries.isEmpty {
                let mkdirCmd = dirEntries.map { "mkdir -p \(shellEscape($0.remotePath))" }
                    .joined(separator: " && ")
                try await runSSH(connection: connection, command: mkdirCmd)
            }
        } else {
            for dir in dirEntries {
                try FileManager.default.createDirectory(
                    atPath: dir.localPath, withIntermediateDirectories: true)
            }
        }

        // 4) 파일 병렬 전송 (최대 4개 동시)
        let maxConcurrent = 4
        var transferred: Int64 = 0
        var completed = 0

        for batchStart in stride(from: 0, to: fileEntries.count, by: maxConcurrent) {
            let batchEnd = min(batchStart + maxConcurrent, fileEntries.count)
            let batch = Array(fileEntries[batchStart..<batchEnd])

            // 전송 시작 알림
            for (i, entry) in batch.enumerated() {
                onFileProgress?(entry.relativeName, totalCount, completed + i)
            }

            // 병렬 전송
            try await withThrowingTaskGroup(of: Int64.self) { group in
                for entry in batch {
                    group.addTask {
                        try await self.scpTransfer(connection: connection,
                                                   localPath: entry.localPath,
                                                   remotePath: entry.remotePath,
                                                   upload: upload,
                                                   totalBytes: 0, onProgress: { _ in })
                        return entry.size
                    }
                }
                for try await size in group {
                    transferred += size
                    completed += 1
                    onProgress(transferred)
                }
            }
        }
    }

    /// 로컬 디렉토리 재귀 탐색하여 파일 목록 수집
    private struct DirFileEntry {
        let localPath: String
        let remotePath: String
        let relativeName: String
        let isDir: Bool
        let size: Int64
    }

    private func collectLocalFiles(atPath localDir: String, remotePath remoteDir: String,
                                    relativePrefix: String, into entries: inout [DirFileEntry]) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: localDir).sorted() else { return }
        for name in contents {
            let childLocal = (localDir as NSString).appendingPathComponent(name)
            let childRemote = (remoteDir as NSString).appendingPathComponent(name)
            let relName = relativePrefix.isEmpty ? name : relativePrefix + "/" + name
            var isChildDir: ObjCBool = false
            fm.fileExists(atPath: childLocal, isDirectory: &isChildDir)
            if isChildDir.boolValue {
                entries.append(DirFileEntry(localPath: childLocal, remotePath: childRemote,
                                            relativeName: relName, isDir: true, size: 0))
                collectLocalFiles(atPath: childLocal, remotePath: childRemote,
                                   relativePrefix: relName, into: &entries)
            } else {
                let sz = (try? fm.attributesOfItem(atPath: childLocal)[.size] as? Int64) ?? 0
                entries.append(DirFileEntry(localPath: childLocal, remotePath: childRemote,
                                            relativeName: relName, isDir: false, size: sz))
            }
        }
    }

    /// 원격 SFTP 디렉토리 재귀 탐색하여 파일 목록 수집
    private func collectRemoteFiles(connection: Connection,
                                     remotePath remoteDir: String, localPath localDir: String,
                                     relativePrefix: String, into entries: inout [DirFileEntry]) async throws {
        let items = try await listSFTP(connection: connection, path: remoteDir)
        for item in items.sorted(by: { $0.name < $1.name }) {
            let childRemote = (remoteDir as NSString).appendingPathComponent(item.name)
            let childLocal = (localDir as NSString).appendingPathComponent(item.name)
            let relName = relativePrefix.isEmpty ? item.name : relativePrefix + "/" + item.name
            if item.isDirectory {
                entries.append(DirFileEntry(localPath: childLocal, remotePath: childRemote,
                                            relativeName: relName, isDir: true, size: 0))
                try await collectRemoteFiles(connection: connection,
                                              remotePath: childRemote, localPath: childLocal,
                                              relativePrefix: relName, into: &entries)
            } else {
                entries.append(DirFileEntry(localPath: childLocal, remotePath: childRemote,
                                            relativeName: relName, isDir: false, size: item.size))
            }
        }
    }

    /// 원격 FTP 디렉토리 재귀 탐색하여 파일 목록 수집
    private func collectFTPFiles(connection: Connection,
                                  remotePath remoteDir: String, localPath localDir: String,
                                  relativePrefix: String, into entries: inout [DirFileEntry]) async throws {
        let items = try await listFTP(connection: connection, path: remoteDir)
        for item in items.sorted(by: { $0.name < $1.name }) {
            let childRemote = (remoteDir as NSString).appendingPathComponent(item.name)
            let childLocal = (localDir as NSString).appendingPathComponent(item.name)
            let relName = relativePrefix.isEmpty ? item.name : relativePrefix + "/" + item.name
            if item.isDirectory {
                entries.append(DirFileEntry(localPath: childLocal, remotePath: childRemote,
                                            relativeName: relName, isDir: true, size: 0))
                try await collectFTPFiles(connection: connection,
                                           remotePath: childRemote, localPath: childLocal,
                                           relativePrefix: relName, into: &entries)
            } else {
                entries.append(DirFileEntry(localPath: childLocal, remotePath: childRemote,
                                            relativeName: relName, isDir: false, size: item.size))
            }
        }
    }

    // MARK: - FTP (curl)

    private func listFTP(connection: Connection, path: String) async throws -> [RemoteItem] {
        let dirPath = path.hasSuffix("/") ? path : path + "/"

        // curl -l : NLST (이름만), 기본 FTP LIST: 상세 정보
        // 먼저 상세 목록(LIST) 시도 — curl FTP 디렉토리 URL 요청 시 기본 동작
        var detailArgs = [ftpURL(connection, path: dirPath)]
        if !connection.anonymous {
            detailArgs += ["-u", "\(connection.username):\(connection.password)"]
        }
        if connection.proto == .ftps {
            detailArgs += ["--ssl-reqd", "-k"]
        }
        detailArgs += ["--connect-timeout", "10", "--max-time", "30"]

        let output = try await runCurlOutput(args: detailArgs)

        // FTP LIST 출력 파싱
        let items = parseFTPList(output, username: connection.username)
        if !items.isEmpty { return items }

        // 상세 파싱 실패 시 NLST(이름만) 시도
        var nlstArgs = [ftpURL(connection, path: dirPath), "--list-only"]
        if !connection.anonymous {
            nlstArgs += ["-u", "\(connection.username):\(connection.password)"]
        }
        if connection.proto == .ftps {
            nlstArgs += ["--ssl-reqd", "-k"]
        }
        nlstArgs += ["--connect-timeout", "10", "--max-time", "30"]

        let simpleOutput = try await runCurlOutput(args: nlstArgs)
        return simpleOutput.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .map { name in
                let isDir = !name.contains(".")
                return RemoteItem(name: name, isDirectory: isDir,
                                  size: 0, modified: Date(),
                                  permissions: isDir ? "drwxr-xr-x" : "-rw-r--r--",
                                  owner: connection.username, group: "")
            }
    }

    /// FTP LIST 출력 파싱 (Unix 스타일 + Windows IIS 스타일 지원)
    private func parseFTPList(_ output: String, username: String) -> [RemoteItem] {
        let lines = output.components(separatedBy: "\n")
        var items: [RemoteItem] = []
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("total") else { continue }

            // Windows IIS 형식: "05-22-26  10:30AM       <DIR>          foldername"
            if let item = parseWindowsFTPLine(trimmed, username: username) {
                items.append(item)
                continue
            }

            // Unix 형식: "drwxr-xr-x  2 user group  4096 May 22 10:00 filename"
            // 또는:      "-rw-r--r--  1 user group  1234 May 22 2025 filename"
            // 또는:      "drwxr-xr-x  2 0    0      4096 May 22 10:00 filename"
            if let item = parseUnixFTPLine(trimmed, username: username, dateFormatter: dateFormatter) {
                items.append(item)
                continue
            }
        }
        return items
    }

    private func parseUnixFTPLine(_ line: String, username: String, dateFormatter: DateFormatter) -> RemoteItem? {
        // 퍼미션 문자로 시작하는지 확인
        guard let first = line.first, "dl-crwxbps".contains(first) else { return nil }

        // 최소 8개 필드: perms links owner group size month day time/year [name...]
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 9 else { return nil }

        let perms = String(parts[0])
        guard perms.count >= 10 else { return nil }

        // links 필드 건너뛰기 (parts[1])
        let owner = String(parts[2])
        let group = String(parts[3])
        let size = Int64(parts[4]) ?? 0

        let monthStr = String(parts[5])
        let dayStr = String(parts[6])
        let timeOrYear = String(parts[7])

        // 파일명을 정확히 추출: 8번째 공백 구분자 이후 나머지 전부
        let name: String
        var spaceCount = 0
        var nameIdx = line.startIndex
        for (i, ch) in line.enumerated() {
            if ch == " " || ch == "\t" {
                if i > 0 {
                    let prev = line[line.index(line.startIndex, offsetBy: i - 1)]
                    if prev != " " && prev != "\t" {
                        spaceCount += 1
                    }
                }
            }
            if spaceCount == 8 && ch != " " && ch != "\t" {
                nameIdx = line.index(line.startIndex, offsetBy: i)
                break
            }
        }
        name = String(line[nameIdx...]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        // 심볼릭 링크의 " -> target" 제거
        let displayName: String
        if let arrowRange = name.range(of: " -> ") {
            displayName = String(name[name.startIndex..<arrowRange.lowerBound])
        } else {
            displayName = name
        }

        let isDir = perms.hasPrefix("d") || perms.hasPrefix("l")

        // 날짜 파싱
        var modified = Date()
        let year = Calendar.current.component(.year, from: Date())
        if timeOrYear.contains(":") {
            dateFormatter.dateFormat = "MMM dd HH:mm yyyy"
            modified = dateFormatter.date(from: "\(monthStr) \(dayStr) \(timeOrYear) \(year)") ?? Date()
        } else {
            dateFormatter.dateFormat = "MMM dd yyyy"
            modified = dateFormatter.date(from: "\(monthStr) \(dayStr) \(timeOrYear)") ?? Date()
        }

        return RemoteItem(name: displayName, isDirectory: isDir,
                          size: size, modified: modified,
                          permissions: perms,
                          owner: owner, group: group)
    }

    private func parseWindowsFTPLine(_ line: String, username: String) -> RemoteItem? {
        // "05-22-26  10:30AM       <DIR>          foldername"
        // "05-22-26  10:30AM              12345   filename.txt"
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return nil }

        let dateStr = String(parts[0])  // MM-DD-YY
        let timeStr = String(parts[1])  // HH:MMAM/PM

        // MM-DD-YY 형식인지 확인
        guard dateStr.contains("-"),
              dateStr.split(separator: "-").count == 3 else { return nil }

        let isDir = parts[2] == "<DIR>"
        let size: Int64
        let nameIndex: Int

        if isDir {
            size = 0
            nameIndex = 3
        } else {
            size = Int64(parts[2]) ?? 0
            nameIndex = 3
        }

        guard parts.count > nameIndex else { return nil }
        let name = parts[nameIndex...].joined(separator: " ")
        guard name != ".", name != ".." else { return nil }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "MM-dd-yy hh:mma"
        let modified = dateFormatter.date(from: "\(dateStr) \(timeStr)") ?? Date()

        return RemoteItem(name: name, isDirectory: isDir,
                          size: size, modified: modified,
                          permissions: isDir ? "drwxr-xr-x" : "-rw-r--r--",
                          owner: username, group: "")
    }

    private func curlFTPTransfer(connection: Connection, localPath: String,
                                  remotePath: String, upload: Bool,
                                  totalBytes: Int64,
                                  onFileProgress: ((@Sendable (String, Int, Int) -> Void))? = nil,
                                  onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        // 디렉토리 판별
        let isDir: Bool
        if upload {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: localPath, isDirectory: &isDirectory)
            isDir = isDirectory.boolValue
        } else {
            // 다운로드 시 remotePath가 /로 끝나면 디렉토리
            isDir = remotePath.hasSuffix("/")
        }

        if isDir {
            // 전체 파일 수 계산
            var fileCount = 0
            if upload {
                fileCount = Self.localFileCount(path: localPath)
            }
            try await curlFTPTransferDirectory(
                connection: connection, localPath: localPath,
                remotePath: remotePath, upload: upload,
                totalBytes: totalBytes,
                fileCount: fileCount, completedCount: 0,
                onFileProgress: onFileProgress,
                onProgress: onProgress)
            return
        }

        let url = ftpURL(connection, path: remotePath)
        var args: [String]

        if upload {
            args = ["-T", localPath, url]
        } else {
            args = ["-o", localPath, url]
        }

        if !connection.anonymous {
            args += ["-u", "\(connection.username):\(connection.password)"]
        }
        if connection.proto == .ftps {
            args += ["--ssl-reqd"]
        }

        try await runCurl(connection: connection, args: args)
        onProgress(totalBytes)
    }

    /// FTP 디렉토리 재귀 전송
    private func curlFTPTransferDirectory(connection: Connection, localPath: String,
                                           remotePath: String, upload: Bool,
                                           totalBytes: Int64,
                                           fileCount: Int, completedCount: Int,
                                           onFileProgress: ((@Sendable (String, Int, Int) -> Void))?,
                                           onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        var completed = completedCount
        if upload {
            // 로컬 → FTP: 원격에 디렉토리 생성 후 재귀 전송
            let dirPath = remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
            try? await runCurl(connection: connection,
                               args: ["-Q", "MKD \(remotePath)", "\(ftpURL(connection, path: "/"))"])

            let fm = FileManager.default
            let contents = try fm.contentsOfDirectory(atPath: localPath)
            var transferred: Int64 = 0
            for name in contents {
                let childLocal = (localPath as NSString).appendingPathComponent(name)
                let childRemote = dirPath + name
                var isChildDir: ObjCBool = false
                fm.fileExists(atPath: childLocal, isDirectory: &isChildDir)

                if isChildDir.boolValue {
                    try await curlFTPTransferDirectory(
                        connection: connection, localPath: childLocal,
                        remotePath: childRemote, upload: true,
                        totalBytes: totalBytes,
                        fileCount: fileCount, completedCount: completed,
                        onFileProgress: onFileProgress,
                        onProgress: onProgress)
                    completed += Self.localFileCount(path: childLocal)
                } else {
                    onFileProgress?(name, fileCount, completed)
                    let url = ftpURL(connection, path: childRemote)
                    var args = ["-T", childLocal, url]
                    if !connection.anonymous {
                        args += ["-u", "\(connection.username):\(connection.password)"]
                    }
                    if connection.proto == .ftps {
                        args += ["--ssl-reqd"]
                    }
                    try await runCurl(connection: connection, args: args)
                    let fileSize = (try? fm.attributesOfItem(atPath: childLocal)[.size] as? Int64) ?? 0
                    transferred += fileSize
                    completed += 1
                    onProgress(transferred)
                }
            }
        } else {
            // FTP → 로컬: 원격 디렉토리 목록 후 재귀 다운로드
            let fm = FileManager.default
            try fm.createDirectory(atPath: localPath, withIntermediateDirectories: true)

            let dirPath = remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
            let items = try await listFTP(connection: connection, path: dirPath)
            var transferred: Int64 = 0

            for item in items {
                let childLocal = (localPath as NSString).appendingPathComponent(item.name)
                let childRemote = dirPath + item.name

                if item.isDirectory {
                    try await curlFTPTransferDirectory(
                        connection: connection, localPath: childLocal,
                        remotePath: childRemote + "/", upload: false,
                        totalBytes: totalBytes,
                        fileCount: fileCount, completedCount: completed,
                        onFileProgress: onFileProgress,
                        onProgress: onProgress)
                } else {
                    onFileProgress?(item.name, fileCount, completed)
                    let url = ftpURL(connection, path: childRemote)
                    var args = ["-o", childLocal, url]
                    if !connection.anonymous {
                        args += ["-u", "\(connection.username):\(connection.password)"]
                    }
                    if connection.proto == .ftps {
                        args += ["--ssl-reqd"]
                    }
                    try await runCurl(connection: connection, args: args)
                    transferred += item.size
                    completed += 1
                    onProgress(transferred)
                }
            }
        }
    }

    private func ftpURL(_ connection: Connection, path: String) -> String {
        let scheme = connection.proto == .ftps ? "ftps" : "ftp"
        let port = connection.port != connection.proto.defaultPort ? ":\(connection.port)" : ""
        return "\(scheme)://\(connection.host)\(port)\(path)"
    }

    private func runCurlOutput(args: [String]) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = args + ["-s"]  // silent mode

        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: FileServiceError.notSupported(
                        "FTP 오류: \(errMsg.isEmpty ? "exit \(proc.terminationStatus)" : errMsg.trimmingCharacters(in: .whitespacesAndNewlines))"
                    ))
                } else {
                    continuation.resume(returning: output)
                }
            }
            do {
                try proc.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func runCurl(connection: Connection, args: [String]) async throws {
        _ = try await runCurlOutput(args: args + ["-s"])
    }

    // MARK: - Directory size

    /// 로컬 디렉토리의 총 크기 계산 (재귀)
    static func localDirectorySize(path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    /// 로컬 디렉토리의 파일 개수 (재귀, 디렉토리 제외)
    static func localFileCount(path: String) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var count = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            if !isDir.boolValue { count += 1 }
        }
        return count
    }

    // MARK: - Helpers

    private func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func findSshpass() -> String? {
        let paths = ["/opt/homebrew/bin/sshpass", "/usr/local/bin/sshpass"]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }
}

enum FileServiceError: LocalizedError {
    case notFound(String)
    case notADirectory(String)
    case exists(String)
    case notSupported(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let p):     return "찾을 수 없음: \(p)"
        case .notADirectory(let p): return "디렉토리가 아닙니다: \(p)"
        case .exists(let n):       return "이미 존재합니다: \(n)"
        case .notSupported(let m): return m
        }
    }
}

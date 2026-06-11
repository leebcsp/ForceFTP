//
//  Models.swift
//  ForceFTP
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import QuickLookThumbnailing

// MARK: - Adaptive Colors

extension Color {
    /// 헤더, 상태바
    static let panelHeader = Color(nsColor: .init(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.15, green: 0.15, blue: 0.16, alpha: 1)
            : .windowBackgroundColor
    })
    /// 카드, 인스펙터, 행 교대
    static let panelCard = Color(nsColor: .init(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)
            : NSColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)
    })
    /// 리스트 배경
    static let panelList = Color(nsColor: .init(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.18, green: 0.18, blue: 0.19, alpha: 1)
            : .textBackgroundColor
    })
    /// 포인터/강조 색상 (다크: 노랑, 라이트: 파랑)
    static let accentTint = Color(nsColor: .init(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.76, green: 0.60, blue: 0.20, alpha: 1)
            : NSColor(red: 0.25, green: 0.52, blue: 0.95, alpha: 1)
    })
    /// 최근 수정 파일 색상 (다크: 노랑, 라이트: 파랑)
    static let recentTint = Color(nsColor: .init(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.94, green: 0.81, blue: 0.33, alpha: 1)
            : NSColor(red: 0.15, green: 0.40, blue: 0.85, alpha: 1)
    })
    /// 활성 헤더 텍스트 (다크: 검정, 라이트: 흰색)
    static let activeHeaderFg = Color(nsColor: .init(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.1, green: 0.08, blue: 0.02, alpha: 1)
            : .white
    })
    /// 활성 헤더 보조 텍스트
    static let activeHeaderDim = Color(nsColor: .init(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.25, green: 0.20, blue: 0.05, alpha: 1)
            : NSColor.white.withAlphaComponent(0.7)
    })
    /// 활성 헤더 배지 배경
    static let activeHeaderBadge = Color(nsColor: .init(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.25)
            : NSColor(red: 0.90, green: 0.78, blue: 0.40, alpha: 1)
    })
    /// 카드 테두리
    static let panelBorder = Color(nsColor: .init(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.black.withAlphaComponent(0.08)
    })
}

// MARK: - Protocol

enum TransferProtocol: String, CaseIterable, Identifiable, Codable, Hashable {
    case local
    case sftp
    case ftp
    case ftps
    case webdav
    case s3
    case smb
    case googleDrive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:       return "LOCAL"
        case .sftp:        return "SFTP"
        case .ftp:         return "FTP"
        case .ftps:        return "FTPS"
        case .webdav:      return "WebDAV"
        case .s3:          return "Amazon S3"
        case .smb:         return "SMB"
        case .googleDrive: return "Google Drive"
        }
    }

    var defaultPort: Int {
        switch self {
        case .local:       return 0
        case .sftp:        return 22
        case .ftp:         return 21
        case .ftps:        return 990
        case .webdav:      return 443
        case .s3:          return 443
        case .smb:         return 445
        case .googleDrive: return 443
        }
    }

    var badgeColor: Color {
        switch self {
        case .local:       return Color(red: 0.43, green: 0.43, blue: 0.45)
        case .sftp:        return Color(red: 0.04, green: 0.42, blue: 1.00)
        case .ftp:         return Color(red: 1.00, green: 0.58, blue: 0.00)
        case .ftps:        return Color(red: 0.35, green: 0.34, blue: 0.84)
        case .webdav:      return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .s3:          return Color(red: 1.00, green: 0.23, blue: 0.19)
        case .smb:         return Color(red: 0.69, green: 0.32, blue: 0.87)
        case .googleDrive: return Color(red: 0.26, green: 0.52, blue: 0.96)
        }
    }
}

// MARK: - Connection

struct Connection: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var proto: TransferProtocol
    var host: String
    var port: Int
    var username: String
    var password: String
    var remotePath: String
    var anonymous: Bool = false

    static let localPlaceholder = Connection(
        name: "내 Mac",
        proto: .local,
        host: "localhost",
        port: 0,
        username: NSUserName(),
        password: "",
        remotePath: NSHomeDirectory()
    )
}

// MARK: - Remote item

struct RemoteItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date
    var permissions: String   // e.g. "-rw-r--r--"
    var owner: String
    var group: String
    var tagColorName: String?  // macOS Finder 태그 컬러: "gray","green","purple","blue","yellow","red","orange"
    var fullPath: String?      // 태그 검색 결과에서 원본 경로 (nil이면 currentPath 기준)

    var iconName: String {
        if isDirectory { return "folder" }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "app" { return "app.dashed" }
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "bmp":
            return "photo"
        case "zip", "tar", "gz", "tgz", "bz2", "7z", "rar":
            return "doc.zipper"
        case "mp4", "mov", "m4v", "avi", "mkv":
            return "film"
        case "mp3", "wav", "aac", "flac", "m4a":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "js", "ts", "swift", "py", "rb", "go", "rs", "java", "c", "cpp", "h", "sh",
             "json", "yml", "yaml", "html", "css", "md", "php", "sql", "xml":
            return "chevron.left.forwardslash.chevron.right"
        case "txt", "rtf", "doc", "docx":
            return "doc.text"
        default:
            return "doc"
        }
    }

    /// 확장자 기반 시스템 아이콘 (캐시 사용)
    var systemIcon: NSImage {
        IconCache.shared.icon(for: name, isDirectory: isDirectory)
    }

    var iconTint: Color {
        if isDirectory { return Color(red: 0.40, green: 0.73, blue: 0.99) }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "bmp":
            return Color(red: 0.0, green: 0.48, blue: 1.0)
        case "zip", "tar", "gz", "tgz", "bz2", "7z", "rar":
            return Color(red: 0.65, green: 0.45, blue: 0.25)
        case "mp4", "mov", "m4v", "avi", "mkv":
            return Color(red: 0.87, green: 0.20, blue: 0.55)
        case "js", "ts", "swift", "py", "rb", "go", "rs", "json", "html", "css", "md":
            return Color(red: 0.20, green: 0.78, blue: 0.35)
        default:
            return Color.secondary
        }
    }
}

// MARK: - Pane side

enum PaneSide {
    case left, right
    var opposite: PaneSide { self == .left ? .right : .left }
}

// MARK: - Transfer

enum TransferDirection { case upload, download }

/// 전송 로그 항목
struct TransferLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
    let level: TransferLogLevel
}

enum TransferLogLevel {
    case info, ok, error
    var color: Color {
        switch self {
        case .info:  return .secondary
        case .ok:    return .green
        case .error: return .red
        }
    }
}

/// 폴더 전송 시 개별 파일 상태
struct FileTransferEntry: Identifiable {
    let id = UUID()
    let name: String
    var status: FileTransferStatus = .pending
}

enum FileTransferStatus {
    case pending, transferring, done, error
}

enum TransferStatus: String {
    case queued = "대기"
    case active = "전송 중"
    case done = "완료"
    case error = "오류"
    case paused = "일시정지"
}

final class Transfer: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let sourcePath: String
    let destinationPath: String
    let direction: TransferDirection
    let totalBytes: Int64
    let sourceConnection: Connection
    let destConnection: Connection
    let isDirectory: Bool

    @Published var transferredBytes: Int64 = 0
    @Published var status: TransferStatus = .queued
    @Published var speedBps: Int64 = 0
    @Published var etaSeconds: Int = 0
    @Published var errorMessage: String?
    /// 폴더 전송 시 현재 처리 중인 파일명
    @Published var currentFileName: String?
    /// 폴더 전송 시 전체 파일 수
    @Published var totalFileCount: Int = 0
    /// 폴더 전송 시 완료된 파일 수
    @Published var completedFileCount: Int = 0
    /// 폴더 전송 시 파일별 상태 이력
    @Published var fileEntries: [FileTransferEntry] = []

    var progress: Double {
        // 폴더 전송: 바이트 정보가 없으면 파일 개수 기반 진행률 사용
        if isDirectory && totalBytes <= 0 && totalFileCount > 0 {
            return min(1.0, Double(completedFileCount) / Double(totalFileCount))
        }
        guard totalBytes > 0 else { return 0 }
        return min(1.0, Double(transferredBytes) / Double(totalBytes))
    }

    init(name: String, sourcePath: String, destinationPath: String,
         direction: TransferDirection, totalBytes: Int64,
         source: Connection, dest: Connection,
         isDirectory: Bool = false) {
        self.name = name
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.direction = direction
        self.totalBytes = totalBytes
        self.sourceConnection = source
        self.destConnection = dest
        self.isDirectory = isDirectory
    }
}

// MARK: - Permissions (chmod)

struct Permissions {
    var ownerRead: Bool, ownerWrite: Bool, ownerExec: Bool
    var groupRead: Bool, groupWrite: Bool, groupExec: Bool
    var otherRead: Bool, otherWrite: Bool, otherExec: Bool
    var isDirectory: Bool

    init(from permissionString: String, isDirectory: Bool) {
        self.isDirectory = isDirectory
        let s = permissionString.count == 10
            ? String(permissionString.dropFirst())
            : "rw-r--r--"
        let chars = Array(s)
        func has(_ i: Int, _ set: Set<Character>) -> Bool {
            i < chars.count && set.contains(chars[i])
        }
        ownerRead  = has(0, ["r"])
        ownerWrite = has(1, ["w"])
        ownerExec  = has(2, ["x", "s"])         // s = setuid+exec
        groupRead  = has(3, ["r"])
        groupWrite = has(4, ["w"])
        groupExec  = has(5, ["x", "s"])         // s = setgid+exec
        otherRead  = has(6, ["r"])
        otherWrite = has(7, ["w"])
        otherExec  = has(8, ["x", "t"])         // t = sticky+exec
    }

    var octal: String {
        func bits(_ r: Bool, _ w: Bool, _ x: Bool) -> Int {
            (r ? 4 : 0) + (w ? 2 : 0) + (x ? 1 : 0)
        }
        return "\(bits(ownerRead, ownerWrite, ownerExec))" +
               "\(bits(groupRead, groupWrite, groupExec))" +
               "\(bits(otherRead, otherWrite, otherExec))"
    }

    var symbolic: String {
        func tri(_ r: Bool, _ w: Bool, _ x: Bool) -> String {
            (r ? "r" : "-") + (w ? "w" : "-") + (x ? "x" : "-")
        }
        let head = isDirectory ? "d" : "-"
        return head +
               tri(ownerRead, ownerWrite, ownerExec) +
               tri(groupRead, groupWrite, groupExec) +
               tri(otherRead, otherWrite, otherExec)
    }
}

// MARK: - Drag & Drop

/// 드래그 시 전달할 데이터
struct DragItem: Codable {
    let name: String
    let isDirectory: Bool
    let size: Int64
    let sourceSide: String  // "left" or "right"
    let sourcePath: String  // 전체 경로
}

extension UTType {
    static let transmitLiteItem = UTType(exportedAs: "com.transmitlite.dragitem")
}

// MARK: - Tag Store (서버 파일 태그 — UserDefaults 저장)

final class TagStore {
    static let shared = TagStore()
    private let key = "TL.serverFileTags"
    private let dirKey = "TL.serverFileDirs"
    private var store: [String: String] = [:]  // "host:port/path" → colorName
    private var dirStore: Set<String> = []     // 디렉토리인 경로 키 집합

    private init() {
        if let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: String] {
            store = dict
        }
        if let arr = UserDefaults.standard.array(forKey: dirKey) as? [String] {
            dirStore = Set(arr)
        }
    }

    /// 서버+경로로 고유 키 생성
    private func makeKey(connection: Connection, path: String) -> String {
        "\(connection.host):\(connection.port)\(path)"
    }

    func tag(connection: Connection, path: String) -> String? {
        store[makeKey(connection: connection, path: path)]
    }

    func setTag(connection: Connection, path: String, colorName: String?, isDirectory: Bool = false) {
        let k = makeKey(connection: connection, path: path)
        if let colorName = colorName {
            store[k] = colorName
            if isDirectory { dirStore.insert(k) } else { dirStore.remove(k) }
        } else {
            store.removeValue(forKey: k)
            dirStore.remove(k)
        }
        save()
    }

    func isDirectory(connection: Connection, path: String) -> Bool {
        dirStore.contains(makeKey(connection: connection, path: path))
    }

    /// 특정 서버의 특정 태그를 가진 모든 경로 반환
    func paths(connection: Connection, colorName: String) -> [String] {
        let prefix = "\(connection.host):\(connection.port)"
        return store.compactMap { key, value in
            guard value == colorName, key.hasPrefix(prefix) else { return nil }
            return String(key.dropFirst(prefix.count))
        }
    }

    private func save() {
        UserDefaults.standard.set(store, forKey: key)
        UserDefaults.standard.set(Array(dirStore), forKey: dirKey)
    }
}

// MARK: - Icon Cache

final class IconCache {
    static let shared = IconCache()
    private init() {}

    // 확장자별 캐시 (서버 파일용)
    private var extCache: [String: NSImage] = [:]
    private let folderIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .folder)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }()
    private let defaultIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .data)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }()

    // 로컬 파일 경로별 캐시
    private var pathCache: [String: NSImage] = [:]
    private let cacheLimit = 500

    func icon(for name: String, isDirectory: Bool) -> NSImage {
        if isDirectory { return folderIcon }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return defaultIcon }
        if let cached = extCache[ext] { return cached }
        let img: NSImage
        if let utType = UTType(filenameExtension: ext) {
            img = NSWorkspace.shared.icon(for: utType)
        } else {
            img = defaultIcon
        }
        img.size = NSSize(width: 16, height: 16)
        extCache[ext] = img
        return img
    }

    func icon(forPath path: String, isDirectory: Bool) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "app" {
            if let cached = pathCache[path] { return cached }
            let img = NSWorkspace.shared.icon(forFile: path)
            img.size = NSSize(width: 16, height: 16)
            if pathCache.count >= cacheLimit { pathCache.removeAll(keepingCapacity: true) }
            pathCache[path] = img
            return img
        }
        let name = (path as NSString).lastPathComponent
        return icon(for: name, isDirectory: isDirectory)
    }

    func clearPathCache() {
        pathCache.removeAll(keepingCapacity: true)
        thumbnailCache.removeAll(keepingCapacity: true)
    }

    // MARK: - Thumbnail (미리보기 아이콘)

    private var thumbnailCache: [String: NSImage] = [:]
    private var thumbnailRequested: Set<String> = []
    private let thumbnailCacheLimit = 300

    /// 썸네일 지원 확장자
    private static let thumbnailExts: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "ico",
        "pdf", "ai", "psd", "svg"
    ]

    func hasThumbnailSupport(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return Self.thumbnailExts.contains(ext)
    }

    func cachedThumbnail(forPath path: String) -> NSImage? {
        thumbnailCache[path]
    }

    func requestThumbnail(forPath path: String, size: CGFloat, completion: @escaping (NSImage) -> Void) {
        guard !thumbnailRequested.contains(path) else { return }

        let ext = (path as NSString).pathExtension.lowercased()
        if let utType = UTType(filenameExtension: ext),
           utType.conforms(to: .audiovisualContent) || utType.conforms(to: .audio) {
            return
        }

        thumbnailRequested.insert(path)

        let url = URL(fileURLWithPath: path)
        let sz = max(size * 2, 32) // Retina 대응
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: sz, height: sz),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateRepresentations(for: request) { [weak self] thumb, _, error in
            guard let thumb = thumb, error == nil else { return }
            let img = thumb.nsImage
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.thumbnailCache.count >= self.thumbnailCacheLimit {
                    self.thumbnailCache.removeAll(keepingCapacity: true)
                    self.thumbnailRequested.removeAll(keepingCapacity: true)
                }
                self.thumbnailCache[path] = img
                completion(img)
            }
        }
    }
}

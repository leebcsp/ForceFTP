//
//  AppState.swift
//  ForceFinder
//

import SwiftUI
import Combine

// MARK: - Selection State (경량 분리 객체)

@Observable
final class SelectionState {
    var ids: Set<UUID> = []
}

// MARK: - Sidebar tag

struct SidebarTag: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var colorName: String  // "gray","green","purple","blue","yellow","red","orange"

    var color: Color {
        switch colorName {
        case "gray":   return .gray
        case "green":  return .green
        case "purple": return .purple
        case "blue":   return .blue
        case "yellow": return .yellow
        case "red":    return .red
        case "orange": return .orange
        default:       return .gray
        }
    }

    var nsColor: NSColor {
        switch colorName {
        case "gray":   return .systemGray
        case "green":  return .systemGreen
        case "purple": return .systemPurple
        case "blue":   return .systemBlue
        case "yellow": return .systemYellow
        case "red":    return .systemRed
        case "orange": return .systemOrange
        default:       return .systemGray
        }
    }

    static func colorFor(_ name: String) -> Color {
        switch name {
        case "gray":   return .gray
        case "green":  return .green
        case "purple": return .purple
        case "blue":   return .blue
        case "yellow": return .yellow
        case "red":    return .red
        case "orange": return .orange
        default:       return .gray
        }
    }

    static let defaults: [SidebarTag] = [
        SidebarTag(name: "Gray",   colorName: "gray"),
        SidebarTag(name: "Green",  colorName: "green"),
        SidebarTag(name: "Purple", colorName: "purple"),
        SidebarTag(name: "Blue",   colorName: "blue"),
        SidebarTag(name: "Yellow", colorName: "yellow"),
        SidebarTag(name: "Red",    colorName: "red"),
        SidebarTag(name: "Orange", colorName: "orange"),
    ]
}

// MARK: - Sidebar favorite

struct SidebarFavorite: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var icon: String       // SF Symbol name
    var isLocal: Bool = true
    var connection: Connection?  // 서버 즐겨찾기용

    static let defaults: [SidebarFavorite] = [
        SidebarFavorite(name: NSUserName(), path: NSHomeDirectory(), icon: "house"),
        SidebarFavorite(name: "Desktop",
                        path: (NSHomeDirectory() as NSString).appendingPathComponent("Desktop"),
                        icon: "menubar.dock.rectangle"),
        SidebarFavorite(name: "Documents",
                        path: (NSHomeDirectory() as NSString).appendingPathComponent("Documents"),
                        icon: "doc"),
        SidebarFavorite(name: "Downloads",
                        path: (NSHomeDirectory() as NSString).appendingPathComponent("Downloads"),
                        icon: "arrow.down.circle"),
        SidebarFavorite(name: "Applications",
                        path: "/Applications",
                        icon: "square.grid.2x2"),
        SidebarFavorite(name: "Pictures",
                        path: (NSHomeDirectory() as NSString).appendingPathComponent("Pictures"),
                        icon: "photo"),
        SidebarFavorite(name: "iCloud Drive",
                        path: (NSHomeDirectory() as NSString).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs"),
                        icon: "icloud"),
    ]
}

// MARK: - Clipboard

struct Clipboard {
    var items: [RemoteItem] = []
    var sourcePaths: [UUID: String] = [:]   // 아이템ID → 부모 경로
    var sourcePath: String = ""             // 기본 소스 경로 (호환용)
    var sourceConnection: Connection = .localPlaceholder
    var sourceSide: PaneSide = .left

    var isEmpty: Bool { items.isEmpty }

    func parentPath(for item: RemoteItem) -> String {
        sourcePaths[item.id] ?? sourcePath
    }
}

// MARK: - Undo

enum UndoAction {
    /// 붙혀넣기로 생성된 파일 — 되살리기 시 삭제
    case paste(names: [String], path: String, connection: Connection)
    /// 삭제된 파일 경로 기록 (로컬 전용: 휴지통에서 복원)
    /// originalPaths: 원래 파일 경로, trashedURLs: 휴지통 내 경로
    case delete(originalPaths: [String], trashedURLs: [URL])
}

final class AppState: ObservableObject {

    @Published var leftPane:  PaneState
    @Published var rightPane: PaneState

    @Published var activeSide: PaneSide = .left
    @Published var showHiddenFiles: Bool = false
    /// 파인더 아이콘 줌 (1.0 = 기본, 2.0 = 확대)
    @Published var iconZoom: CGFloat = 1.0

    @Published var savedConnections: [Connection] = []
    @Published var recentConnections: [Connection] = []

    @Published var sidebarTags: [SidebarTag] = SidebarTag.defaults
    @Published var sidebarFavorites: [SidebarFavorite] = SidebarFavorite.defaults

    @Published var terminalLines: [TerminalLine] = []
    @Published var logLines: [LogLine] = []

    var clipboard = Clipboard()
    var undoStack: [UndoAction] = []
    /// QuickLook 줌 애니메이션용: 선택된 행의 화면 좌표
    var selectedItemScreenFrame: NSRect = .zero
    /// 줌 애니메이션용: 선택된 아이콘의 SwiftUI global 좌표 (window 기준, top-left origin)
    var selectedItemGlobalFrame: CGRect = .zero

    init() {
        leftPane = PaneState(side: .left,
                             connection: Connection.localPlaceholder)
        rightPane = PaneState(side: .right,
                              connection: Connection.localPlaceholder)

        loadSavedConnections()
        loadRecentConnections()
        loadFavorites()
        restoreLastPaneState()
        appendLog(.info, "ForceFinder 시작됨.")
    }

    func pane(_ side: PaneSide) -> PaneState {
        side == .left ? leftPane : rightPane
    }

    func setPane(_ side: PaneSide, to pane: PaneState) {
        if side == .left { leftPane = pane } else { rightPane = pane }
    }

    func setActive(_ side: PaneSide) {
        guard activeSide != side else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeSide != side else { return }
            self.activeSide = side
        }
    }

    func appendLog(_ level: LogLevel, _ msg: String) {
        let line = LogLine(timestamp: Date(), level: level, text: msg)
        print("[LOG] \(level): \(msg)")
        if Thread.isMainThread {
            self.logLines.append(line)
            if self.logLines.count > 1000 {
                self.logLines.removeFirst(self.logLines.count - 1000)
            }
        } else {
            DispatchQueue.main.async {
                self.logLines.append(line)
                if self.logLines.count > 1000 {
                    self.logLines.removeFirst(self.logLines.count - 1000)
                }
            }
        }
        // 중요 작업 완료/실패 시 앱 내 토스트 알림
        if level == .ok || level == .warn || level == .error {
            let toast = ToastItem(level: level, message: msg)
            if Thread.isMainThread {
                self.toasts.append(toast)
            } else {
                DispatchQueue.main.async { self.toasts.append(toast) }
            }
        }
    }

    // MARK: - Toast
    struct ToastItem: Identifiable {
        let id = UUID()
        let level: LogLevel
        let message: String
        let created = Date()
    }
    @Published var toasts: [ToastItem] = []

    func removeToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    // MARK: - Saved Connections (전체 연결 목록)

    func addSavedConnection(_ c: Connection) {
        if !savedConnections.contains(where: { $0.host == c.host && $0.proto == c.proto && $0.username == c.username }) {
            savedConnections.append(c)
            saveSavedConnections()
        }
    }

    func removeSavedConnection(_ c: Connection) {
        savedConnections.removeAll { $0.id == c.id }
        saveSavedConnections()
    }

    private func saveSavedConnections() {
        if let data = try? JSONEncoder().encode(savedConnections) {
            UserDefaults.standard.set(data, forKey: "savedConnections")
        }
    }

    private func loadSavedConnections() {
        if let data = UserDefaults.standard.data(forKey: "savedConnections"),
           let saved = try? JSONDecoder().decode([Connection].self, from: data) {
            savedConnections = saved
        }
        // 기존 recentConnections에서 마이그레이션
        if savedConnections.isEmpty {
            if let data = UserDefaults.standard.data(forKey: "recentConnections"),
               let recent = try? JSONDecoder().decode([Connection].self, from: data) {
                for c in recent {
                    if !savedConnections.contains(where: { $0.host == c.host && $0.proto == c.proto && $0.username == c.username }) {
                        savedConnections.append(c)
                    }
                }
                saveSavedConnections()
            }
        }
    }

    // MARK: - Recent Connections (최근 접속 기록)

    func addRecentConnection(_ c: Connection) {
        recentConnections.removeAll { $0.host == c.host && $0.proto == c.proto && $0.username == c.username }
        recentConnections.insert(c, at: 0)
        if recentConnections.count > 10 { recentConnections = Array(recentConnections.prefix(10)) }
        saveRecentConnections()
        // 저장 목록에도 추가
        addSavedConnection(c)
    }

    private func saveRecentConnections() {
        if let data = try? JSONEncoder().encode(recentConnections) {
            UserDefaults.standard.set(data, forKey: "recentConnections")
        }
    }

    private func loadRecentConnections() {
        if let data = UserDefaults.standard.data(forKey: "recentConnections"),
           let saved = try? JSONDecoder().decode([Connection].self, from: data) {
            recentConnections = saved
        }
    }

    func saveFavorites() {
        if let data = try? JSONEncoder().encode(sidebarFavorites) {
            UserDefaults.standard.set(data, forKey: "sidebarFavorites")
        }
    }

    private func loadFavorites() {
        if let data = UserDefaults.standard.data(forKey: "sidebarFavorites"),
           let saved = try? JSONDecoder().decode([SidebarFavorite].self, from: data) {
            sidebarFavorites = saved
        }
    }

    // MARK: - 마지막 패인 상태 저장/복원

    private struct PaneSnapshot: Codable {
        let connection: Connection
        let path: String
    }

    func saveLastPaneState() {
        let ud = UserDefaults.standard
        if let left = try? JSONEncoder().encode(PaneSnapshot(connection: leftPane.connection, path: leftPane.currentPath)) {
            ud.set(left, forKey: "lastPaneState.left")
        }
        if let right = try? JSONEncoder().encode(PaneSnapshot(connection: rightPane.connection, path: rightPane.currentPath)) {
            ud.set(right, forKey: "lastPaneState.right")
        }
    }

    func restoreLastPaneState() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: "lastPaneState.left"),
           let snap = try? JSONDecoder().decode(PaneSnapshot.self, from: data) {
            leftPane = PaneState(side: .left, connection: snap.connection)
            leftPane.currentPath = snap.path
            leftPane.pathHistory = [snap.path]
            leftPane.isConnected = snap.connection.proto == .local
        }
        if let data = ud.data(forKey: "lastPaneState.right"),
           let snap = try? JSONDecoder().decode(PaneSnapshot.self, from: data) {
            rightPane = PaneState(side: .right, connection: snap.connection)
            rightPane.currentPath = snap.path
            rightPane.pathHistory = [snap.path]
            rightPane.isConnected = snap.connection.proto == .local
        }
    }
}

// MARK: - PaneState

final class PaneState: ObservableObject, Identifiable {
    let id = UUID()
    let side: PaneSide

    @Published var connection: Connection
    @Published var currentPath: String
    @Published var items: [RemoteItem] = []
    /// 선택 상태 (별도 객체로 분리 — 선택 변경 시 PaneState 전체 재평가 방지)
    let selectionState = SelectionState()
    var selection: Set<UUID> {
        get { selectionState.ids }
        set { selectionState.ids = newValue }
    }
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isConnected: Bool = false

    /// 태그 변경 시 트리 캐시 무효화용
    @Published var tagVersion: Int = 0

    /// 펼쳐진 폴더 ID
    @Published var expandedFolders: Set<UUID> = []
    /// 펼쳐진 폴더의 자식 아이템 캐시 (폴더ID → 자식 목록)
    @Published var childrenCache: [UUID: [RemoteItem]] = [:]
    /// 현재 로딩 중인 폴더 ID
    @Published var loadingFolders: Set<UUID> = []

    // Navigation history
    @Published var pathHistory: [String] = []
    @Published var historyIndex: Int = 0

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < pathHistory.count - 1 }

    enum SortKey { case name, ext, size, date, perm }
    @Published var sortKey: SortKey = .name
    @Published var sortAscending: Bool = true

    /// 태그 필터: nil이면 전체, 값이 있으면 해당 태그만 표시
    @Published var tagFilter: String? = nil

    /// 마키 선택 중 여부 (인스펙터 업데이트 지연용)
    @Published var isMarqueeSelecting: Bool = false
    /// FileWatcher reload 억제 (삭제/이동/복사 후 중복 리로드 방지)
    var suppressWatcherUntil: Date = .distantPast

    /// 컬럼 너비 (디바이더로 조절)
    @Published var nameColumnWidth: CGFloat = 200
    @Published var extColumnWidth: CGFloat = 50
    @Published var sizeColumnWidth: CGFloat = 70

    /// 변환 진행 중인 파일 (파일명 → 진행률 0.0~1.0)
    @Published var conversionProgress: [String: Double] = [:]
    /// 변환 취소용 프로세스 참조
    var conversionProcesses: [String: Process] = [:]
    /// 변환 출력 파일 경로 (취소 시 삭제용)
    var conversionOutputPaths: [String: String] = [:]

    func cancelConversion(fileName: String) {
        let outputPath = conversionOutputPaths[fileName]
        if let proc = conversionProcesses[fileName], proc.isRunning {
            proc.terminate()
            DispatchQueue.global(qos: .utility).async {
                proc.waitUntilExit()
                if let path = outputPath {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
        } else if let path = outputPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        conversionProcesses.removeValue(forKey: fileName)
        conversionProgress.removeValue(forKey: fileName)
        conversionOutputPaths.removeValue(forKey: fileName)
    }

    init(side: PaneSide, connection: Connection) {
        self.side = side
        self.connection = connection
        self.currentPath = connection.remotePath
        self.isConnected = connection.proto == .local
        self.pathHistory = [connection.remotePath]
        self.historyIndex = 0
    }

    var sortedItems: [RemoteItem] {
        items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let result: Bool
            switch sortKey {
            case .name: result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .ext:
                let extA = (a.name as NSString).pathExtension.lowercased()
                let extB = (b.name as NSString).pathExtension.lowercased()
                result = extA == extB
                    ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                    : extA < extB
            case .size: result = a.size < b.size
            case .date: result = a.modified < b.modified
            case .perm: result = a.permissions < b.permissions
            }
            return sortAscending ? result : !result
        }
    }

    var selectedItems: [RemoteItem] {
        guard !selection.isEmpty else { return [] }
        // 단일 선택 시 빠른 경로
        if selection.count == 1, let id = selection.first {
            if let item = items.first(where: { $0.id == id }) { return [item] }
            for (_, children) in childrenCache {
                if let item = children.first(where: { $0.id == id }) { return [item] }
            }
            return []
        }
        return allItems.filter { selection.contains($0.id) }
    }

    var firstSelectedItem: RemoteItem? {
        guard let id = selection.first else { return nil }
        if let item = items.first(where: { $0.id == id }) { return item }
        for (_, children) in childrenCache {
            if let item = children.first(where: { $0.id == id }) { return item }
        }
        return nil
    }

    /// 최상위 + 펼쳐진 하위 아이템 모두 포함
    var allItems: [RemoteItem] {
        var result = items
        for (_, children) in childrenCache {
            result.append(contentsOf: children)
        }
        return result
    }

    /// 화면 표시 순서대로 정렬된 아이템 (펼쳐진 하위 폴더 포함)
    func flattenedDisplayItems(showHidden: Bool) -> [RemoteItem] {
        var result: [RemoteItem] = []
        func append(items: [RemoteItem], parentPath: String) {
            let filtered = showHidden ? items : items.filter { !$0.name.hasPrefix(".") }
            let sorted = filtered.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                let cmp: Bool
                switch sortKey {
                case .name: cmp = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                case .ext:
                    let extA = (a.name as NSString).pathExtension.lowercased()
                    let extB = (b.name as NSString).pathExtension.lowercased()
                    cmp = extA == extB
                        ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                        : extA < extB
                case .size: cmp = a.size < b.size
                case .date: cmp = a.modified < b.modified
                case .perm: cmp = a.permissions < b.permissions
                }
                return sortAscending ? cmp : !cmp
            }
            for item in sorted {
                result.append(item)
                if item.isDirectory && expandedFolders.contains(item.id),
                   let children = childrenCache[item.id] {
                    let childPath = (parentPath as NSString).appendingPathComponent(item.name)
                    append(items: children, parentPath: childPath)
                }
            }
        }
        append(items: items, parentPath: currentPath)
        return result
    }

    /// 아이템의 실제 부모 경로 반환 (하위 폴더 포함)
    func parentPath(for itemID: UUID) -> String {
        // 최상위 아이템인지 확인
        if items.contains(where: { $0.id == itemID }) {
            return currentPath
        }
        // childrenCache에서 찾기
        for (folderID, children) in childrenCache {
            if children.contains(where: { $0.id == itemID }) {
                // 이 폴더의 경로를 찾아야 함
                return fullPath(of: folderID)
            }
        }
        return currentPath
    }

    /// 폴더 ID로 전체 경로 재귀 탐색
    func fullPathForFolder(_ folderID: UUID) -> String {
        return fullPath(of: folderID)
    }

    private func fullPath(of folderID: UUID) -> String {
        // 최상위에 있는 폴더인지
        if let folder = items.first(where: { $0.id == folderID }) {
            return (currentPath as NSString).appendingPathComponent(folder.name)
        }
        // 하위 캐시에서 찾기
        for (parentID, children) in childrenCache {
            if let folder = children.first(where: { $0.id == folderID }) {
                let parentFullPath = fullPath(of: parentID)
                return (parentFullPath as NSString).appendingPathComponent(folder.name)
            }
        }
        return currentPath
    }

    func navigate(into folderName: String) {
        let newPath = (currentPath as NSString).appendingPathComponent(folderName)
        pushPath(newPath)
    }

    func navigateUp() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        pushPath(parent.isEmpty ? "/" : parent)
    }

    func navigate(to path: String) {
        pushPath(path)
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        currentPath = pathHistory[historyIndex]
        selection.removeAll()
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        currentPath = pathHistory[historyIndex]
        selection.removeAll()
    }

    func collapseAll() {
        expandedFolders.removeAll()
        childrenCache.removeAll()
    }

    private func pushPath(_ path: String) {
        collapseAll()
        // Truncate forward history
        if historyIndex < pathHistory.count - 1 {
            pathHistory = Array(pathHistory.prefix(historyIndex + 1))
        }
        pathHistory.append(path)
        historyIndex = pathHistory.count - 1
        currentPath = path
        selection.removeAll()
    }

    var pathComponents: [(name: String, path: String)] {
        var comps: [(String, String)] = []
        let parts = currentPath.split(separator: "/").map(String.init)
        var acc = ""
        let rootName = connection.proto == .local ? "/" : connection.name
        comps.append((rootName, "/"))
        for p in parts {
            acc += "/" + p
            comps.append((p, acc))
        }
        return comps
    }
}

// MARK: - Terminal / Log

enum LogLevel: String {
    case info, ok, warn, error, dim
    var color: Color {
        switch self {
        case .info:  return Color(red: 0.61, green: 0.81, blue: 1.00)
        case .ok:    return Color(red: 0.44, green: 0.87, blue: 0.55)
        case .warn:  return Color(red: 1.00, green: 0.85, blue: 0.44)
        case .error: return Color(red: 1.00, green: 0.54, blue: 0.52)
        case .dim:   return Color.gray
        }
    }
}

struct LogLine: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let text: String
}

enum TerminalLineKind {
    case prompt(user: String, host: String, path: String, command: String)
    case output(text: String, color: Color?)
}

struct TerminalLine: Identifiable {
    let id = UUID()
    let kind: TerminalLineKind
}

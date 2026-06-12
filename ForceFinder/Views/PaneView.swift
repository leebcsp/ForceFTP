//
//  PaneView.swift
//  ForceFinder
//

import SwiftUI
import UniformTypeIdentifiers
import Quartz

struct PaneView: View {
    static func loc(_ en: String, ko: String) -> String {
        Locale.current.language.languageCode?.identifier == "ko" ? ko : en
    }

    let side: PaneSide
    let onConnect: () -> Void
    let onInfo: (RemoteItem) -> Void

    @EnvironmentObject var app: AppState
    @AppStorage private var showTerminal: Bool
    @AppStorage private var terminalHeight: Double
    @AppStorage private var nameWidth: Double
    @AppStorage private var extWidth: Double
    @AppStorage private var sizeWidth: Double
    @AppStorage private var dateWidth: Double
    @State private var fileWatcher: DispatchSourceFileSystemObject?
    @State private var watchFD: Int32 = -1

    init(side: PaneSide, onConnect: @escaping () -> Void, onInfo: @escaping (RemoteItem) -> Void) {
        self.side = side
        self.onConnect = onConnect
        self.onInfo = onInfo
        let prefix = side == .left ? "left" : "right"
        _showTerminal = AppStorage(wrappedValue: true, "layout.\(prefix).showTerminal")
        _terminalHeight = AppStorage(wrappedValue: 140, "layout.\(prefix).terminalHeight")
        _nameWidth = AppStorage(wrappedValue: 300, "col.\(prefix).nameWidth")
        _extWidth = AppStorage(wrappedValue: 50, "col.\(prefix).extWidth")
        _sizeWidth = AppStorage(wrappedValue: 80, "col.\(prefix).sizeWidth")
        _dateWidth = AppStorage(wrappedValue: 140, "col.\(prefix).dateWidth")
    }

    var pane: PaneState { app.pane(side) }
    var isActive: Bool  { app.activeSide == side }
    private var nameColW: CGFloat { CGFloat(nameWidth) }
    private var extColW: CGFloat { CGFloat(extWidth) + 8 }
    private var sizeColW: CGFloat { CGFloat(sizeWidth) + 12 }
    private var dateColW: CGFloat { CGFloat(dateWidth) + 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            paneHeader
                .contentShape(Rectangle())
                .onTapGesture { app.setActive(side) }

            // Path bar
            pathBar
                .contentShape(Rectangle())
                .onTapGesture { app.setActive(side) }
            Divider()

            // File list
            columnHeaders
            Divider()
            listSection
                .contentShape(Rectangle())
                .onTapGesture { app.setActive(side) }
            paneStatus

            // Terminal
            if showTerminal {
                TerminalResizeHandle(height: $terminalHeight.cgFloat, minH: 60, maxH: 400)
                    .frame(height: 8)
                PaneTerminal(side: side)
                    .frame(height: terminalHeight)
            }
        }
        .background(Color.panelList)
        .cornerRadius(8)
        .onAppear {
            startFileWatcher()
        }
        .onDisappear {
            stopFileWatcher()
        }
        .onChange(of: pane.currentPath) { _, _ in
            restartFileWatcher()
        }
        .background {
            DeleteKeyHandler {
                deleteSelected()
            }
        }
    }

    private func deleteSelected() {
        let toDelete = pane.selectedItems
        guard !toDelete.isEmpty else { return }
        // Confirm before delete
        let names = toDelete.map(\.name).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "삭제 확인"
        alert.informativeText = "\(toDelete.count)개 항목을 삭제하시겠습니까?\n\(names)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if pane.connection.proto == .local { pane.suppressWatcherUntil = Date().addingTimeInterval(2) }
        Task {
            var trashedURLs: [URL] = []
            var deletedIDs: Set<UUID> = []
            for item in toDelete {
                let parentDir = pane.parentPath(for: item.id)
                let p = (parentDir as NSString).appendingPathComponent(item.name)
                do {
                    // 로컬이면 휴지통으로 이동 (Cmd+Z 복원 가능)
                    if pane.connection.proto == .local {
                        var resultURL: NSURL?
                        try FileManager.default.trashItem(
                            at: URL(fileURLWithPath: p), resultingItemURL: &resultURL)
                        if let url = resultURL as URL? {
                            trashedURLs.append(url)
                        }
                    } else {
                        try await FileService.shared.remove(connection: pane.connection,
                                                            path: p, isDirectory: item.isDirectory)
                    }
                    let lp = pane.connection.proto == .local ? p : "\(pane.connection.host):\(p)"
                    TransferManager.shared.appendLog(.ok, "삭제 완료: \(lp)")
                    deletedIDs.insert(item.id)
                } catch {
                    let lp = pane.connection.proto == .local ? p : "\(pane.connection.host):\(p)"
                    TransferManager.shared.appendLog(.error, "삭제 실패: \(lp)")
                }
            }
            if !trashedURLs.isEmpty {
                let paths = toDelete.map { item in
                    let parentDir = pane.parentPath(for: item.id)
                    return (parentDir as NSString).appendingPathComponent(item.name)
                }
                app.undoStack.append(.delete(originalPaths: paths, trashedURLs: trashedURLs))
            }
            await MainActor.run {
                pane.selection.subtract(deletedIDs)
                pane.items.removeAll { deletedIDs.contains($0.id) }
                for (folderID, children) in pane.childrenCache {
                    let filtered = children.filter { !deletedIDs.contains($0.id) }
                    if filtered.count != children.count {
                        pane.childrenCache[folderID] = filtered
                    }
                }
                for id in deletedIDs {
                    pane.expandedFolders.remove(id)
                    pane.childrenCache.removeValue(forKey: id)
                }
            }
        }
    }

    private func refreshExpandedFolders() async {
        for folderID in pane.expandedFolders {
            let folderPath = pane.fullPathForFolder(folderID)
            do {
                let children = try await FileService.shared.list(
                    connection: pane.connection, path: folderPath)
                await MainActor.run { pane.childrenCache[folderID] = children }
            } catch {
                await MainActor.run {
                    _ = pane.expandedFolders.remove(folderID)
                    pane.childrenCache.removeValue(forKey: folderID)
                }
            }
        }
    }

    // MARK: - Header

    private var paneHeader: some View {
        HStack(spacing: 6) {
            // Back / Forward
            Button { goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(!pane.canGoBack)
            .foregroundStyle(isActive ? Color.activeHeaderFg : .primary)

            Button { goForward() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(!pane.canGoForward)
            .foregroundStyle(isActive ? Color.activeHeaderFg : .primary)

            Divider().frame(height: 14)

            // Connection icon + label
            Image(systemName: pane.connection.proto == .local ? "laptopcomputer" : "globe")
                .font(.system(size: 11))
                .foregroundStyle(isActive ? Color.activeHeaderFg : (pane.connection.proto == .local ? .secondary : pane.connection.proto.badgeColor))

            Text(pane.connection.proto == .local ? NSUserName() : pane.connection.host)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Color.activeHeaderFg : .primary)
                .lineLimit(1)

            if pane.connection.proto != .local {
                Text(pane.connection.proto.displayName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isActive ? Color.activeHeaderFg : .white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(isActive ? Color.activeHeaderBadge : pane.connection.proto.badgeColor)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            Spacer()

            Text(statusInfo)
                .font(.system(size: 10.5))
                .foregroundStyle(isActive ? Color.activeHeaderDim : Color.secondary.opacity(0.5))

            Divider().frame(height: 14)

            // Terminal toggle
            Button {
                withAnimation(.easeInOut(duration: 0.35)) {
                    showTerminal.toggle()
                }
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(isActive
                        ? Color.activeHeaderFg
                        : Color.secondary.opacity(showTerminal ? 1.0 : 0.4))
            }
            .buttonStyle(.borderless)
            .help("터미널 표시/숨김")

            Button(action: { Task { await reload() } }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isActive ? Color.activeHeaderFg : .primary)
            .help("새로고침")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(isActive ? Color.accentTint : Color.panelHeader)
    }

    private var statusInfo: String {
        let count = app.showHiddenFiles ? pane.items.count : pane.items.filter { !$0.name.hasPrefix(".") }.count
        if pane.connection.proto == .local,
           let attrs = try? FileManager.default.attributesOfFileSystem(forPath: pane.currentPath),
           let free = attrs[.systemFreeSize] as? Int64 {
            let gb = Double(free) / 1_073_741_824.0
            return "\(count) items, \(String(format: "%.1f", gb)) GB free"
        }
        return "\(count) items"
    }

    // MARK: - Path bar

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if let tagName = pane.tagFilter {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(SidebarTag.colorFor(tagName))
                            .frame(width: 8, height: 8)
                        Text("\(tagName.prefix(1).uppercased() + tagName.dropFirst()) 태그")
                            .font(.system(size: 11, weight: .medium))
                        Button {
                            pane.tagFilter = nil
                            Task { await reload() }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(red: 0.78, green: 0.28, blue: 0.51).opacity(0.12))
                    .cornerRadius(4)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.quaternary)
                }
                ForEach(Array(pane.pathComponents.enumerated()), id: \.offset) { _, comp in
                    Button {
                        pane.navigate(to: comp.path)
                        Task { await reload() }
                    } label: {
                        HStack(spacing: 2) {
                            if comp.path == "/" {
                                Image(systemName: pane.connection.proto == .local ? "desktopcomputer" : "globe")
                                    .font(.system(size: 9))
                            }
                            Text(comp.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            comp.path == pane.currentPath
                                ? Color(red: 0.78, green: 0.28, blue: 0.51).opacity(0.15)
                                : Color.clear
                        )
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(comp.path == pane.currentPath ? Color(red: 0.78, green: 0.28, blue: 0.51) : .secondary)

                    if comp.path != pane.currentPath {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.quaternary)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 24)
        .background(Color.panelCard)
    }

    // MARK: - Column Headers

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            sortLabel(title: Self.loc("Name", ko: "이름"), key: .name)
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            columnSep()
            sortLabel(title: Self.loc("Kind", ko: "종류"), key: .ext)
                .frame(width: extColW)
            ColumnDivider(width: $extWidth, minW: 30)
            sortLabel(title: Self.loc("Size", ko: "크기"), key: .size)
                .frame(width: sizeColW)
            ColumnDivider(width: $sizeWidth, minW: 40)
            sortLabel(title: Self.loc("Date Modified", ko: "수정일"), key: .date)
                .frame(width: dateColW)
        }
        .frame(height: 22)
        .padding(.horizontal, 3)
        .clipped()
        .background(Color.panelHeader)
    }

    @ViewBuilder
    private func columnSep() -> some View {
        Color(white: 0.3)
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
            .frame(width: 5, height: 22)
    }

    @ViewBuilder
    private func sortLabel(title: String, key: PaneState.SortKey) -> some View {
        Button {
            app.setActive(side)
            if pane.sortKey == key { pane.sortAscending.toggle() }
            else { pane.sortKey = key; pane.sortAscending = true }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 11))
                if pane.sortKey == key {
                    Image(systemName: pane.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 6, weight: .bold))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .foregroundStyle(.secondary)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - List section

    @ViewBuilder private var listSection: some View {
        if let err = pane.errorMessage, pane.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
                Text(err).font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                Button("다시 시도") { Task { await reload() } }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pane.isLoading && pane.items.isEmpty {
            VStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("불러오는 중...")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FinderList(side: side, isActive: isActive, onInfo: onInfo)
        }
    }

    // MARK: - Status bar

    private var paneStatus: some View {
        HStack {
            if pane.selection.count > 0 {
                Text("\(pane.selection.count) selected")
            }
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(Color.panelHeader)
    }

    // MARK: - File Watcher (로컬 실시간 동기화)

    private func startFileWatcher() {
        guard pane.connection.proto == .local else { return }
        stopFileWatcher()
        let path = pane.currentPath
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .link, .attrib],
            queue: .main
        )
        source.setEventHandler { [self] in
            if Date() < pane.suppressWatcherUntil { return }
            Task { await reload() }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileWatcher = source
    }

    private func stopFileWatcher() {
        fileWatcher?.cancel()
        fileWatcher = nil
        if watchFD >= 0 {
            watchFD = -1
        }
    }

    private func restartFileWatcher() {
        stopFileWatcher()
        Task {
            await reload()
            startFileWatcher()
        }
    }

    // MARK: - Actions

    private func goBack() {
        pane.goBack()
        Task { await reload() }
    }

    private func goForward() {
        pane.goForward()
        Task { await reload() }
    }

    func reload() async {
        await MainActor.run { pane.isLoading = true; pane.errorMessage = nil }
        do {
            let items = try await FileService.shared.list(connection: pane.connection,
                                                          path: pane.currentPath)
            await MainActor.run {
                pane.items = items; pane.isLoading = false; pane.isConnected = true
            }
        } catch {
            await MainActor.run {
                pane.isLoading = false
                pane.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Finder List

struct FinderList: View {
    let side: PaneSide
    let isActive: Bool
    let onInfo: (RemoteItem) -> Void

    @EnvironmentObject var app: AppState
    @State private var renamingItemId: UUID?
    @State private var pendingRenameName: String?
    @State private var marqueeRect: CGRect = .zero
    @State private var cachedTreeIds: [UUID] = []        // 마키 선택 중 캐시
    @State private var lastMarqueeSelection: Set<UUID> = []  // 변경 감지용
    @State private var lastSelectionUpdate: Date = .distantPast  // 쓰로틀용
    @State private var pendingMarqueeRect: CGRect? = nil
    @State private var dropTargetItemId: UUID?
    @State private var contextMenuItemId: UUID?
    @State private var pendingScrollToName: String?   // 변환 완료 후 자동스크롤 대상
    @AppStorage("listZoomLevel") private var zoomLevel: Int = 1  // 1=normal, 2=large
    // flattenedTree 캐시 (선택 변경 시 재계산 방지)
    @State private var _cachedFlatTree: [(depth: Int, item: RemoteItem, parentPath: String)] = []
    @State private var _treeInputHash: Int = 0
    @AppStorage private var nameWidth: Double
    @AppStorage private var extWidth: Double
    @AppStorage private var sizeWidth: Double
    @AppStorage private var dateWidth: Double

    init(side: PaneSide, isActive: Bool, onInfo: @escaping (RemoteItem) -> Void) {
        self.side = side
        self.isActive = isActive
        self.onInfo = onInfo
        let prefix = side == .left ? "left" : "right"
        _nameWidth = AppStorage(wrappedValue: 300, "col.\(prefix).nameWidth")
        _extWidth = AppStorage(wrappedValue: 50, "col.\(prefix).extWidth")
        _sizeWidth = AppStorage(wrappedValue: 80, "col.\(prefix).sizeWidth")
        _dateWidth = AppStorage(wrappedValue: 140, "col.\(prefix).dateWidth")
    }

    var pane: PaneState { app.pane(side) }

    private var zoomScale: CGFloat { CGFloat(max(1, zoomLevel)) }
    private var rowHeight: CGFloat { 22 * zoomScale }
    private var iconSize: CGFloat { 16 * zoomScale }

    private var filteredItems: [RemoteItem] {
        if app.showHiddenFiles {
            return pane.sortedItems
        }
        return pane.sortedItems.filter { !$0.name.hasPrefix(".") }
    }

    /// 플랫 리스트를 트리 구조로 펼침 (depth, item, parentPath)
    private var flattenedTree: [(depth: Int, item: RemoteItem, parentPath: String)] {
        var result: [(Int, RemoteItem, String)] = []

        // 태그 필터 모드: fullPath 기준 parentPath 사용
        if pane.tagFilter != nil {
            let filtered = app.showHiddenFiles ? pane.items : pane.items.filter { !$0.name.hasPrefix(".") }
            for item in filtered {
                let parent = item.fullPath.map { ($0 as NSString).deletingLastPathComponent } ?? pane.currentPath
                result.append((0, item, parent))
            }
            return result
        }

        func append(items: [RemoteItem], depth: Int, parentPath: String) {
            let filtered = app.showHiddenFiles ? items : items.filter { !$0.name.hasPrefix(".") }
            let asc = pane.sortAscending
            let sorted = filtered.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                switch pane.sortKey {
                case .name:
                    let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
                    return asc ? cmp == .orderedAscending : cmp == .orderedDescending
                case .ext:
                    let extA = (a.name as NSString).pathExtension.lowercased()
                    let extB = (b.name as NSString).pathExtension.lowercased()
                    if extA == extB {
                        let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
                        return asc ? cmp == .orderedAscending : cmp == .orderedDescending
                    }
                    return asc ? extA < extB : extA > extB
                case .size:
                    return asc ? a.size < b.size : a.size > b.size
                case .date:
                    return asc ? a.modified < b.modified : a.modified > b.modified
                case .perm:
                    let cmp = a.permissions.compare(b.permissions)
                    return asc ? cmp == .orderedAscending : cmp == .orderedDescending
                }
            }
            for item in sorted {
                result.append((depth, item, parentPath))
                if item.isDirectory && pane.expandedFolders.contains(item.id),
                   let children = pane.childrenCache[item.id] {
                    let childPath = (parentPath as NSString).appendingPathComponent(item.name)
                    append(items: children, depth: depth + 1, parentPath: childPath)
                }
            }
        }
        append(items: pane.items, depth: 0, parentPath: pane.currentPath)
        return result
    }

    /// 트리 입력값 해시 (선택 변경 시 재정렬 방지) - O(1) 경량 해시
    private var treeInputHash: Int {
        var h = Hasher()
        h.combine(pane.items.count)
        if let first = pane.items.first { h.combine(first.id); h.combine(first.name); h.combine(first.size) }
        if let last = pane.items.last { h.combine(last.id); h.combine(last.name); h.combine(last.size) }
        h.combine(pane.expandedFolders)
        h.combine(pane.childrenCache.count)
        for (k, v) in pane.childrenCache { h.combine(k); h.combine(v.count) }
        h.combine(pane.sortKey)
        h.combine(pane.sortAscending)
        h.combine(app.showHiddenFiles)
        h.combine(pane.tagFilter)
        h.combine(pane.tagVersion)
        return h.finalize()
    }

    var body: some View {
        let hash = treeInputHash
        let tree: [(depth: Int, item: RemoteItem, parentPath: String)] =
            (hash == _treeInputHash && !_cachedFlatTree.isEmpty) ? _cachedFlatTree : flattenedTree
        let isLocalConn = pane.connection.proto == .local
        let selSet = pane.selectionState.ids
        GeometryReader { geo in
            ScrollViewReader { scrollProxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(tree.enumerated()), id: \.element.item.id) { idx, entry in
                            let isSel = selSet.contains(entry.item.id)
                            let prevSel = idx > 0 && selSet.contains(tree[idx - 1].item.id)
                            let nextSel = idx < tree.count - 1 && selSet.contains(tree[idx + 1].item.id)
                            let groupPos: FileRow.GroupPosition = !isSel ? .none :
                                (!prevSel && !nextSel) ? .single :
                                (!prevSel && nextSel) ? .first :
                                (prevSel && !nextSel) ? .last : .middle
                            fileRow(idx: idx, entry: entry, isLocalConn: isLocalConn, groupPosition: groupPos)
                                .id(entry.item.id)
                        }
                        // 하단 빈 공간
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: max(200, geo.size.height - CGFloat(tree.count) * rowHeight))
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button("새 폴더") { createNewFolder() }
                                    .keyboardShortcut("n", modifiers: [.command, .shift])
                                Divider()
                                Button("붙여넣기") {
                                    NotificationCenter.default.post(name: .filePaste, object: nil)
                                }
                                .keyboardShortcut("v", modifiers: .command)
                                .disabled(app.clipboard.isEmpty)
                            }
                    }

                    // 마키 선택 사각형은 ListNSView에서 직접 그림 (성능 최적화)
                }
                .overlay {
                    ListInteractionOverlay(
                        rowHeight: rowHeight,
                        itemCount: tree.count,
                        isRenaming: renamingItemId != nil,
                        nameEndX: { row in
                            guard row >= 0, row < tree.count else { return 0 }
                            let entry = tree[row]
                            let z = self.zoomScale
                            let indent = CGFloat(entry.depth) * 16
                            let nameFont = NSFont.systemFont(ofSize: 12)
                            let textW = (entry.item.name as NSString)
                                .size(withAttributes: [.font: nameFont]).width
                            return 6 + indent + 14 + 2 + 16 * z + 5 + textW + 8
                        },
                        onClick: { row, point, mods in
                            handleListClick(row: row, point: point, mods: mods, tree: tree)
                        },
                        onDoubleClick: { row in
                            guard row >= 0, row < tree.count else { return }
                            let entry = tree[row]
                            handleDouble(item: entry.item, parentPath: entry.parentPath)
                        },
                        onEmptyClick: {
                            app.setActive(side)
                            pane.selection.removeAll()
                            renamingItemId = nil
                        },
                        onMarqueeUpdate: { rect in
                            if !pane.isMarqueeSelecting {
                                pane.isMarqueeSelecting = true
                            }
                            let now = Date()
                            let elapsed = now.timeIntervalSince(lastSelectionUpdate)
                            if elapsed >= 0.05 {
                                // 50ms 간격으로 SwiftUI 선택 업데이트
                                selectItemsInMarquee(rect)
                                lastSelectionUpdate = now
                                pendingMarqueeRect = nil
                            } else {
                                pendingMarqueeRect = rect
                            }
                        },
                        onMarqueeEnd: {
                            // 마지막 pending이 있으면 반영
                            if let pending = pendingMarqueeRect {
                                selectItemsInMarquee(pending)
                            }
                            pane.isMarqueeSelecting = false
                            cachedTreeIds = []
                            lastMarqueeSelection = []
                            pendingMarqueeRect = nil
                        },
                        makeDragData: { row in
                            guard row >= 0, row < tree.count else { return nil }
                            let sideStr = side == .left ? "left" : "right"
                            // 선택된 모든 행 수집
                            let selRows: [Int] = tree.enumerated().compactMap { (idx: Int, e) -> Int? in
                                pane.selection.contains(e.item.id) ? idx : nil
                            }
                            let rows: [Int] = selRows.isEmpty ? [row] : (selRows.contains(row) ? selRows : [row])
                            let items: [DragItem] = rows.compactMap { (r: Int) -> DragItem? in
                                guard r >= 0, r < tree.count else { return nil }
                                let e = tree[r]
                                let fp = (e.parentPath as NSString).appendingPathComponent(e.item.name)
                                return DragItem(name: e.item.name, isDirectory: e.item.isDirectory,
                                                size: e.item.size, sourceSide: sideStr, sourcePath: fp)
                            }
                            return try? JSONEncoder().encode(items)
                        },
                        dragUTI: UTType.transmitLiteItem.identifier,
                        selectedRows: {
                            return tree.enumerated().compactMap { idx, entry in
                                pane.selection.contains(entry.item.id) ? idx : nil
                            }
                        },
                        isRowSelected: { row in
                            guard row >= 0, row < tree.count else { return false }
                            return pane.selection.contains(tree[row].item.id)
                        },
                        rowInfo: { row in
                            guard row >= 0, row < tree.count else { return nil }
                            let entry = tree[row]
                            let fullPath = (entry.parentPath as NSString).appendingPathComponent(entry.item.name)
                            let isLocal = pane.connection.proto == .local
                            return (name: entry.item.name, path: fullPath,
                                    isDirectory: entry.item.isDirectory, isLocal: isLocal,
                                    depth: entry.depth)
                        },
                        onKeyArrow: { keyCode in
                            handleArrowKey(keyCode, tree: tree)
                        },
                        onSelectAll: {
                            pane.selection = Set(tree.map(\.item.id))
                        },
                        isRowConverting: { row in
                            guard row >= 0, row < tree.count else { return false }
                            return pane.conversionProgress[tree[row].item.name] != nil
                        },
                        onCancelConversion: { row in
                            guard row >= 0, row < tree.count else { return }
                            let name = tree[row].item.name
                            pane.cancelConversion(fileName: name)
                            Task { await self.reload() }
                        },
                        onRightClick: { row in
                            guard row >= 0, row < tree.count else { return }
                            app.setActive(side)
                            contextMenuItemId = tree[row].item.id
                        }
                    )
                }
            }
            .background(Color.panelList)
            .onPreferenceChange(SelectedIconFrameKey.self) { frame in
                guard frame != .zero, let window = NSApp.keyWindow else { return }
                app.selectedItemGlobalFrame = frame
                // SwiftUI .global: origin top-left; NSWindow: origin bottom-left
                let contentH = window.contentView?.frame.height ?? window.frame.height
                let flipped = NSRect(x: frame.origin.x,
                                     y: contentH - frame.origin.y - frame.height,
                                     width: frame.width, height: frame.height)
                app.selectedItemScreenFrame = window.convertToScreen(flipped)
            }
            .onChange(of: pendingScrollToName) { _, _ in scrollToConversionResult(tree: tree, proxy: scrollProxy) }
            .onChange(of: pane.items.count) { _, _ in scrollToConversionResult(tree: tree, proxy: scrollProxy) }
            } // ScrollViewReader
        }
        .onDrop(of: [UTType.transmitLiteItem, .fileURL], isTargeted: nil) { providers in
            // 내부 드래그 확인 (배경 영역 드롭: 현재 경로)
            let hasInternal = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.transmitLiteItem.identifier) }
            if hasInternal {
                handleDrop(providers, destPath: pane.currentPath)
            } else {
                handleExternalDrop(providers, destPath: pane.currentPath)
            }
            dropTargetItemId = nil
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: .fileRename)) { _ in
            guard isActive, pane.selection.count == 1,
                  let id = pane.selection.first else { return }
            renamingItemId = id
        }
        .onReceive(NotificationCenter.default.publisher(for: .newFolder)) { _ in
            guard isActive else { return }
            createNewFolder()
        }
        .onChange(of: treeInputHash) { _, newHash in
            _cachedFlatTree = flattenedTree
            _treeInputHash = newHash
        }
        .onAppear {
            _cachedFlatTree = flattenedTree
            _treeInputHash = treeInputHash
        }
        .onChange(of: pane.items.count) {
            // 이름 변경 대기
            if let name = pendingRenameName {
                if let newItem = pane.items.first(where: { $0.name == name }) {
                    pane.selection = [newItem.id]
                    pendingRenameName = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.renamingItemId = newItem.id
                    }
                }
            }
            // 변환 완료 후 자동스크롤 (items 변경 시 재시도)
            if let name = pendingScrollToName {
                if let newItem = pane.items.first(where: { $0.name == name }) {
                    pane.selection = [newItem.id]
                    pendingScrollToName = nil
                }
            }
        }
    }

    /// 특정 경로의 폴더만 갱신 (리플래시 없이)
    private func logPath(_ conn: Connection, _ path: String) -> String {
        conn.proto == .local ? path : "\(conn.host):\(path)"
    }

    private func reloadFolderInPane(_ pane: PaneState, path: String) async {
        if path == pane.currentPath {
            if let items = try? await FileService.shared.list(
                connection: pane.connection, path: path) {
                await MainActor.run {
                    pane.items = items
                    let validIDs = Set(pane.allItems.map(\.id))
                    pane.selection = pane.selection.intersection(validIDs)
                }
            }
        } else if let folder = await MainActor.run(body: {
            pane.allItems.first(where: {
                $0.isDirectory && pane.expandedFolders.contains($0.id) &&
                (pane.parentPath(for: $0.id) as NSString).appendingPathComponent($0.name) == path
            })
        }) {
            if let children = try? await FileService.shared.list(
                connection: pane.connection, path: path) {
                await MainActor.run {
                    pane.childrenCache[folder.id] = children
                }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], destPath: String) {
        app.appendLog(.info, "드롭 시작: destPath=\(destPath), providers=\(providers.count)")
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.transmitLiteItem.identifier) { data, _ in
                guard let data = data else {
                    self.app.appendLog(.warn, "드롭: 데이터 없음")
                    return
                }

                // 배열 디코딩 시도, 실패하면 단일 아이템 디코딩
                let dragItems: [DragItem]
                if let items = try? JSONDecoder().decode([DragItem].self, from: data) {
                    dragItems = items
                } else if let single = try? JSONDecoder().decode(DragItem.self, from: data) {
                    dragItems = [single]
                } else {
                    return
                }

                guard let first = dragItems.first else { return }
                let dragSide: PaneSide = first.sourceSide == "left" ? .left : .right

                // 같은 패널 + 같은 경로면 무시
                if dragSide == self.side {
                    let srcDir = (first.sourcePath as NSString).deletingLastPathComponent
                    if srcDir == destPath { return }
                }

                DispatchQueue.main.async {
                    let sourcePane = self.app.pane(dragSide)
                    let destPane = self.pane
                    let sc = sourcePane.connection
                    let dc = destPane.connection
                    let names = dragItems.map(\.name).joined(separator: ", ")
                    let sameSide = dragSide == self.side

                    // 같은 서버/로컬 내 (같은 패널 포함)
                    let sameLocation = sc.proto == dc.proto
                        && sc.host == dc.host
                        && sc.port == dc.port
                        && sc.username == dc.username

                    if sameLocation {
                        let action = sameSide ? "이동" : "이동"
                        // 확인 창
                        let alert = NSAlert()
                        alert.messageText = "\(action) 확인"
                        alert.informativeText = "\(dragItems.count)개 항목을 \(destPath) 로 \(action)하시겠습니까?\n\(names)"
                        alert.addButton(withTitle: action)
                        alert.addButton(withTitle: "취소")
                        guard alert.runModal() == .alertFirstButtonReturn else { return }

                        if sc.proto == .local {
                            sourcePane.suppressWatcherUntil = Date().addingTimeInterval(3)
                            destPane.suppressWatcherUntil = Date().addingTimeInterval(3)
                            // 소스 폴더 경로
                            let srcDir = (first.sourcePath as NSString).deletingLastPathComponent
                            // 로컬 이동: 동기 처리 + 직접 아이템 제거
                            var movedNames: [String] = []
                            for dragItem in dragItems {
                                let dstPath = (destPath as NSString)
                                    .appendingPathComponent(dragItem.name)
                                do {
                                    try FileManager.default.moveItem(
                                        atPath: dragItem.sourcePath, toPath: dstPath)
                                    movedNames.append(dragItem.name)
                                    TransferManager.shared.appendLog(.ok, "이동 완료: \(self.logPath(sc, dragItem.sourcePath)) → \(self.logPath(dc, destPath))")
                                } catch {
                                    TransferManager.shared.appendLog(.error, "이동 실패: \(self.logPath(sc, dragItem.sourcePath)) — \(error.localizedDescription)")
                                }
                            }
                            // 소스 패널에서 이동된 항목 제거 (리플래시 없이)
                            let movedSet = Set(movedNames)
                            sourcePane.items.removeAll { movedSet.contains($0.name) }
                            for (folderID, children) in sourcePane.childrenCache {
                                let filtered = children.filter { !movedSet.contains($0.name) }
                                if filtered.count != children.count {
                                    sourcePane.childrenCache[folderID] = filtered
                                }
                            }
                            sourcePane.selection.removeAll()
                            // 양쪽 패널의 소스/대상 폴더 모두 갱신
                            let otherPane = self.app.pane(self.side.opposite)
                            Task {
                                await self.reloadFolderInPane(sourcePane, path: destPath)
                                await self.reloadFolderInPane(destPane, path: destPath)
                                await self.reloadFolderInPane(destPane, path: srcDir)
                                // 반대편 패널에서도 같은 폴더가 펼쳐져 있으면 갱신
                                await self.reloadFolderInPane(otherPane, path: srcDir)
                                await self.reloadFolderInPane(otherPane, path: destPath)
                            }
                        } else {
                            // 원격 서버 이동
                            Task {
                                for dragItem in dragItems {
                                    let dstPath = (destPath as NSString)
                                        .appendingPathComponent(dragItem.name)
                                    do {
                                        try await FileService.shared.moveFile(
                                            connection: sc, from: dragItem.sourcePath, to: dstPath)
                                        TransferManager.shared.appendLog(.ok, "이동 완료: \(self.logPath(sc, dragItem.sourcePath)) → \(self.logPath(dc, destPath))")
                                    } catch {
                                        TransferManager.shared.appendLog(.error, "이동 실패: \(self.logPath(sc, dragItem.sourcePath)) — \(error.localizedDescription)")
                                    }
                                }
                                await self.reload()
                            }
                        }
                        return
                    }

                    // 서버 ↔ 로컬: 전송 큐
                    let direction: TransferDirection =
                        sc.proto == .local ? .upload : .download
                    let label = direction == .upload ? "업로드" : "다운로드"

                    // 확인 창
                    let alert = NSAlert()
                    alert.messageText = "\(label) 확인"
                    alert.informativeText = "\(dragItems.count)개 항목을 \(destPath) 로 \(label)하시겠습니까?\n\(names)"
                    alert.addButton(withTitle: label)
                    alert.addButton(withTitle: "취소")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }

                    for dragItem in dragItems {
                        let dstPath = (destPath as NSString)
                            .appendingPathComponent(dragItem.name)

                        let t = Transfer(
                            name: dragItem.name,
                            sourcePath: dragItem.sourcePath,
                            destinationPath: dstPath,
                            direction: direction,
                            totalBytes: dragItem.size,
                            source: sc,
                            dest: dc,
                            isDirectory: dragItem.isDirectory
                        )
                        TransferManager.shared.enqueue(t)
                    }
                    TransferManager.shared.appendLog(.info, "\(label) 대기열: \(dragItems.count)개 항목 → \(self.logPath(dc, destPath))")
                }
            }
        }
    }

    private func handleExternalDrop(_ providers: [NSItemProvider], destPath: String) {
        let destPane = pane
        let dc = destPane.connection

        // 먼저 모든 URL을 수집
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            let label = dc.proto == .local ? "복사" : "업로드"

            let alert = NSAlert()
            alert.messageText = "\(label) 확인"
            alert.informativeText = "\(urls.count)개 항목을 \(destPath) 로 \(label)하시겠습니까?\n\(names)"
            alert.addButton(withTitle: label)
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            for url in urls {
                let srcPath = url.path
                let name = url.lastPathComponent
                let dstPath = (destPath as NSString).appendingPathComponent(name)

                if dc.proto == .local {
                    Task {
                        do {
                            try FileManager.default.copyItem(atPath: srcPath, toPath: dstPath)
                            self.app.appendLog(.ok, "복사 완료: \(name)")
                            await self.reload()
                        } catch {
                            self.app.appendLog(.error, "복사 실패: \(error.localizedDescription)")
                        }
                    }
                } else {
                    let fm = FileManager.default
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: srcPath, isDirectory: &isDir)
                    let size: Int64 = isDir.boolValue
                        ? FileService.localDirectorySize(path: srcPath)
                        : ((try? fm.attributesOfItem(atPath: srcPath)[.size] as? Int64) ?? 0)
                    let localConn = Connection.localPlaceholder
                    let t = Transfer(
                        name: name, sourcePath: srcPath, destinationPath: dstPath,
                        direction: .upload, totalBytes: size,
                        source: localConn, dest: dc,
                        isDirectory: isDir.boolValue)
                    TransferManager.shared.enqueue(t)
                    TransferManager.shared.appendLog(.info, "업로드 대기열: \(url.path) → \(self.logPath(dc, destPath))/\(name)")
                }
            }
        }
    }

    private func toggleExpand(item: RemoteItem, parentPath: String) {
        guard item.isDirectory else { return }
        if pane.expandedFolders.contains(item.id) {
            // 접기
            pane.expandedFolders.remove(item.id)
            pane.childrenCache.removeValue(forKey: item.id)
        } else {
            // 펼치기: 자식 로드
            let folderPath = (parentPath as NSString).appendingPathComponent(item.name)
            pane.loadingFolders.insert(item.id)
            pane.expandedFolders.insert(item.id)
            Task {
                do {
                    let children = try await FileService.shared.list(
                        connection: pane.connection, path: folderPath)
                    await MainActor.run {
                        pane.childrenCache[item.id] = children
                        pane.loadingFolders.remove(item.id)
                    }
                } catch {
                    await MainActor.run {
                        _ = pane.expandedFolders.remove(item.id)
                        pane.loadingFolders.remove(item.id)
                    }
                    app.appendLog(.error, "폴더 열기 실패: \(item.name)")
                }
            }
        }
    }

    private func fileRow(idx: Int, entry: (depth: Int, item: RemoteItem, parentPath: String), isLocalConn: Bool, groupPosition: FileRow.GroupPosition = .none) -> some View {
        let item: RemoteItem = entry.item
        let depth: Int = entry.depth
        let parentPath: String = entry.parentPath
        return FileRow(item: item,
                       isAltRow: idx % 2 == 1,
                       isSelected: pane.selection.contains(item.id),
                       isActiveSelection: isActive,
                       isExpanded: pane.expandedFolders.contains(item.id),
                       isFolderLoading: pane.loadingFolders.contains(item.id),
                       indentLevel: depth,
                       nameWidth: CGFloat(nameWidth),
                       extWidth: CGFloat(extWidth),
                       sizeWidth: CGFloat(sizeWidth),
                       dateWidth: CGFloat(dateWidth),
                       zoomScale: zoomScale,
                       side: side,
                       currentPath: parentPath,
                       onAction: { action in
                           switch action {
                           case .toggleExpand: toggleExpand(item: item, parentPath: parentPath)
                           case .double: handleDouble(item: item, parentPath: parentPath)
                           case .info: onInfo(item)
                           case .rename(let newName): renameItem(item, in: parentPath, to: newName)
                           case .delete: deleteItem(item, in: parentPath)
                           case .newFolder: createNewFolder()
                           case .setTag(let colorName): setTag(item: item, in: parentPath, colorName: colorName)
                           case .convertImage(let fmt): runTrackedConversion(item: item, parentPath: parentPath, outputExt: fmt.ext) { svc, path, prog, pct, proc in try await svc.convertImage(at: path, to: fmt, progress: prog, percentProgress: pct, processHandler: proc) }
                           case .convertVideo(let fmt): runTrackedConversion(item: item, parentPath: parentPath, outputExt: fmt.ext) { svc, path, prog, pct, proc in try await svc.convertVideo(at: path, to: fmt, progress: prog, percentProgress: pct, processHandler: proc) }
                           case .convertAudio(let fmt): runTrackedConversion(item: item, parentPath: parentPath, outputExt: fmt.ext) { svc, path, prog, pct, proc in try await svc.convertAudio(at: path, to: fmt, progress: prog, percentProgress: pct, processHandler: proc) }
                           case .compressPDF(let q): runTrackedConversion(item: item, parentPath: parentPath, outputExt: "pdf") { svc, path, prog, pct, proc in try await svc.compressPDF(at: path, quality: q, progress: prog, percentProgress: pct, processHandler: proc) }
                           case .pdfToImages(let fmt): runTrackedConversion(item: item, parentPath: parentPath, outputExt: fmt.ext) { svc, path, prog, pct, proc in
                               let results = try await svc.convertPDFToImages(at: path, format: fmt, progress: prog, percentProgress: pct)
                               return results.first ?? ""
                           }
                           case .convertToPDF: runTrackedConversion(item: item, parentPath: parentPath, outputExt: "pdf") { svc, path, prog, pct, proc in try await svc.convertToPDF(at: path, progress: prog, percentProgress: pct, processHandler: proc) }
                           case .compressFiles: compressSelectedFiles(item: item, parentPath: parentPath)
                           case .decompressFiles: decompressArchive(item: item, parentPath: parentPath)
                           }
                       },
                       conversionProgress: pane.conversionProgress[item.name],
                       onCancelConversion: pane.conversionProgress[item.name] != nil ? {
                           pane.cancelConversion(fileName: item.name)
                           Task { await self.reload() }
                       } : nil,
                       isLocal: isLocalConn,
                       renamingItemId: $renamingItemId,
                       isDropTarget: dropTargetItemId == item.id,
                       isContextTarget: contextMenuItemId == item.id,
                       groupPosition: groupPosition)
        .equatable()
        .onDrop(of: [UTType.transmitLiteItem, .fileURL], isTargeted: Binding(
            get: { dropTargetItemId == item.id },
            set: { isOver in
                if item.isDirectory {
                    dropTargetItemId = isOver ? item.id : nil
                }
            }
        )) { providers in
            guard item.isDirectory else { return false }
            let folderPath = (parentPath as NSString).appendingPathComponent(item.name)
            let hasInternal = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.transmitLiteItem.identifier) }
            if hasInternal {
                handleDrop(providers, destPath: folderPath)
            } else {
                handleExternalDrop(providers, destPath: folderPath)
            }
            dropTargetItemId = nil
            return true
        }
    }

    func createNewFolder() {
        let base = "새 폴더"
        var name = base; var i = 1
        while pane.allItems.contains(where: { $0.name == name }) { i += 1; name = "\(base) \(i)" }
        let p = (pane.currentPath as NSString).appendingPathComponent(name)
        Task {
            do {
                if pane.connection.proto == .local {
                    try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: false)
                } else {
                    try await FileService.shared.mkdir(connection: pane.connection, path: p)
                }
                app.appendLog(.ok, "폴더 생성: \(name)")
                pendingRenameName = name
            } catch {
                app.appendLog(.error, "폴더 생성 실패: \(error.localizedDescription)")
            }
        }
    }

    private func setTag(item: RemoteItem, in parentPath: String, colorName: String?) {
        let path = (parentPath as NSString).appendingPathComponent(item.name)

        if pane.connection.proto == .local {
            // 로컬: xattr로 Finder 태그 설정
            Task {
                do {
                    try await FileService.shared.setFinderTagColor(atPath: path, colorName: colorName)
                } catch {
                    app.appendLog(.error, "태그 설정 실패: \(error.localizedDescription)")
                }
            }
        } else {
            // 서버: TagStore에 저장 (디렉토리 여부 포함)
            TagStore.shared.setTag(connection: pane.connection, path: path,
                                   colorName: colorName, isDirectory: item.isDirectory)
        }

        // 인메모리 업데이트 (깜빡임 방지)
        if let idx = pane.items.firstIndex(where: { $0.id == item.id }) {
            pane.items[idx].tagColorName = colorName
        }
            // childrenCache도 업데이트
        for (folderId, children) in pane.childrenCache {
            if let idx = children.firstIndex(where: { $0.id == item.id }) {
                pane.childrenCache[folderId]?[idx].tagColorName = colorName
            }
        }
        pane.tagVersion += 1
        let tagLabel = colorName ?? "없음"
        app.appendLog(.ok, "태그 변경: \(item.name) → \(tagLabel)")
    }

    private func deleteItem(_ item: RemoteItem, in parentPath: String) {
        let p = (parentPath as NSString).appendingPathComponent(item.name)
        Task {
            do {
                if pane.connection.proto == .local {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
                } else {
                    try await FileService.shared.remove(
                        connection: pane.connection, path: p, isDirectory: item.isDirectory)
                }
                TransferManager.shared.appendLog(.ok, "삭제 완료: \(logPath(pane.connection, p))")
                pane.selection.remove(item.id)
                await reload()
            } catch {
                TransferManager.shared.appendLog(.error, "삭제 실패: \(logPath(pane.connection, p))")
            }
        }
    }

    private func renameItem(_ item: RemoteItem, in parentPath: String, to newName: String) {
        let oldPath = (parentPath as NSString).appendingPathComponent(item.name)
        let newPath = (parentPath as NSString).appendingPathComponent(newName)
        Task {
            do {
                if pane.connection.proto == .local {
                    try FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
                } else {
                    try await FileService.shared.rename(
                        connection: pane.connection, from: oldPath, to: newPath)
                }
                app.appendLog(.ok, "이름 변경: \(item.name) → \(newName)")
                await reload()
            } catch {
                app.appendLog(.error, "이름 변경 실패: \(error.localizedDescription)")
            }
        }
    }

    private func scrollToConversionResult(tree: [(depth: Int, item: RemoteItem, parentPath: String)], proxy: ScrollViewProxy) {
        guard let name = pendingScrollToName else { return }
        // 현재 tree에서 찾기
        if let target = tree.first(where: { $0.item.name == name }) {
            pane.selection = [target.item.id]
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(target.item.id, anchor: .center)
            }
            pendingScrollToName = nil
        } else {
            // tree 캐시가 아직 안 갱신됐을 수 있으므로 items에서 직접 검색
            if let item = pane.items.first(where: { $0.name == name }) {
                pane.selection = [item.id]
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(item.id, anchor: .center)
                }
                pendingScrollToName = nil
            }
        }
    }

    // MARK: - 변환/압축

    private func runConversion(item: RemoteItem, parentPath: String,
                               task: @escaping (ConversionService, String, @escaping (String) -> Void) async throws -> String) {
        let path = (parentPath as NSString).appendingPathComponent(item.name)
        guard pane.connection.proto == .local else {
            app.appendLog(.error, "변환은 로컬 파일만 지원합니다")
            return
        }
        Task {
            app.appendLog(.info, "변환 시작: \(item.name)")
            do {
                let result = try await task(ConversionService.shared, path) { msg in
                    Task { @MainActor in self.app.appendLog(.info, msg) }
                }
                let resultName = !result.isEmpty ? (result as NSString).lastPathComponent : item.name
                app.appendLog(.ok, "변환 완료: \(resultName)")
                pendingScrollToName = resultName
                await reload()
            } catch {
                app.appendLog(.error, "변환 실패: \(error.localizedDescription)")
            }
        }
    }

    /// percentProgress + processHandler 지원 변환
    /// 출력 파일명(새 파일) 기준으로 진행률/취소 추적, 가상 아이템으로 리스트에 즉시 표시
    private func runTrackedConversion(item: RemoteItem, parentPath: String, outputExt: String,
                                      task: @escaping (ConversionService, String, @escaping (String) -> Void, @escaping (Double) -> Void, @escaping (Process) -> Void) async throws -> String) {
        let path = (parentPath as NSString).appendingPathComponent(item.name)
        guard pane.connection.proto == .local else {
            app.appendLog(.error, "변환은 로컬 파일만 지원합니다")
            return
        }
        // 예상 출력 파일명 계산
        let baseName = (item.name as NSString).deletingPathExtension
        let expectedOutputPath = ConversionService.shared.uniquePath(
            (parentPath as NSString).appendingPathComponent("\(baseName).\(outputExt)")
        )
        let trackingKey = (expectedOutputPath as NSString).lastPathComponent

        Task {
            // 가상 아이템을 pane.items에 추가 (실제 파일 없이 리스트에 표시)
            let virtualItem = RemoteItem(name: trackingKey, isDirectory: false, size: 0, modified: Date(),
                                          permissions: "", owner: "", group: "")
            pane.items.append(virtualItem)
            pane.conversionProgress[trackingKey] = 0.0
            pane.conversionOutputPaths[trackingKey] = expectedOutputPath
            app.appendLog(.info, "변환 시작: \(item.name)")
            do {
                let result = try await task(ConversionService.shared, path,
                    { msg in Task { @MainActor in self.app.appendLog(.info, msg) } },
                    { pct in
                        DispatchQueue.main.async {
                            self.pane.conversionProgress[trackingKey] = pct
                        }
                    },
                    { proc in
                        DispatchQueue.main.async {
                            self.pane.conversionProcesses[trackingKey] = proc
                            self.pane.conversionOutputPaths[trackingKey] = expectedOutputPath
                        }
                    }
                )
                let resultName = (result as NSString).lastPathComponent
                pane.conversionProgress.removeValue(forKey: trackingKey)
                pane.conversionProcesses.removeValue(forKey: trackingKey)
                pane.conversionOutputPaths.removeValue(forKey: trackingKey)
                pane.conversionProgress.removeValue(forKey: resultName)
                pane.conversionProcesses.removeValue(forKey: resultName)
                pane.conversionOutputPaths.removeValue(forKey: resultName)
                app.appendLog(.ok, "변환 완료: \(resultName)")
                pendingScrollToName = resultName
                await reload()
            } catch {
                pane.conversionProgress.removeValue(forKey: trackingKey)
                pane.conversionProcesses.removeValue(forKey: trackingKey)
                // 취소/실패 시 미완성 출력 파일 삭제
                if let outPath = pane.conversionOutputPaths[trackingKey] {
                    try? FileManager.default.removeItem(atPath: outPath)
                }
                pane.conversionOutputPaths.removeValue(forKey: trackingKey)
                app.appendLog(.error, "변환 실패: \(error.localizedDescription)")
                await reload()  // reload로 가상 아이템 제거
            }
        }
    }

    private func compressSelectedFiles(item: RemoteItem, parentPath: String) {
        // 선택된 항목이 있으면 선택된 것들, 없으면 우클릭 대상 아이템
        let selectedItems = pane.selectedItems
        let itemsToCompress = selectedItems.isEmpty ? [item] : (selectedItems.contains(where: { $0.id == item.id }) ? selectedItems : [item])
        guard !itemsToCompress.isEmpty else { return }
        guard pane.connection.proto == .local else {
            app.appendLog(.error, "압축은 로컬 파일만 지원합니다")
            return
        }
        let paths = itemsToCompress.map { (parentPath as NSString).appendingPathComponent($0.name) }

        // 출력 zip 파일명으로 추적
        let zipBaseName = itemsToCompress.count == 1 ? "\(itemsToCompress[0].name).zip" : "Archive.zip"
        let expectedOutputPath = ConversionService.shared.uniquePath(
            (parentPath as NSString).appendingPathComponent(zipBaseName)
        )
        let trackingKey = (expectedOutputPath as NSString).lastPathComponent

        Task {
            // 가상 아이템을 pane.items에 추가 (실제 파일 없이 리스트에 표시)
            let virtualItem = RemoteItem(name: trackingKey, isDirectory: false, size: 0, modified: Date(),
                                          permissions: "", owner: "", group: "")
            pane.items.append(virtualItem)
            pane.conversionProgress[trackingKey] = 0.0
            pane.conversionOutputPaths[trackingKey] = expectedOutputPath
            app.appendLog(.info, "압축 시작: \(itemsToCompress.count)개 항목")
            do {
                let result = try await ConversionService.shared.compress(
                    paths: paths,
                    progress: { msg in Task { @MainActor in self.app.appendLog(.info, msg) } },
                    percentProgress: { pct in
                        DispatchQueue.main.async { self.pane.conversionProgress[trackingKey] = pct }
                    },
                    processHandler: { proc in
                        DispatchQueue.main.async {
                            self.pane.conversionProcesses[trackingKey] = proc
                            self.pane.conversionOutputPaths[trackingKey] = expectedOutputPath
                        }
                    }
                )
                let resultName = (result as NSString).lastPathComponent
                pane.conversionProgress.removeValue(forKey: trackingKey)
                pane.conversionProcesses.removeValue(forKey: trackingKey)
                pane.conversionOutputPaths.removeValue(forKey: trackingKey)
                pane.conversionProgress.removeValue(forKey: resultName)
                app.appendLog(.ok, "압축 완료: \(resultName)")
                pendingScrollToName = resultName
                await reload()
            } catch {
                pane.conversionProgress.removeValue(forKey: trackingKey)
                pane.conversionProcesses.removeValue(forKey: trackingKey)
                if let outPath = pane.conversionOutputPaths[trackingKey] {
                    try? FileManager.default.removeItem(atPath: outPath)
                }
                pane.conversionOutputPaths.removeValue(forKey: trackingKey)
                app.appendLog(.error, "압축 실패: \(error.localizedDescription)")
                await reload()
            }
        }
    }

    private func decompressArchive(item: RemoteItem, parentPath: String) {
        let path = (parentPath as NSString).appendingPathComponent(item.name)
        Task {
            app.appendLog(.info, "압축 해제 시작: \(item.name)")
            do {
                let resultNames = try await ConversionService.shared.decompressZip(at: path) { msg in
                    Task { @MainActor in self.app.appendLog(.info, msg) }
                }
                if let firstName = resultNames.first {
                    pendingScrollToName = firstName
                }
                await reload()
            } catch {
                app.appendLog(.error, "압축 해제 실패: \(error.localizedDescription)")
            }
        }
    }

    private func handleDouble(item: RemoteItem, parentPath: String) {
        // 태그 필터 모드: 해당 파일의 부모 폴더로 이동
        if pane.tagFilter != nil, let fp = item.fullPath {
            pane.tagFilter = nil
            let parent = (fp as NSString).deletingLastPathComponent
            if item.isDirectory {
                pane.navigate(to: fp)
            } else {
                pane.navigate(to: parent)
            }
            Task { await reload() }
            return
        }

        if item.isDirectory {
            let targetPath = (parentPath as NSString).appendingPathComponent(item.name)
            pane.navigate(to: targetPath)
            Task { await reload() }
        } else if pane.connection.proto == .local {
            let fullPath = (parentPath as NSString).appendingPathComponent(item.name)
            let ext = (item.name as NSString).pathExtension.lowercased()
            if ["zip", "tar", "gz", "tgz", "bz2", "7z"].contains(ext) {
                decompressArchive(item: item, parentPath: parentPath)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: fullPath))
            }
        }
    }


    private func handleArrowKey(_ keyCode: UInt16, tree: [(depth: Int, item: RemoteItem, parentPath: String)]) {
        app.setActive(side)
        guard !tree.isEmpty else { return }

        var t = Transaction(); t.disablesAnimations = true
        // 현재 선택된 행 찾기
        let currentRow: Int
        if let selId = pane.selection.first,
           let idx = tree.firstIndex(where: { $0.item.id == selId }) {
            currentRow = idx
        } else {
            withTransaction(t) { pane.selection = [tree[0].item.id] }
            return
        }

        switch keyCode {
        case 126: // Up
            let newRow = max(0, currentRow - 1)
            withTransaction(t) { pane.selection = [tree[newRow].item.id] }
        case 125: // Down
            let newRow = min(tree.count - 1, currentRow + 1)
            withTransaction(t) { pane.selection = [tree[newRow].item.id] }
        case 124: // Right - 폴더 펼치기
            let entry = tree[currentRow]
            if entry.item.isDirectory && !pane.expandedFolders.contains(entry.item.id) {
                toggleExpand(item: entry.item, parentPath: entry.parentPath)
            }
        case 123: // Left - 폴더 접기, 또는 부모로 이동
            let entry = tree[currentRow]
            if entry.item.isDirectory && pane.expandedFolders.contains(entry.item.id) {
                toggleExpand(item: entry.item, parentPath: entry.parentPath)
            } else if entry.depth > 0 {
                // 부모 폴더로 선택 이동
                for i in stride(from: currentRow - 1, through: 0, by: -1) {
                    if tree[i].depth < entry.depth {
                        withTransaction(t) { pane.selection = [tree[i].item.id] }
                        break
                    }
                }
            }
        default:
            break
        }
    }

    private func handleListClick(row: Int, point: CGPoint, mods: NSEvent.ModifierFlags, tree: [(depth: Int, item: RemoteItem, parentPath: String)]) {
        app.setActive(side)
        renamingItemId = nil
        contextMenuItemId = nil
        guard row >= 0, row < tree.count else { return }
        let entry = tree[row]

        // 디스클로저 화살표 영역인지 확인
        let indent = CGFloat(entry.depth) * 16
        let arrowEnd = 6 + indent + 14
        if point.x < arrowEnd && entry.item.isDirectory {
            toggleExpand(item: entry.item, parentPath: entry.parentPath)
            return
        }

        handleClick(item: entry.item, mods: mods, tree: tree)
    }

    private func handleClick(item: RemoteItem, mods: NSEvent.ModifierFlags? = nil, tree: [(depth: Int, item: RemoteItem, parentPath: String)]? = nil) {
        app.setActive(side)
        let mods = mods ?? NSEvent.modifierFlags
        if mods.contains(.command) {
            if pane.selection.contains(item.id) {
                pane.selection.remove(item.id)
            } else {
                pane.selection.insert(item.id)
            }
        } else if mods.contains(.shift), let first = pane.selection.first {
            let tree = tree ?? flattenedTree
            if let i1 = tree.firstIndex(where: { $0.item.id == first }),
               let i2 = tree.firstIndex(where: { $0.item.id == item.id }) {
                let range = i1 <= i2 ? i1...i2 : i2...i1
                pane.selection = Set(range.map { tree[$0].item.id })
            }
        } else {
            pane.selection = [item.id]
        }
    }

    private func selectItemsInMarquee(_ rect: CGRect) {
        // 첫 호출 시 ID 배열 캐시 (마키 중 재계산 방지)
        if cachedTreeIds.isEmpty {
            cachedTreeIds = flattenedTree.map(\.item.id)
        }
        let ids = cachedTreeIds
        let rh = rowHeight
        let minRow = max(0, Int(floor(rect.minY / rh)))
        let maxRow = min(ids.count - 1, Int(floor(rect.maxY / rh)))
        guard minRow <= maxRow, !ids.isEmpty else {
            if !pane.selection.isEmpty {
                pane.selection.removeAll()
                lastMarqueeSelection = []
            }
            return
        }
        let newSel = Set(ids[minRow...maxRow])
        // 실제 변경이 있을 때만 @Published 업데이트
        if newSel != lastMarqueeSelection {
            lastMarqueeSelection = newSel
            pane.selection = newSel
        }
    }

    private func reload() async {
        IconCache.shared.clearPathCache()
        await MainActor.run { pane.isLoading = true; pane.tagFilter = nil }
        do {
            let items = try await FileService.shared.list(connection: pane.connection,
                                                          path: pane.currentPath)
            await MainActor.run { pane.items = items; pane.isLoading = false }
        } catch {
            await MainActor.run {
                pane.isLoading = false
                pane.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - File Row

private enum FileRowAction {
    case toggleExpand
    case double
    case info
    case rename(String)
    case delete
    case newFolder
    case setTag(String?)
    // 변환 기능
    case convertImage(ConversionService.ImageFormat)
    case convertVideo(ConversionService.VideoFormat)
    case convertAudio(ConversionService.AudioFormat)
    case compressPDF(Int)        // quality %
    case pdfToImages(ConversionService.ImageFormat)
    case convertToPDF
    case compressFiles
    case decompressFiles
}

private struct FileRow: View, Equatable {
    static func == (lhs: FileRow, rhs: FileRow) -> Bool {
        lhs.item.id == rhs.item.id &&
        lhs.item.name == rhs.item.name &&
        lhs.item.size == rhs.item.size &&
        lhs.item.modified == rhs.item.modified &&
        lhs.item.permissions == rhs.item.permissions &&
        lhs.item.tagColorName == rhs.item.tagColorName &&
        lhs.isAltRow == rhs.isAltRow &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isActiveSelection == rhs.isActiveSelection &&
        lhs.isExpanded == rhs.isExpanded &&
        lhs.isFolderLoading == rhs.isFolderLoading &&
        lhs.indentLevel == rhs.indentLevel &&
        lhs.nameWidth == rhs.nameWidth &&
        lhs.extWidth == rhs.extWidth &&
        lhs.sizeWidth == rhs.sizeWidth &&
        lhs.dateWidth == rhs.dateWidth &&
        lhs.zoomScale == rhs.zoomScale &&
        lhs.isDropTarget == rhs.isDropTarget &&
        lhs.isContextTarget == rhs.isContextTarget &&
        lhs.groupPosition == rhs.groupPosition &&
        lhs.transferProgress == rhs.transferProgress &&
        lhs.conversionProgress == rhs.conversionProgress &&
        lhs.isLocal == rhs.isLocal &&
        (lhs.renamingItemId == lhs.item.id) == (rhs.renamingItemId == rhs.item.id)
    }

    enum GroupPosition: Equatable {
        case none    // 선택 안됨
        case single  // 단독 선택
        case first   // 그룹 첫 번째
        case middle  // 그룹 중간
        case last    // 그룹 마지막
    }

    let item: RemoteItem
    let isAltRow: Bool
    let isSelected: Bool
    let isActiveSelection: Bool
    var isExpanded: Bool = false
    var isFolderLoading: Bool = false
    var indentLevel: Int = 0
    let nameWidth: CGFloat
    let extWidth: CGFloat
    let sizeWidth: CGFloat
    let dateWidth: CGFloat
    var zoomScale: CGFloat = 1
    let side: PaneSide
    let currentPath: String
    let onAction: (FileRowAction) -> Void
    var transferProgress: Double? = nil
    var conversionProgress: Double? = nil
    var onCancelConversion: (() -> Void)? = nil
    var isLocal: Bool = false
    @Binding var renamingItemId: UUID?
    var isDropTarget: Bool = false
    var isContextTarget: Bool = false
    var groupPosition: GroupPosition = .none
    @State private var editName: String = ""
    @FocusState private var nameFieldFocused: Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return f
    }()

    private var rowH: CGFloat { 22 * zoomScale }
    private var iconSz: CGFloat { 16 * zoomScale }
    private let mainFontSize: CGFloat = 12
    private let subFontSize: CGFloat = 10.5

    /// Transmit 스타일 핑크 선택 색상
    private static let selectionPink = Color(red: 0.78, green: 0.28, blue: 0.51)
    /// Transmit 스타일 다크 배경 색상
    private static let tmListBg = Color.panelList
    private static let tmAltBg = Color.panelCard

    private var bgColor: Color {
        if isDropTarget {
            return Color.accentColor.opacity(0.35)
        }
        if isContextTarget && !isSelected {
            return Self.selectionPink.opacity(0.25)
        }
        if isSelected {
            return isActiveSelection
                ? Self.selectionPink
                : Color(NSColor.unemphasizedSelectedContentBackgroundColor)
        }
        return isAltRow
            ? Self.tmAltBg
            : Self.tmListBg
    }

    private var isHiddenFile: Bool { item.name.hasPrefix(".") }
    private var isRecentlyModified: Bool {
        item.modified > Date().addingTimeInterval(-86400)
    }

    private var fgColor: Color {
        if isSelected && isActiveSelection { return .white }
        if isHiddenFile { return .secondary.opacity(0.6) }
        if isRecentlyModified { return Color.recentTint }
        return .primary
    }

    private var dimColor: Color {
        if isSelected && isActiveSelection { return .white.opacity(0.8) }
        return isHiddenFile ? .secondary.opacity(0.4) : .secondary
    }

    private var indentWidth: CGFloat { CGFloat(indentLevel) * 16 }

    private var groupShape: some Shape {
        let r: CGFloat = 14
        switch groupPosition {
        case .none, .single:
            return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r,
                                           bottomTrailingRadius: r, topTrailingRadius: r)
        case .first:
            return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0, topTrailingRadius: r)
        case .middle:
            return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0, topTrailingRadius: 0)
        case .last:
            return UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: r,
                                           bottomTrailingRadius: r, topTrailingRadius: 0)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
          HStack(spacing: 0) {
            // 기본 왼쪽 여백 + 인덴트
            Color.clear.frame(width: 6 + indentWidth)

            // Disclosure arrow — ClickHandler 밖에서 독립 처리
            Group {
                if item.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(dimColor)
                } else {
                    Color.clear
                }
            }
            .frame(width: 14, height: rowH)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { /* 더블클릭 무시 */ }
            .onTapGesture {
                if item.isDirectory { onAction(.toggleExpand) }
            }

            // Icon + Name
            HStack(spacing: 5) {
                ZStack {
                    if isLocal {
                        FileIconView(path: (currentPath as NSString).appendingPathComponent(item.name),
                                     isDirectory: item.isDirectory, size: iconSz)
                            .opacity(isHiddenFile && !(isSelected && isActiveSelection) ? 0.45 : 1.0)
                    } else {
                        Image(nsImage: item.systemIcon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .opacity(isHiddenFile && !(isSelected && isActiveSelection) ? 0.45 : 1.0)
                    }
                    if let progress = transferProgress {
                        Circle()
                            .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                            .frame(width: iconSz - 2, height: iconSz - 2)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Self.selectionPink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: iconSz - 2, height: iconSz - 2)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.3), value: progress)
                    }
                }
                .frame(width: iconSz, height: iconSz)
                .background {
                    if isSelected {
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SelectedIconFrameKey.self,
                                            value: geo.frame(in: .global))
                        }
                    }
                }
                if renamingItemId == item.id {
                    TextField("", text: $editName)
                        .font(.system(size: mainFontSize))
                        .textFieldStyle(.plain)
                        .focused($nameFieldFocused)
                        .onAppear {
                            editName = item.name
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                nameFieldFocused = true
                            }
                        }
                        .onSubmit { commitRename() }
                        .onExitCommand { cancelRename() }
                        .onChange(of: nameFieldFocused) { _, focused in
                            if !focused { commitRename() }
                        }
                        .padding(.horizontal, 2)
                        .background(Color.panelList)
                        .cornerRadius(2)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Self.selectionPink, lineWidth: 1))
                } else {
                    Text(item.name)
                        .font(.system(size: mainFontSize))
                        .lineLimit(1)
                        .foregroundStyle(fgColor)
                    if isFolderLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: iconSz, height: iconSz)
                    }
                    if let tagColor = item.tagColorName {
                        Circle()
                            .fill(Self.tagColor(tagColor))
                            .frame(width: 8, height: 8)
                    }
                    // 변환 진행률
                    if let pct = conversionProgress {
                        Text("\(Int(pct * 100))%")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Self.selectionPink)
                        ProgressView(value: pct)
                            .progressViewStyle(.linear)
                            .tint(Self.selectionPink)
                            .frame(width: 50)
                        Button {
                            onCancelConversion?()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("변환 중지")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 2)
          }
          .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
          .clipped()

            // Extension
            Text(item.isDirectory ? "" : (item.name as NSString).pathExtension.uppercased())
                .font(.system(size: subFontSize))
                .foregroundStyle(dimColor)
                .lineLimit(1)
                .frame(width: extWidth, alignment: .leading)
                .padding(.horizontal, 4)

            // Size
            Text(item.isDirectory ? "--" : formatSize(item.size))
                .font(.system(size: subFontSize))
                .foregroundStyle(dimColor)
                .frame(width: sizeWidth, alignment: .trailing)
                .padding(.horizontal, 6)

            // Date
            Text(Self.dateFormatter.string(from: item.modified))
                .font(.system(size: subFontSize))
                .foregroundStyle(dimColor)
                .lineLimit(1)
                .frame(width: dateWidth, alignment: .leading)
                .padding(.horizontal, 6)
        }
        .frame(height: rowH)
        .padding(.horizontal, 3)
        .clipped()
        .background(
            groupShape
                .fill(bgColor)
                .padding(.horizontal, 2)
        )
        .overlay(
            isDropTarget
                ? AnyShape(RoundedRectangle(cornerRadius: 14))
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(.horizontal, 2)
                : (isContextTarget && !isSelected)
                    ? AnyShape(RoundedRectangle(cornerRadius: 14))
                        .stroke(Self.selectionPink.opacity(0.5), lineWidth: 1)
                        .padding(.horizontal, 2)
                    : nil
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button("열기") { onAction(.double) }
            Button("정보 가져오기") { onAction(.info) }
                .keyboardShortcut("i", modifiers: .command)
            Divider()
            Button("새 폴더") { onAction(.newFolder) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("이름 변경") { renamingItemId = item.id }
            Button("휴지통으로 이동") { onAction(.delete) }
                .keyboardShortcut(.delete, modifiers: .command)
            Divider()

            // 변환/압축 메뉴 (로컬 전용)
            if isLocal && !item.isDirectory {
                let filePath = (currentPath as NSString).appendingPathComponent(item.name)
                let cat = ConversionService.category(for: filePath)
                switch cat {
                case .image:
                    Menu("이미지 변환") {
                        let currentExt = (item.name as NSString).pathExtension.lowercased()
                        ForEach(ConversionService.ImageFormat.all.filter { $0.ext != currentExt }, id: \.ext) { fmt in
                            Button(fmt.name) { onAction(.convertImage(fmt)) }
                        }
                    }
                case .video:
                    Menu("동영상 변환") {
                        let currentExt = (item.name as NSString).pathExtension.lowercased()
                        ForEach(ConversionService.VideoFormat.all.filter { $0.ext != currentExt }, id: \.ext) { fmt in
                            Button(fmt.name) { onAction(.convertVideo(fmt)) }
                        }
                    }
                    Menu("오디오 추출") {
                        ForEach(ConversionService.AudioFormat.all, id: \.ext) { fmt in
                            Button(fmt.name) { onAction(.convertAudio(fmt)) }
                        }
                    }
                case .audio:
                    Menu("오디오 변환") {
                        let currentExt = (item.name as NSString).pathExtension.lowercased()
                        ForEach(ConversionService.AudioFormat.all.filter { $0.ext != currentExt }, id: \.ext) { fmt in
                            Button(fmt.name) { onAction(.convertAudio(fmt)) }
                        }
                    }
                case .pdf:
                    Menu("PDF 압축") {
                        Button("고품질 (90%)") { onAction(.compressPDF(90)) }
                        Button("보통 (70%)") { onAction(.compressPDF(70)) }
                        Button("최소 크기 (40%)") { onAction(.compressPDF(40)) }
                    }
                    Menu("PDF → 이미지") {
                        ForEach(ConversionService.ImageFormat.all.filter { [.png, .jpeg, .tiff].contains($0.utType) }, id: \.ext) { fmt in
                            Button(fmt.name) { onAction(.pdfToImages(fmt)) }
                        }
                    }
                case .document:
                    Button("PDF로 변환") { onAction(.convertToPDF) }
                default:
                    EmptyView()
                }
                Divider()
            }
            if isLocal {
                let itemExt = (item.name as NSString).pathExtension.lowercased()
                if ["zip", "tar", "gz", "tgz", "bz2", "7z"].contains(itemExt) {
                    Button("압축 풀기") { onAction(.decompressFiles) }
                }
                Button("\"\(Self.truncatedMiddle(item.name, max: 25)).zip\" 으로 압축") { onAction(.compressFiles) }
                Divider()
            }

            Menu("태그") {
                ForEach(SidebarTag.defaults) { tag in
                    Button {
                        onAction(.setTag(item.tagColorName == tag.colorName ? nil : tag.colorName))
                    } label: {
                        HStack {
                            Image(nsImage: Self.tagCircleImage(tag.nsColor))
                            Text(tag.name)
                            if item.tagColorName == tag.colorName {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                if item.tagColorName != nil {
                    Divider()
                    Button("태그 제거", role: .destructive) { onAction(.setTag(nil)) }
                }
            }
        }
    }

    private func commitRename() {
        let newName = editName.trimmingCharacters(in: .whitespaces)
        if !newName.isEmpty && newName != item.name {
            onAction(.rename(newName))
        }
        renamingItemId = nil
    }

    private func cancelRename() {
        renamingItemId = nil
    }

    /// 파일명 중간 줄임: "longfilename.jpg" → "longf...me.jpg"
    private static func truncatedMiddle(_ name: String, max: Int) -> String {
        guard name.count > max else { return name }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let keep = max - ext.count - (ext.isEmpty ? 3 : 4) // 3 for "..."
        guard keep > 2 else { return name }
        let half = keep / 2
        let prefix = base.prefix(half)
        let suffix = base.suffix(keep - half)
        return ext.isEmpty ? "\(prefix)...\(suffix)" : "\(prefix)...\(suffix).\(ext)"
    }

    private static func tagCircleImage(_ color: NSColor) -> NSImage {
        let size: CGFloat = 12
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size)).fill()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    private static func tagColor(_ name: String) -> Color {
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

    private func formatSize(_ n: Int64) -> String {
        if n < 1024 { return "\(n) bytes" }
        if n < 1024 * 1024 { return String(format: "%.0f KB", Double(n) / 1024.0) }
        if n < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(n) / 1024.0 / 1024.0) }
        return String(format: "%.2f GB", Double(n) / 1024.0 / 1024.0 / 1024.0)
    }
}

// MARK: - List interaction overlay (click, double-click, marquee, file drag)

private struct ListInteractionOverlay: NSViewRepresentable {
    let rowHeight: CGFloat
    let itemCount: Int
    let isRenaming: Bool
    let nameEndX: (Int) -> CGFloat
    let onClick: (Int, CGPoint, NSEvent.ModifierFlags) -> Void
    let onDoubleClick: (Int) -> Void
    let onEmptyClick: () -> Void
    let onMarqueeUpdate: (CGRect) -> Void
    let onMarqueeEnd: () -> Void
    let makeDragData: (Int) -> Data?
    let dragUTI: String
    let selectedRows: () -> [Int]
    let isRowSelected: (Int) -> Bool
    let rowInfo: (Int) -> (name: String, path: String, isDirectory: Bool, isLocal: Bool, depth: Int)?
    var onKeyArrow: ((UInt16) -> Void)? = nil
    var onSelectAll: (() -> Void)? = nil
    var isRowConverting: ((Int) -> Bool)? = nil
    var onCancelConversion: ((Int) -> Void)? = nil
    var onRightClick: ((Int) -> Void)? = nil

    func makeNSView(context: Context) -> ListNSView {
        let v = ListNSView()
        sync(v)
        return v
    }

    func updateNSView(_ nsView: ListNSView, context: Context) { sync(nsView) }

    private func sync(_ v: ListNSView) {
        v.rowHeight = rowHeight
        v.itemCount = itemCount
        v.isRenaming = isRenaming
        v.nameEndX = nameEndX
        v.onClick = onClick
        v.onDoubleClick = onDoubleClick
        v.onEmptyClick = onEmptyClick
        v.onMarqueeUpdate = onMarqueeUpdate
        v.onMarqueeEnd = onMarqueeEnd
        v.makeDragData = makeDragData
        v.dragUTI = dragUTI
        v.selectedRows = selectedRows
        v.isRowSelected = isRowSelected
        v.rowInfo = rowInfo
        v.onKeyArrow = onKeyArrow
        v.onSelectAll = onSelectAll
        v.isRowConverting = isRowConverting
        v.onCancelConversion = onCancelConversion
        v.onRightClick = onRightClick
    }

    class ListNSView: NSView, NSDraggingSource {
        var rowHeight: CGFloat = 22
        var itemCount: Int = 0
        var isRenaming: Bool = false
        var nameEndX: ((Int) -> CGFloat)?
        var onClick: ((Int, CGPoint, NSEvent.ModifierFlags) -> Void)?
        var onDoubleClick: ((Int) -> Void)?
        var onEmptyClick: (() -> Void)?
        var onMarqueeUpdate: ((CGRect) -> Void)?
        var onMarqueeEnd: (() -> Void)?
        var makeDragData: ((Int) -> Data?)?
        var dragUTI: String = ""
        var selectedRows: (() -> [Int])?
        var isRowSelected: ((Int) -> Bool)?
        var rowInfo: ((Int) -> (name: String, path: String, isDirectory: Bool, isLocal: Bool, depth: Int)?)?
        var onKeyArrow: ((UInt16) -> Void)?
        var onSelectAll: (() -> Void)?
        var isRowConverting: ((Int) -> Bool)?
        var onCancelConversion: ((Int) -> Void)?
        var onRightClick: ((Int) -> Void)?

        private var mouseDownLoc: CGPoint = .zero
        private var lastArrowKeyTime: CFAbsoluteTime = 0
        private var isDragging = false
        private var isMarquee = false
        private var deferredClickRow: Int = -1  // mouseUp에서 단일 선택으로 축소할 행
        private var currentMarqueeRect: CGRect = .zero

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard isMarquee, currentMarqueeRect.width > 2 || currentMarqueeRect.height > 2 else { return }
            let accentColor = NSColor.controlAccentColor
            accentColor.withAlphaComponent(0.1).setFill()
            let path = NSBezierPath(rect: currentMarqueeRect)
            path.fill()
            accentColor.withAlphaComponent(0.5).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        private func row(at pt: CGPoint) -> Int {
            let r = Int(pt.y / rowHeight)
            return (r >= 0 && r < itemCount) ? r : -1
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)

            let loc = convert(event.locationInWindow, from: nil)
            mouseDownLoc = loc
            isDragging = false
            isMarquee = false
            deferredClickRow = -1
            let r = row(at: loc)

            // 변환 진행 중인 행 클릭 → 취소 처리 (행 우측 영역)
            if r >= 0, isRowConverting?(r) == true {
                onCancelConversion?(r)
                return
            }

            if event.clickCount == 2 && r >= 0 {
                // 화살표 영역(6 + depth*16 + 14)에서는 더블클릭 무시
                let depth = CGFloat(rowInfo?(r)?.depth ?? 0)
                let arrowEndX: CGFloat = 6 + depth * 16 + 14
                guard loc.x > arrowEndX else { return }
                onDoubleClick?(r)
            } else if r >= 0 {
                let mods = event.modifierFlags
                let alreadySelected = isRowSelected?(r) ?? false
                if alreadySelected && !mods.contains(.command) && !mods.contains(.shift) {
                    // 이미 선택된 항목 클릭 → 드래그 가능하도록 선택 유지, mouseUp에서 축소
                    deferredClickRow = r
                } else {
                    onClick?(r, loc, mods)
                }
            } else {
                onEmptyClick?()
            }
        }

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            // 화살표 키: 126=up, 125=down, 123=left, 124=right
            let key = event.keyCode
            if key == 126 || key == 125 || key == 123 || key == 124 {
                if event.isARepeat {
                    let now = CFAbsoluteTimeGetCurrent()
                    guard now - lastArrowKeyTime >= 0.05 else { return }
                    lastArrowKeyTime = now
                }
                onKeyArrow?(key)
            } else if key == 0 && event.modifierFlags.contains(.command) {
                // Cmd+A: 전체 선택
                onSelectAll?()
            } else {
                super.keyDown(with: event)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            let dx = loc.x - mouseDownLoc.x
            let dy = loc.y - mouseDownLoc.y

            if !isDragging {
                guard sqrt(dx * dx + dy * dy) > 3 else { return }
                isDragging = true
                let r = row(at: mouseDownLoc)
                let endX = r >= 0 ? (nameEndX?(r) ?? 0) : 0
                if r >= 0 && mouseDownLoc.x < endX {
                    // 아이콘+이름 텍스트 위에서 드래그 → 파일 드래그
                    startFileDrag(row: r, event: event)
                    return
                } else {
                    // 빈 공간 → 마키 선택
                    isMarquee = true
                }
            }

            if isMarquee {
                let rect = CGRect(
                    x: min(mouseDownLoc.x, loc.x), y: min(mouseDownLoc.y, loc.y),
                    width: abs(loc.x - mouseDownLoc.x), height: abs(loc.y - mouseDownLoc.y)
                )
                // 마키 사각형: NSView에서 직접 그리기 (setNeedsDisplay만 호출)
                let oldRect = currentMarqueeRect
                currentMarqueeRect = rect
                setNeedsDisplay(oldRect.insetBy(dx: -2, dy: -2))
                setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
                // 선택 업데이트 콜백
                onMarqueeUpdate?(rect)
            }
        }

        override func mouseUp(with event: NSEvent) {
            if isDragging && isMarquee {
                let oldRect = currentMarqueeRect
                currentMarqueeRect = .zero
                setNeedsDisplay(oldRect.insetBy(dx: -2, dy: -2))
                onMarqueeEnd?()
            }
            // 드래그 없이 mouseUp → 지연된 단일 선택 실행
            if !isDragging && deferredClickRow >= 0 {
                let loc = convert(event.locationInWindow, from: nil)
                onClick?(deferredClickRow, loc, event.modifierFlags)
            }
            isDragging = false
            isMarquee = false
            deferredClickRow = -1
        }

        override func hitTest(_ aPoint: NSPoint) -> NSView? {
            // 리네이밍 중이면 해당 행 이벤트를 SwiftUI로 전달
            if isRenaming {
                let row = Int(aPoint.y / rowHeight)
                if row >= 0 && row < itemCount { return nil }
            }
            // 우클릭이면 SwiftUI contextMenu가 처리하도록 nil 반환
            if let event = NSApp.currentEvent, event.type == .rightMouseDown {
                let loc = convert(event.locationInWindow, from: nil)
                let r = row(at: loc)
                if r >= 0, !(isRowSelected?(r) ?? false) {
                    onRightClick?(r)
                }
                return nil
            }
            return super.hitTest(aPoint)
        }

        private func startFileDrag(row: Int, event: NSEvent) {
            guard let data = makeDragData?(row) else { return }

            let rows = selectedRows?() ?? [row]
            let dragRows = rows.isEmpty ? [row] : rows

            // 선택된 파일 정보 수집
            var fileInfos: [(name: String, path: String, isDirectory: Bool)] = []
            var isLocal = false
            for r in dragRows {
                if let info = rowInfo?(r) {
                    fileInfos.append((name: info.name, path: info.path, isDirectory: info.isDirectory))
                    isLocal = info.isLocal
                }
            }
            if fileInfos.isEmpty, let info = rowInfo?(row) {
                fileInfos.append((name: info.name, path: info.path, isDirectory: info.isDirectory))
                isLocal = info.isLocal
            }

            let dragImage = Self.makeDragImage(files: fileInfos)

            var dragItems: [NSDraggingItem] = []

            if isLocal && !fileInfos.isEmpty {
                // 로컬 파일: file URL로 등록하여 Finder와 호환
                for (i, file) in fileInfos.enumerated() {
                    let url = URL(fileURLWithPath: file.path)
                    let pbItem = NSPasteboardItem()
                    // Finder 호환을 위한 fileURL 등록
                    pbItem.setString(url.absoluteString, forType: .fileURL)
                    // 앱 내부 드래그용 커스텀 UTI (첫 번째 아이템에만)
                    if i == 0 {
                        pbItem.setData(data, forType: NSPasteboard.PasteboardType(dragUTI))
                    }
                    let item = NSDraggingItem(pasteboardWriter: pbItem)
                    let imgSize = dragImage.size
                    item.setDraggingFrame(
                        CGRect(x: mouseDownLoc.x - 10,
                               y: mouseDownLoc.y - 10,
                               width: imgSize.width, height: imgSize.height),
                        contents: i == 0 ? dragImage : NSImage()
                    )
                    dragItems.append(item)
                }
            } else {
                // 원격 파일: 커스텀 UTI만 (앱 내부 이동)
                let pbItem = NSPasteboardItem()
                pbItem.setData(data, forType: NSPasteboard.PasteboardType(dragUTI))
                let item = NSDraggingItem(pasteboardWriter: pbItem)
                let imgSize = dragImage.size
                item.setDraggingFrame(
                    CGRect(x: mouseDownLoc.x - 10,
                           y: mouseDownLoc.y - 10,
                           width: imgSize.width, height: imgSize.height),
                    contents: dragImage
                )
                dragItems.append(item)
            }

            beginDraggingSession(with: dragItems, event: event, source: self)
        }

        /// Finder 스타일 드래그 이미지: 아이콘 + 파일명 목록 + 개수 배지
        private static func makeDragImage(files: [(name: String, path: String, isDirectory: Bool)]) -> NSImage {
            let rowH: CGFloat = 22
            let iconSz: CGFloat = 16
            let maxRows = min(files.count, 10)
            let nameFont = NSFont.systemFont(ofSize: 12)
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: nameFont,
                .foregroundColor: NSColor.labelColor
            ]

            // 최대 텍스트 너비 계산
            var maxTextW: CGFloat = 0
            for i in 0..<maxRows {
                let w = (files[i].name as NSString).size(withAttributes: nameAttrs).width
                if w > maxTextW { maxTextW = w }
            }
            maxTextW = min(maxTextW, 250)

            let totalW: CGFloat = 6 + iconSz + 6 + maxTextW + 12
            let totalH: CGFloat = CGFloat(maxRows) * rowH + 2

            let img = NSImage(size: NSSize(width: totalW, height: totalH))
            img.lockFocus()

            // 반투명 배경
            let bgPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: totalW, height: totalH),
                                       xRadius: 6, yRadius: 6)
            NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 0.9) : NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 0.9) }.setFill()
            bgPath.fill()
            NSColor.separatorColor.setStroke()
            bgPath.lineWidth = 0.5
            bgPath.stroke()

            // 각 행 그리기 (NSImage는 좌하→우상 좌표, 그래서 뒤집어서 그림)
            for i in 0..<maxRows {
                let file = files[i]
                let y = totalH - CGFloat(i + 1) * rowH

                // 시스템 파일 아이콘
                let fileIcon: NSImage
                if file.isDirectory {
                    fileIcon = NSWorkspace.shared.icon(for: .folder)
                } else {
                    let ext = (file.name as NSString).pathExtension.lowercased()
                    if let utType = UTType(filenameExtension: ext) {
                        fileIcon = NSWorkspace.shared.icon(for: utType)
                    } else {
                        fileIcon = NSWorkspace.shared.icon(for: .data)
                    }
                }
                fileIcon.size = NSSize(width: iconSz, height: iconSz)
                let iconY = y + (rowH - iconSz) / 2
                fileIcon.draw(in: NSRect(x: 6, y: iconY, width: iconSz, height: iconSz),
                              from: .zero, operation: .sourceOver, fraction: 1.0)

                // 파일명
                let textY = y + (rowH - nameFont.pointSize - 2) / 2
                let textRect = NSRect(x: 6 + iconSz + 6, y: textY,
                                       width: maxTextW + 4, height: rowH)
                (file.name as NSString).draw(in: textRect, withAttributes: nameAttrs)
            }

            // 개수 배지 (2개 이상일 때)
            if files.count > 1 {
                let badgeText = "\(files.count)" as NSString
                let badgeFont = NSFont.boldSystemFont(ofSize: 10)
                let badgeAttrs: [NSAttributedString.Key: Any] = [
                    .font: badgeFont,
                    .foregroundColor: NSColor.white
                ]
                let textSize = badgeText.size(withAttributes: badgeAttrs)
                let badgeW = max(textSize.width + 8, 18)
                let badgeH: CGFloat = 16
                let badgeX = totalW - badgeW - 4
                let badgeY = totalH - badgeH - 3

                let badgeRect = NSRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
                let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: badgeH / 2, yRadius: badgeH / 2)
                NSColor.controlAccentColor.setFill()
                badgePath.fill()

                let txtRect = NSRect(x: badgeX + (badgeW - textSize.width) / 2,
                                      y: badgeY + (badgeH - textSize.height) / 2,
                                      width: textSize.width, height: textSize.height)
                badgeText.draw(in: txtRect, withAttributes: badgeAttrs)
            }

            img.unlockFocus()
            return img
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : .copy
        }
    }
}

// MARK: - Selected icon frame (QuickLook zoom animation)

struct SelectedIconFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Column Divider (drag to resize)

private struct ColumnDivider: View {
    @Binding var width: Double
    let minW: CGFloat
    @State private var startWidth: Double = 0

    var body: some View {
        Color(white: 0.3)
            .frame(width: 1, height: 14)
            .padding(.horizontal, 2)
            .frame(width: 5, height: 22)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if startWidth == 0 { startWidth = width }
                        width = max(Double(minW), startWidth + value.translation.width)
                    }
                    .onEnded { _ in startWidth = 0 }
            )
    }
}

// MARK: - File Icon (system icon / thumbnail)

private struct FileIconView: View {
    let path: String
    let isDirectory: Bool
    var size: CGFloat = 16
    @State private var thumbnail: NSImage?

    var body: some View {
        Group {
            if let thumb = thumbnail ?? IconCache.shared.cachedThumbnail(forPath: path) {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: IconCache.shared.icon(forPath: path, isDirectory: isDirectory))
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: thumbnail != nil ? 2 : 0))
        .onAppear {
            guard !isDirectory,
                  IconCache.shared.hasThumbnailSupport(path),
                  IconCache.shared.cachedThumbnail(forPath: path) == nil else { return }
            IconCache.shared.requestThumbnail(forPath: path, size: size) { img in
                thumbnail = img
            }
        }
    }
}

// MARK: - Cmd+Delete key handler

private struct DeleteKeyHandler: NSViewRepresentable {
    let onDelete: () -> Void

    func makeNSView(context: Context) -> DeleteKeyView {
        let view = DeleteKeyView()
        view.onDelete = onDelete
        return view
    }

    func updateNSView(_ nsView: DeleteKeyView, context: Context) {
        nsView.onDelete = onDelete
    }

    class DeleteKeyView: NSView {
        var onDelete: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 51 && event.modifierFlags.contains(.command) {
                onDelete?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

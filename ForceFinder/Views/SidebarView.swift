//
//  SidebarView.swift
//  ForceFinder
//

import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var app: AppState
    let onNavigate: (String) -> Void
    var onEditConnection: ((Connection) -> Void)? = nil

    private let goldTint = Color.accentTint
    private let transmitPink = Color(red: 0.78, green: 0.28, blue: 0.51)
    private var activeBg: Color { transmitPink.opacity(0.15) }
    @State private var favDropIndex: Int? = nil
    @State private var favDragSourceId: UUID? = nil  // 내부 재정렬 시 드래그 중인 항목

    private func isConnectionOpen(_ c: Connection) -> Bool {
        let lc = app.leftPane.connection
        let rc = app.rightPane.connection
        return (lc.host == c.host && lc.proto == c.proto && lc.username == c.username)
            || (rc.host == c.host && rc.proto == c.proto && rc.username == c.username)
    }

    private func isFavoriteOpen(_ path: String) -> Bool {
        (app.leftPane.connection.proto == .local && app.leftPane.currentPath == path)
        || (app.rightPane.connection.proto == .local && app.rightPane.currentPath == path)
    }

    private var isLocalOpen: Bool {
        app.leftPane.connection.proto == .local || app.rightPane.connection.proto == .local
    }

    var body: some View {
        List {
            // MARK: - Devices
            Section {
                sidebarButton(icon: "externaldrive.fill", tint: goldTint,
                              label: Host.current().localizedName ?? "Mac",
                              trailing: diskSpace()) {
                    onNavigate(NSHomeDirectory())
                }
                .listRowBackground(isLocalOpen ? activeBg : Color.clear)
            } header: {
                sectionHeader("Devices")
            }

            // MARK: - Connections
            if !app.recentConnections.isEmpty {
                Section {
                    ForEach(app.recentConnections) { c in
                        sidebarButton(icon: protoIcon(c.proto), tint: goldTint,
                                      label: c.name,
                                      trailing: c.proto.displayName) {
                            connectRecent(c)
                        }
                        .listRowBackground(isConnectionOpen(c) ? activeBg : Color.clear)
                        .contextMenu {
                            Button("연결") { connectRecent(c) }
                            Button("수정 후 연결...") { onEditConnection?(c) }
                            Divider()
                            Button("삭제", role: .destructive) {
                                app.recentConnections.removeAll { $0.id == c.id }
                            }
                        }
                    }
                } header: {
                    sectionHeader("Recent")
                }
            }


            // MARK: - Tags
            Section {
                ForEach(app.sidebarTags) { tag in
                    let activePane = app.pane(app.activeSide)
                    let isActive = activePane.tagFilter == tag.colorName
                    Button {
                        filterByTag(tag)
                    } label: {
                        Label {
                            Text(tag.name)
                                .fontWeight(isActive ? .semibold : .regular)
                        } icon: {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 10, height: 10)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, -5)
                }
            } header: {
                sectionHeader("Tags")
            }

            // MARK: - Favorites
            Section {
                ForEach(Array(app.sidebarFavorites.enumerated()), id: \.element.id) { idx, fav in
                    sidebarButton(icon: fav.icon, tint: goldTint,
                                  label: fav.name,
                                  trailing: fav.isLocal ? nil : fav.connection?.name) {
                        if fav.isLocal {
                            onNavigate(fav.path)
                        } else if let conn = fav.connection {
                            connectFavorite(conn, path: fav.path)
                        }
                    }
                    .opacity(favDragSourceId == fav.id ? 0.3 : 1.0)
                    .overlay(alignment: .top) {
                        if favDropIndex == idx {
                            favDropIndicator
                        }
                    }
                    .onDrag {
                        favDragSourceId = fav.id
                        return NSItemProvider(object: fav.id.uuidString as NSString)
                    }
                    .onDrop(of: [.fileURL, UTType.transmitLiteItem, .plainText],
                            delegate: FavDropDelegate(
                                index: idx,
                                dropIndex: $favDropIndex,
                                dragSourceId: $favDragSourceId,
                                favorites: $app.sidebarFavorites,
                                onExternalDrop: { providers, insertAt in
                                    handleFavoriteDrop(providers, at: insertAt)
                                },
                                onSaveFavorites: { app.saveFavorites() }))
                    .listRowBackground(isFavoriteOpen(fav.path) ? activeBg : Color.clear)
                    .contextMenu {
                        Button("즐겨찾기에서 제거", role: .destructive) {
                            app.sidebarFavorites.removeAll { $0.id == fav.id }
                            app.saveFavorites()
                        }
                    }
                }

                // 마지막 행 뒤 드롭 영역
                Color.clear.frame(height: 20)
                    .overlay(alignment: .top) {
                        if favDropIndex == app.sidebarFavorites.count {
                            favDropIndicator
                        }
                    }
                .listRowBackground(Color.clear)
                .onDrop(of: [.fileURL, UTType.transmitLiteItem, .plainText],
                        delegate: FavDropDelegate(
                            index: app.sidebarFavorites.count,
                            dropIndex: $favDropIndex,
                            dragSourceId: $favDragSourceId,
                            favorites: $app.sidebarFavorites,
                            onExternalDrop: { providers, insertAt in
                                handleFavoriteDrop(providers, at: insertAt)
                            },
                            onSaveFavorites: { app.saveFavorites() }))
            } header: {
                sectionHeader("Favorites")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 2) {
                Text(appVersion)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(buildDate)
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    private var appVersion: String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "ForceFinder v\(ver) (\(build))"
    }

    private var buildDate: String {
        if let execURL = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
           let date = attrs[.modificationDate] as? Date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return "Built: \(f.string(from: date))"
        }
        return ""
    }

    // MARK: - Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }

    private var favDropIndicator: some View {
        HStack(spacing: 0) {
            Circle()
                .stroke(transmitPink, lineWidth: 2)
                .frame(width: 8, height: 8)
            Rectangle()
                .fill(transmitPink)
                .frame(height: 2)
        }
        .padding(.leading, -6)
        .padding(.trailing, 4)
        .offset(y: -7)
    }

    @ViewBuilder
    private func sidebarButton(icon: String, tint: Color,
                                label: String, trailing: String?,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                HStack {
                    Text(label)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let t = trailing {
                        Text(t)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, -5)
    }

    // MARK: - Helpers

    private func diskSpace() -> String {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let free = attrs[.systemFreeSize] as? Int64 else { return "" }
        let fgb = String(format: "%.2f", Double(free) / 1_073_741_824.0)
        return "\(fgb) GB"
    }

    private func protoIcon(_ p: TransferProtocol) -> String {
        switch p {
        case .local: return "internaldrive"
        case .sftp:  return "lock.shield"
        case .ftp:   return "network"
        case .ftps:  return "lock.fill"
        case .webdav: return "globe"
        case .s3:    return "cube.box"
        case .smb:   return "server.rack"
        case .googleDrive: return "icloud"
        }
    }

    private func filterByTag(_ tag: SidebarTag) {
        let pane = app.pane(app.activeSide)
        if pane.tagFilter == tag.colorName {
            // 이미 같은 태그 → 필터 해제
            pane.tagFilter = nil
        } else {
            pane.tagFilter = tag.colorName
            if pane.connection.proto == .local {
                // 로컬: Spotlight로 태그된 파일 검색
                let searchPath = pane.currentPath
                Task {
                    let paths = await FileService.shared.findFilesWithTag(
                        colorName: tag.colorName, inPath: searchPath)
                    let fm = FileManager.default
                    var items: [RemoteItem] = []
                    for path in paths {
                        do {
                            let attrs = try fm.attributesOfItem(atPath: path)
                            let fileType = attrs[.type] as? FileAttributeType
                            let isDir = fileType == .typeDirectory
                            let size = (attrs[.size] as? Int64) ?? 0
                            let modified = (attrs[.modificationDate] as? Date) ?? Date()
                            let posix = (attrs[.posixPermissions] as? Int) ?? 0o644
                            let owner = (attrs[.ownerAccountName] as? String) ?? ""
                            let group = (attrs[.groupOwnerAccountName] as? String) ?? ""
                            let perms = Self.formatPosix(posix, isDir: isDir)
                            items.append(RemoteItem(
                                name: (path as NSString).lastPathComponent,
                                isDirectory: isDir, size: size, modified: modified,
                                permissions: perms, owner: owner, group: group,
                                tagColorName: tag.colorName,
                                fullPath: path))
                        } catch { continue }
                    }
                    await MainActor.run {
                        pane.items = items
                    }
                }
            } else {
                // 서버: TagStore에서 태그된 파일 경로 조회
                let taggedPaths = TagStore.shared.paths(
                    connection: pane.connection, colorName: tag.colorName)
                // 현재 로드된 아이템 중 태그된 것만 필터
                let currentPath = pane.currentPath
                let filtered = pane.items.filter { item in
                    let fullPath = (currentPath as NSString).appendingPathComponent(item.name)
                    return taggedPaths.contains(fullPath)
                }
                if filtered.isEmpty {
                    // 현재 디렉토리에 없으면 전체 태그된 경로로 가상 목록 생성
                    var items: [RemoteItem] = []
                    for path in taggedPaths {
                        let name = (path as NSString).lastPathComponent
                        let isDir = TagStore.shared.isDirectory(
                            connection: pane.connection, path: path)
                        items.append(RemoteItem(
                            name: name, isDirectory: isDir,
                            size: 0, modified: Date(),
                            permissions: isDir ? "drwxr-xr-x" : "-rw-r--r--",
                            owner: pane.connection.username, group: "",
                            tagColorName: tag.colorName,
                            fullPath: path))
                    }
                    pane.items = items
                } else {
                    pane.items = filtered
                }
            }
        }
    }

    private static func formatPosix(_ posix: Int, isDir: Bool) -> String {
        let head = isDir ? "d" : "-"
        var s = head
        for shift in stride(from: 6, through: 0, by: -3) {
            let bits = (posix >> shift) & 0x7
            s += (bits & 4 != 0) ? "r" : "-"
            s += (bits & 2 != 0) ? "w" : "-"
            s += (bits & 1 != 0) ? "x" : "-"
        }
        return s
    }

    private func handleFavoriteDrop(_ providers: [NSItemProvider], at insertIndex: Int) -> Bool {
        let insertAt = min(insertIndex, app.sidebarFavorites.count)
        var added = false
        for provider in providers {
            // 내부 드래그 (앱 파인더에서 폴더 드래그)
            if provider.hasItemConformingToTypeIdentifier(UTType.transmitLiteItem.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.transmitLiteItem.identifier) { data, _ in
                    guard let data = data else { return }
                    let items: [DragItem]
                    if let arr = try? JSONDecoder().decode([DragItem].self, from: data) {
                        items = arr
                    } else if let single = try? JSONDecoder().decode(DragItem.self, from: data) {
                        items = [single]
                    } else { return }
                    for item in items where item.isDirectory {
                        let path = item.sourcePath
                        guard !app.sidebarFavorites.contains(where: { $0.path == path && $0.isLocal == (app.pane(item.sourceSide == "left" ? .left : .right).connection.proto == .local) }) else { continue }
                        let side: PaneSide = item.sourceSide == "left" ? .left : .right
                        let pane = app.pane(side)
                        let isLocal = pane.connection.proto == .local
                        let conn: Connection? = isLocal ? nil : pane.connection
                        let icon = isLocal ? "folder" : "folder.badge.gearshape"
                        let fav = SidebarFavorite(name: item.name, path: path,
                                                  icon: icon, isLocal: isLocal,
                                                  connection: conn)
                        DispatchQueue.main.async {
                            let idx = min(insertAt, app.sidebarFavorites.count)
                            app.sidebarFavorites.insert(fav, at: idx)
                            app.saveFavorites()
                        }
                    }
                }
                added = true
                continue
            }
            // 외부 드래그 (Finder에서 폴더 드래그)
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.hasDirectoryPath else { return }
                let path = url.path
                guard !app.sidebarFavorites.contains(where: { $0.path == path && $0.isLocal }) else { return }
                let name = url.lastPathComponent
                let fav = SidebarFavorite(name: name, path: path, icon: "folder")
                DispatchQueue.main.async {
                    let idx = min(insertAt, app.sidebarFavorites.count)
                    app.sidebarFavorites.insert(fav, at: idx)
                    app.saveFavorites()
                }
            }
            added = true
        }
        return added
    }

    private func connectRecent(_ c: Connection) {
        let side = app.activeSide
        let pane = PaneState(side: side, connection: c)
        pane.isConnected = true
        app.setPane(side, to: pane)
        Task {
            do {
                let items = try await FileService.shared.list(connection: c, path: c.remotePath)
                await MainActor.run { pane.items = items; pane.isLoading = false }
                app.appendLog(.ok, "연결됨: \(c.name)")
            } catch {
                app.appendLog(.error, "연결 실패: \(error.localizedDescription)")
            }
        }
    }

    /// 서버 즐겨찾기: 연결 후 지정 경로로 이동
    private func connectFavorite(_ c: Connection, path: String) {
        let side = app.activeSide
        let pane = PaneState(side: side, connection: c)
        pane.isConnected = true
        pane.currentPath = path
        app.setPane(side, to: pane)
        Task {
            do {
                let items = try await FileService.shared.list(connection: c, path: path)
                await MainActor.run { pane.items = items; pane.isLoading = false }
                app.appendLog(.ok, "연결됨: \(c.name) → \(path)")
            } catch {
                app.appendLog(.error, "연결 실패: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Favorites Drop Delegate

struct FavDropDelegate: DropDelegate {
    let index: Int
    @Binding var dropIndex: Int?
    @Binding var dragSourceId: UUID?
    @Binding var favorites: [SidebarFavorite]
    let onExternalDrop: ([NSItemProvider], Int) -> Bool
    let onSaveFavorites: () -> Void

    private var isInternalReorder: Bool {
        dragSourceId != nil
    }

    func dropEntered(info: DropInfo) {
        withAnimation(.easeInOut(duration: 0.15)) {
            dropIndex = index
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: isInternalReorder ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if dropIndex == index {
                withAnimation(.easeInOut(duration: 0.15)) {
                    dropIndex = nil
                }
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dropIndex = nil
            dragSourceId = nil
        }

        // 내부 재정렬
        if let sourceId = dragSourceId,
           let fromIndex = favorites.firstIndex(where: { $0.id == sourceId }) {
            var toIndex = index
            if fromIndex < toIndex { toIndex -= 1 }
            toIndex = max(0, min(toIndex, favorites.count - 1))
            guard fromIndex != toIndex else { return false }
            withAnimation(.easeInOut(duration: 0.2)) {
                favorites.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: index > fromIndex ? index : index)
            }
            onSaveFavorites()
            return true
        }

        // 외부 드롭
        let providers = info.itemProviders(for: [.fileURL, UTType.transmitLiteItem])
        return onExternalDrop(providers, index)
    }

    func validateDrop(info: DropInfo) -> Bool {
        isInternalReorder || info.hasItemsConforming(to: [.fileURL, UTType.transmitLiteItem])
    }
}

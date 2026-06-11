//
//  ContentView.swift
//  ForceFTP
//

import SwiftUI
import Quartz

// MARK: - Double ↔ CGFloat Binding 변환
extension Binding where Value == Double {
    var cgFloat: Binding<CGFloat> {
        Binding<CGFloat>(
            get: { CGFloat(self.wrappedValue) },
            set: { self.wrappedValue = Double($0) }
        )
    }
}

struct ContentView: View {
    @StateObject private var app = AppState()
    @EnvironmentObject var transfers: TransferManager

    @State private var showConnect = false
    @State private var connectSide: PaneSide = .left
    @State private var editingConnection: Connection? = nil
    @State private var infoItem: RemoteItem?
    @State private var infoSide: PaneSide = .left
    @State private var infoAnimating = false
    @State private var infoSourceFrame: CGRect = .zero
    @AppStorage("layout.showTransfers") private var showTransfers = false
    @AppStorage("layout.showInspector") private var showInspector = true
    @AppStorage("layout.inspectorWidth") private var inspectorWidth: Double = 280
    /// 0~1 비율 (왼쪽 파인더가 차지하는 비율)
    @AppStorage("layout.leftPaneRatio") private var leftPaneRatio: Double = 0.5
    @State private var search = ""
    @State private var spacebarMonitor: Any?
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showFDAAlert = false
    @AppStorage("layout.transferPanelHeight") private var savedTransferPanelHeight: Double = 120
    @State private var transferPanelHeight: CGFloat = 120

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(onNavigate: { path in
                let side = app.activeSide
                let currentPane = app.pane(side)
                // If currently on a remote connection, switch back to local
                if currentPane.connection.proto != .local {
                    let localConn = Connection.localPlaceholder
                    let newPane = PaneState(side: side, connection: localConn)
                    newPane.navigate(to: path)
                    newPane.isConnected = true
                    app.setPane(side, to: newPane)
                    app.saveLastPaneState()
                    Task { await reloadPane(newPane) }
                } else {
                    currentPane.navigate(to: path)
                    Task { await reloadPane(currentPane) }
                }
            }, onEditConnection: { c in
                editingConnection = c
                connectSide = app.activeSide
                showConnect = true
            })
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            HStack(spacing: 0) {
                // Main content
                VStack(spacing: 0) {
                    // Dual pane area
                    GeometryReader { geo in
                        let totalW = geo.size.width
                        let centerW: CGFloat = 46
                        let paneArea = totalW - centerW
                        let leftW = paneArea * leftPaneRatio
                        let rightW = paneArea - leftW
                        HStack(spacing: 0) {
                            PaneView(side: .left,
                                     onConnect: { connectSide = .left; showConnect = true },
                                     onInfo: { item in showInfoModal(side: .left, item: item) })
                                .frame(width: leftW, alignment: .leading)
                                .clipped()

                            centerArrowButtons

                            PaneView(side: .right,
                                     onConnect: { connectSide = .right; showConnect = true },
                                     onInfo: { item in showInfoModal(side: .right, item: item) })
                                .frame(width: rightW, alignment: .leading)
                                .clipped()
                        }
                    }

                    // Bottom: transfer panel + status bar
                    if showTransfers {
                        ResizableDivider(dimension: $transferPanelHeight, edge: .top,
                                         minSize: 60, maxSize: 400,
                                         onDragEnd: { savedTransferPanelHeight = Double(transferPanelHeight) })
                        TransferPanel()
                            .frame(height: transferPanelHeight)
                    }
                    Divider()
                    StatusBar(showTransfers: $showTransfers)
                }

                // Inspector panel (right side, resizable)
                if showInspector {
                    inspectorPanel
                        .frame(width: inspectorWidth)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.leading, 6)
                }
            }
        }
        .environmentObject(app)
        .navigationTitle(activeFolderName)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { goBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!app.pane(app.activeSide).canGoBack)
                .help("뒤로")

                Button { goForward() } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!app.pane(app.activeSide).canGoForward)
                .help("앞으로")
            }


            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Section("연결 목록") {
                        ForEach(app.savedConnections) { c in
                            Menu {
                                Button("연결") { connectFromRecent(c) }
                                Button("수정 후 연결...") {
                                    editingConnection = c
                                    connectSide = app.activeSide
                                    showConnect = true
                                }
                                Divider()
                                Button("삭제", role: .destructive) {
                                    app.removeSavedConnection(c)
                                }
                            } label: {
                                Label("\(c.username)@\(c.host)", systemImage: protoIcon(c.proto))
                            } primaryAction: {
                                connectFromRecent(c)
                            }
                        }
                    }
                    Divider()
                    Button("새 연결...") {
                        editingConnection = nil
                        connectSide = app.activeSide; showConnect = true
                    }
                } label: {
                    Image(systemName: "bolt.horizontal.fill")
                }
                .help("서버 연결")

                Button { refresh(app.activeSide) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("새로고침")

                Button { performAction(.newFolder) } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("새 폴더")

                Button { openInfoForActive() } label: {
                    Image(systemName: "info.circle")
                }
                .help("정보")

                Button { performAction(.delete) } label: {
                    Image(systemName: "trash")
                }
                .help("삭제")

                Divider()

                Button {
                    app.showHiddenFiles.toggle()
                } label: {
                    Image(systemName: app.showHiddenFiles ? "eye" : "eye.slash")
                }
                .help(app.showHiddenFiles ? "숨김 파일 감추기" : "숨김 파일 보기")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showInspector.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("인스펙터")
            }

            ToolbarItemGroup(placement: .automatic) {
                Spacer()
                TextField("검색", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit { performSearch() }
                    .onChange(of: search) { _, newValue in
                        if newValue.isEmpty { clearSearch() }
                    }
            }
        }
        .sheet(isPresented: $showConnect) {
            ConnectSheet(side: connectSide, isPresented: $showConnect,
                         editConnection: editingConnection)
            .environmentObject(app)
        }
        .onChange(of: showConnect) { _, showing in
            if !showing { editingConnection = nil }
        }
        .onChange(of: transfers.transferLogs.count) { _, _ in
            if !showTransfers { withAnimation(.easeInOut(duration: 0.2)) { showTransfers = true } }
        }
        .onChange(of: transfers.transfers.count) { _, _ in
            if !showTransfers { withAnimation(.easeInOut(duration: 0.2)) { showTransfers = true } }
        }
        .onChange(of: app.pane(app.activeSide).selection) { _, _ in
            scheduleInspectorUpdate()
        }
        .onChange(of: app.activeSide) { _, _ in
            scheduleInspectorUpdate()
        }
        .overlay {
            if let it = infoItem {
                infoOverlay(item: it)
            }
        }
        .overlay(alignment: .top) {
            ToastOverlay(toasts: app.toasts, onDismiss: { app.removeToast($0) })
        }
        .onAppear {
            transferPanelHeight = CGFloat(savedTransferPanelHeight)
            initialLoad()
            setupSpacebarMonitor()
            setupTransferCallback()
            checkFullDiskAccess()
        }
        .alert("전체 디스크 접근 권한 필요", isPresented: $showFDAAlert) {
            Button("시스템 설정 열기") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
                UserDefaults.standard.set(true, forKey: "TL.fdaPrompted")
            }
            Button("나중에", role: .cancel) {
                UserDefaults.standard.set(true, forKey: "TL.fdaPrompted")
            }
        } message: {
            Text("파일 관리를 위해 전체 디스크 접근 권한이 필요합니다.\n시스템 설정 > 개인정보 보호 > 전체 디스크 접근에서 ForceFTP를 추가해 주세요.")
        }
        .onDisappear {
            app.saveLastPaneState()
            if let monitor = spacebarMonitor {
                NSEvent.removeMonitor(monitor)
                spacebarMonitor = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            app.saveLastPaneState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openConnect)) { _ in
            connectSide = app.activeSide; showConnect = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .disconnect)) { _ in disconnectActive() }
        .onReceive(NotificationCenter.default.publisher(for: .upload))   { _ in performAction(.upload) }
        .onReceive(NotificationCenter.default.publisher(for: .download)) { _ in performAction(.download) }
        .onReceive(NotificationCenter.default.publisher(for: .refresh))  { _ in refresh(app.activeSide) }
        .onReceive(NotificationCenter.default.publisher(for: .getInfo))  { _ in openInfoForActive() }
        .modifier(FileNotificationHandlers(
            onCopy: handleFileCopy, onPaste: handleFilePaste, onUndo: fileUndo,
            onCopyPath: copySelectedPaths, onDelete: fileDelete, onPermanentDelete: filePermanentDelete
        ))
    }

    // MARK: - Center Arrow Buttons

    private var centerArrowButtons: some View {
        let leftCount = app.leftPane.selection.count
        let rightCount = app.rightPane.selection.count
        return VStack(spacing: 4) {
            Spacer()

            // 선택 개수 (→ 방향)
            if leftCount > 0 {
                Text("\(leftCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(y: -0.5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color(red: 0.78, green: 0.28, blue: 0.51))
                    .clipShape(Capsule())
            }

            VStack(spacing: 8) {
                Button { moveSelectedFiles(from: .left, to: .right) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(leftCount > 0 ? Color(red: 0.76, green: 0.60, blue: 0.20) : .secondary)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .stroke(leftCount > 0 ? Color(red: 0.76, green: 0.60, blue: 0.20) : Color(NSColor.separatorColor), lineWidth: 1.5)
                        )
                        .contentShape(Circle())
                }
                .help("오른쪽으로 이동")
                .disabled(leftCount == 0)

                Button { moveSelectedFiles(from: .right, to: .left) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(rightCount > 0 ? Color(red: 0.76, green: 0.60, blue: 0.20) : .secondary)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .stroke(rightCount > 0 ? Color(red: 0.76, green: 0.60, blue: 0.20) : Color(NSColor.separatorColor), lineWidth: 1.5)
                        )
                        .contentShape(Circle())
                }
                .help("왼쪽으로 이동")
                .disabled(rightCount == 0)
            }
            .buttonStyle(.borderless)

            // 선택 개수 (← 방향)
            if rightCount > 0 {
                Text("\(rightCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(y: -0.5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color(red: 0.78, green: 0.28, blue: 0.51))
                    .clipShape(Capsule())
            }

            Spacer()
        }
        .frame(width: 46)
        .overlay {
            // 양쪽 가장자리에 드래그 핸들
            HStack(spacing: 0) {
                paneResizeHandle
                Spacer()
                paneResizeHandle
            }
        }
    }

    private var paneResizeHandle: some View {
        PaneResizeHandleView(ratio: $leftPaneRatio.cgFloat)
            .frame(width: 6)
    }

    // MARK: - Inspector

    @State private var debouncedInspectorItems: [RemoteItem] = []
    @State private var inspectorDebounceTask: Task<Void, Never>?

    @ViewBuilder
    private var inspectorPanel: some View {
        let pane = app.pane(app.activeSide)
        if pane.isMarqueeSelecting {
            // 마키 선택 중: 인스펙터 갱신 중단 (이전 상태 유지)
            Color.clear
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
                .background(Color(red: 0.16, green: 0.16, blue: 0.17))
        } else if debouncedInspectorItems.count > 1 {
            MultiInspectorView(items: debouncedInspectorItems, side: app.activeSide)
        } else if let selectedItem = debouncedInspectorItems.first {
            InspectorView(item: selectedItem, side: app.activeSide)
        } else {
            VStack {
                Spacer()
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(.quaternary)
                Text("파일을 선택하세요")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                Spacer()
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
            .background(Color(red: 0.16, green: 0.16, blue: 0.17))
        }
    }

    private func scheduleInspectorUpdate() {
        inspectorDebounceTask?.cancel()
        inspectorDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let pane = app.pane(app.activeSide)
            debouncedInspectorItems = pane.selectedItems
        }
    }

    // MARK: - Computed

    private var activeFolderName: String {
        let p = app.pane(app.activeSide).currentPath
        let name = (p as NSString).lastPathComponent
        return name.isEmpty ? "/" : name
    }

    // MARK: - Navigation

    private func goBack() {
        let pane = app.pane(app.activeSide)
        pane.goBack()
        Task { await reloadPane(pane) }
    }

    private func goForward() {
        let pane = app.pane(app.activeSide)
        pane.goForward()
        Task { await reloadPane(pane) }
    }

    // MARK: - Actions

    /// 타겟 패널의 대상 경로와 해당 폴더 아이템 (있으면)
    /// - 폴더 1개 선택: 그 폴더 안
    /// - 파일 선택 (펼쳐진 하위): 그 파일의 부모 폴더
    /// - 그 외: 현재 경로
    private func targetInfo(of pane: PaneState) -> (path: String, folder: RemoteItem?) {
        let sel = pane.selectedItems
        guard !sel.isEmpty else { return (pane.currentPath, nil) }

        let folders = sel.filter { $0.isDirectory }
        if folders.count == 1, let folder = folders.first {
            let parentDir = pane.parentPath(for: folder.id)
            return ((parentDir as NSString).appendingPathComponent(folder.name), folder)
        }

        // 선택 항목의 부모 경로 확인 (펼쳐진 하위 폴더 안의 항목인지)
        if let first = sel.first {
            let parentDir = pane.parentPath(for: first.id)
            if parentDir != pane.currentPath {
                // 하위 폴더 안의 항목 → 그 부모 폴더로
                if let parentFolder = pane.allItems.first(where: {
                    $0.isDirectory && pane.expandedFolders.contains($0.id) &&
                    (pane.parentPath(for: $0.id) as NSString)
                        .appendingPathComponent($0.name) == parentDir
                }) {
                    return (parentDir, parentFolder)
                }
                return (parentDir, nil)
            }
        }

        return (pane.currentPath, nil)
    }

    private func targetPath(of pane: PaneState) -> String {
        targetInfo(of: pane).path
    }

    private func targetFolder(of pane: PaneState) -> RemoteItem? {
        targetInfo(of: pane).folder
    }

    /// 로그용 경로 문자열: 서버면 host:path, 로컬이면 path만
    private func logPath(_ conn: Connection, _ path: String) -> String {
        conn.proto == .local ? path : "\(conn.host):\(path)"
    }

    /// 전송 완료 후 타겟 패널 갱신: 선택된 폴더면 하위만 리로드+펼치기, 아니면 전체 리로드
    private func reloadTarget(_ pane: PaneState) async {
        if let folder = targetFolder(of: pane) {
            let folderPath = targetPath(of: pane)
            do {
                let children = try await FileService.shared.list(
                    connection: pane.connection, path: folderPath)
                await MainActor.run {
                    pane.expandedFolders.insert(folder.id)
                    pane.childrenCache[folder.id] = children
                }
            } catch {
                app.appendLog(.error, "폴더 갱신 실패: \(folder.name)")
            }
        } else {
            await reloadPane(pane)
        }
    }

    /// 특정 경로의 폴더만 갱신 (리플래시 없이)
    private func reloadFolder(pane: PaneState, path: String) async {
        if path == pane.currentPath {
            // 루트 경로: items 갱신
            do {
                let items = try await FileService.shared.list(
                    connection: pane.connection, path: path)
                await MainActor.run {
                    pane.items = items
                    let validIDs = Set(pane.allItems.map(\.id))
                    pane.selection = pane.selection.intersection(validIDs)
                }
            } catch {
                app.appendLog(.error, "폴더 갱신 실패: \(path)")
            }
        } else if let folder = pane.allItems.first(where: {
            $0.isDirectory && pane.expandedFolders.contains($0.id) &&
            (pane.parentPath(for: $0.id) as NSString).appendingPathComponent($0.name) == path
        }) {
            // 펼쳐진 하위 폴더: childrenCache만 갱신
            do {
                let children = try await FileService.shared.list(
                    connection: pane.connection, path: path)
                await MainActor.run {
                    pane.childrenCache[folder.id] = children
                }
            } catch {
                app.appendLog(.error, "폴더 갱신 실패: \(folder.name)")
            }
        }
    }

    private enum PaneAction { case upload, download, newFolder, delete }

    private func performAction(_ action: PaneAction) {
        let pane = app.pane(app.activeSide)
        let other = app.pane(app.activeSide.opposite)

        switch action {
        case .upload:
            let sourcePane = pane.connection.proto == .local ? pane : other
            let targetPane = pane.connection.proto == .local ? other : pane
            guard targetPane.connection.proto != .local else {
                app.appendLog(.warn, "업로드: 반대편 패널을 원격 서버에 연결하세요."); return
            }
            let files = sourcePane.selectedItems
            guard !files.isEmpty else {
                app.appendLog(.warn, "업로드할 파일을 선택하세요."); return
            }
            let destDir = targetPath(of: targetPane)
            let names = files.map(\.name).joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = "업로드 확인"
            alert.informativeText = "\(files.count)개 항목을 \(destDir) 로 업로드하시겠습니까?\n\(names)"
            alert.addButton(withTitle: "업로드")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            for f in files {
                let srcDir = sourcePane.parentPath(for: f.id)
                let src = (srcDir as NSString).appendingPathComponent(f.name)
                let dst = (destDir as NSString).appendingPathComponent(f.name)
                let size = f.isDirectory
                    ? FileService.localDirectorySize(path: src)
                    : f.size
                transfers.enqueue(Transfer(name: f.name, sourcePath: src, destinationPath: dst,
                                           direction: .upload, totalBytes: size,
                                           source: sourcePane.connection, dest: targetPane.connection,
                                           isDirectory: f.isDirectory))
            }

        case .download:
            let sourcePane = pane.connection.proto != .local ? pane : other
            let targetPane = pane.connection.proto != .local ? other : pane
            guard sourcePane.connection.proto != .local else {
                app.appendLog(.warn, "다운로드: 한쪽 패널을 원격 서버에 연결하세요."); return
            }
            let files = sourcePane.selectedItems
            guard !files.isEmpty else {
                app.appendLog(.warn, "다운로드할 파일을 선택하세요."); return
            }
            let destDir = targetPath(of: targetPane)
            let dlNames = files.map(\.name).joined(separator: ", ")
            let dlAlert = NSAlert()
            dlAlert.messageText = "다운로드 확인"
            dlAlert.informativeText = "\(files.count)개 항목을 \(destDir) 로 다운로드하시겠습니까?\n\(dlNames)"
            dlAlert.addButton(withTitle: "다운로드")
            dlAlert.addButton(withTitle: "취소")
            guard dlAlert.runModal() == .alertFirstButtonReturn else { return }
            for f in files {
                let srcDir = sourcePane.parentPath(for: f.id)
                let src = (srcDir as NSString).appendingPathComponent(f.name)
                let dst = (destDir as NSString).appendingPathComponent(f.name)
                transfers.enqueue(Transfer(name: f.name, sourcePath: src, destinationPath: dst,
                                           direction: .download, totalBytes: f.size,
                                           source: sourcePane.connection, dest: targetPane.connection,
                                           isDirectory: f.isDirectory))
            }

        case .newFolder:
            NotificationCenter.default.post(name: .newFolder, object: nil)

        case .delete:
            let toDelete = pane.selectedItems
            guard !toDelete.isEmpty else { return }
            if pane.connection.proto == .local { pane.suppressWatcherUntil = Date().addingTimeInterval(2) }
            Task {
                var deletedIDs: Set<UUID> = []
                for item in toDelete {
                    let parentDir = pane.parentPath(for: item.id)
                    let p = (parentDir as NSString).appendingPathComponent(item.name)
                    do {
                        try await FileService.shared.remove(connection: pane.connection,
                                                            path: p, isDirectory: item.isDirectory)
                        transfers.appendLog(.ok, "삭제 완료: \(logPath(pane.connection, p))")
                        deletedIDs.insert(item.id)
                    } catch {
                        transfers.appendLog(.error, "삭제 실패: \(logPath(pane.connection, p))")
                    }
                }
                await MainActor.run {
                    pane.selection.subtract(deletedIDs)
                    // 최상위 항목에서 제거
                    pane.items.removeAll { deletedIDs.contains($0.id) }
                    // 펼쳐진 하위 항목에서 제거
                    for (folderID, children) in pane.childrenCache {
                        let filtered = children.filter { !deletedIDs.contains($0.id) }
                        if filtered.count != children.count {
                            pane.childrenCache[folderID] = filtered
                        }
                    }
                    // 삭제된 폴더의 펼침 상태 및 캐시 정리
                    for id in deletedIDs {
                        pane.expandedFolders.remove(id)
                        pane.childrenCache.removeValue(forKey: id)
                    }
                }
            }
        }
    }

    private func setupTransferCallback() {
        transfers.onTransferDone = { [self] t in
            let destDir = (t.destinationPath as NSString).deletingLastPathComponent
            // 대상 경로와 일치하는 패널만 리프레시
            for side: PaneSide in [.left, .right] {
                let p = app.pane(side)
                if p.currentPath == destDir {
                    // 현재 경로에 직접 전송된 경우
                    Task { await reloadPane(p) }
                } else {
                    // 선택된 폴더 안으로 전송된 경우: 해당 폴더의 하위만 갱신
                    if let folder = p.allItems.first(where: {
                        $0.isDirectory && p.expandedFolders.contains($0.id) &&
                        (p.parentPath(for: $0.id) as NSString)
                            .appendingPathComponent($0.name) == destDir
                    }) {
                        Task {
                            do {
                                let children = try await FileService.shared.list(
                                    connection: p.connection, path: destDir)
                                await MainActor.run {
                                    p.childrenCache[folder.id] = children
                                }
                            } catch {}
                        }
                    }
                }
            }
            // 모든 전송 완료 시 알림
            if transfers.activeCount == 0 {
                let alert = NSAlert()
                alert.messageText = "전송 완료"
                alert.informativeText = "전송이 완료되었습니다."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "확인")
                alert.runModal()
            }
        }
    }

    private func refresh(_ side: PaneSide) {
        Task { await reloadPane(app.pane(side)) }
    }

    func reloadPane(_ pane: PaneState) async {
        await MainActor.run { pane.isLoading = true; pane.errorMessage = nil }
        do {
            let items = try await FileService.shared.list(
                connection: pane.connection, path: pane.currentPath)
            await MainActor.run {
                pane.items = items; pane.isLoading = false; pane.isConnected = true
                // 존재하지 않는 항목의 선택 해제
                let validIDs = Set(pane.allItems.map(\.id))
                pane.selection = pane.selection.intersection(validIDs)
                app.saveLastPaneState()
            }
        } catch {
            await MainActor.run {
                pane.items = []; pane.isLoading = false
                pane.errorMessage = error.localizedDescription
                pane.isConnected = pane.connection.proto == .local
                if pane.connection.proto != .local {
                    app.appendLog(.error, "접속 실패 (\(pane.connection.host)): \(error.localizedDescription)")
                }
            }
        }
    }

    private func checkFullDiskAccess() {
        // 이미 안내한 적 있으면 스킵
        guard !UserDefaults.standard.bool(forKey: "TL.fdaPrompted") else { return }
        // ~/Library/Safari 접근 가능 여부로 FDA 체크
        let testPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Safari")
        let accessible = FileManager.default.isReadableFile(atPath: testPath)
        if !accessible {
            showFDAAlert = true
        } else {
            UserDefaults.standard.set(true, forKey: "TL.fdaPrompted")
        }
    }

    private func initialLoad() {
        Task {
            // 왼쪽 패널 복원
            let lc = app.leftPane.connection
            if lc.proto != .local {
                app.appendLog(.info, "왼쪽 패널 재접속: \(lc.proto.displayName) \(lc.host):\(lc.port)")
            }
            await reloadPane(app.leftPane)

            // 오른쪽 패널 복원
            let rc = app.rightPane.connection
            if rc.proto != .local {
                app.appendLog(.info, "오른쪽 패널 재접속: \(rc.proto.displayName) \(rc.host):\(rc.port)")
            }
            await reloadPane(app.rightPane)
        }
    }

    // MARK: - QuickLook (Spacebar)

    /// 텍스트 입력 중인지 확인
    private func isTextFieldFocused() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private func setupSpacebarMonitor() {
        spacebarMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 텍스트 필드 포커스 시 모든 키를 시스템에 맡김
            if self.isTextFieldFocused() { return event }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // 스페이스바 (keyCode 49), 다른 modifier 없을 때만
            if event.keyCode == 49 && mods == [] {
                self.handleSpacebar()
                return nil
            }

            // Shift+Cmd+Backspace 완전 삭제
            if event.keyCode == 51 && mods == [.command, .shift] {
                NotificationCenter.default.post(name: .filePermanentDelete, object: nil)
                return nil
            }

            // Cmd+Backspace 삭제
            if event.keyCode == 51 && mods == .command {
                NotificationCenter.default.post(name: .fileDelete, object: nil)
                return nil
            }

            // Enter (keyCode 36) — 이름 변경 시작
            if event.keyCode == 36 && mods == [] {
                NotificationCenter.default.post(name: .fileRename, object: nil)
                return nil
            }

            // Cmd++ 아이콘 확대 / Cmd+- 아이콘 축소
            if let chars = event.charactersIgnoringModifiers {
                if chars == "=" || chars == "+" {
                    if mods == .command {
                        withAnimation(.easeInOut(duration: 0.25)) { self.app.iconZoom = 2.0 }
                        return nil
                    }
                }
                if chars == "-" && mods == .command {
                    withAnimation(.easeInOut(duration: 0.25)) { self.app.iconZoom = 1.0 }
                    return nil
                }
            }

            // QuickLook 열린 상태에서 방향키로 파일 이동
            if let panel = QLPreviewPanel.shared(), panel.isVisible {
                let key = event.keyCode
                if (key == 126 || key == 125) && mods == [] {
                    // Up(126) / Down(125)
                    self.navigateQuickLook(direction: key == 126 ? -1 : 1)
                    return nil
                }
            }

            return event
        }
    }

    private func navigateQuickLook(direction: Int) {
        let pane = app.pane(app.activeSide)
        guard pane.connection.proto == .local else { return }

        // 화면 표시 순서대로 정렬된 아이템 (펼쳐진 하위 폴더 포함)
        let displayItems = pane.flattenedDisplayItems(showHidden: app.showHiddenFiles)
        guard !displayItems.isEmpty else { return }

        let currentIdx: Int
        if let selId = pane.selection.first,
           let idx = displayItems.firstIndex(where: { $0.id == selId }) {
            currentIdx = idx
        } else {
            currentIdx = 0
        }

        let newIdx = max(0, min(displayItems.count - 1, currentIdx + direction))
        let newItem = displayItems[newIdx]
        pane.selection = [newItem.id]

        // QuickLook 업데이트
        let parentDir = pane.parentPath(for: newItem.id)
        let path = (parentDir as NSString).appendingPathComponent(newItem.name)
        quickLookCoordinator.sourceFrame = app.selectedItemScreenFrame
        quickLookCoordinator.fileURL = URL(fileURLWithPath: path)
        QLPreviewPanel.shared()?.reloadData()
    }

    private func handleSpacebar() {
        let pane = app.pane(app.activeSide)
        guard pane.connection.proto == .local,
              let selectedId = pane.selection.first,
              let selectedItem = pane.allItems.first(where: { $0.id == selectedId }) else { return }
        let parentDir = pane.parentPath(for: selectedId)
        let path = (parentDir as NSString).appendingPathComponent(selectedItem.name)
        quickLookCoordinator.sourceFrame = app.selectedItemScreenFrame
        toggleQuickLook(for: path)
    }

    private func toggleQuickLook(for path: String) {
        quickLookCoordinator.fileURL = URL(fileURLWithPath: path)
        quickLookCoordinator.onArrowKey = { [weak app] keyCode in
            guard let app else { return }
            let pane = app.pane(app.activeSide)
            let items = pane.flattenedDisplayItems(showHidden: app.showHiddenFiles)
            guard !items.isEmpty else { return }
            let currentIdx = items.firstIndex(where: { pane.selection.contains($0.id) }) ?? 0
            let newIdx: Int
            if keyCode == 126 { // Up
                newIdx = max(0, currentIdx - 1)
            } else { // Down
                newIdx = min(items.count - 1, currentIdx + 1)
            }
            pane.selection = [items[newIdx].id]
            let parentDir = pane.parentPath(for: items[newIdx].id)
            let newPath = (parentDir as NSString).appendingPathComponent(items[newIdx].name)
            quickLookCoordinator.fileURL = URL(fileURLWithPath: newPath)
            quickLookCoordinator.sourceFrame = app.selectedItemScreenFrame
            QLPreviewPanel.shared()?.reloadData()
        }
        if let panel = QLPreviewPanel.shared() {
            if panel.isVisible {
                panel.orderOut(nil)
            } else {
                panel.dataSource = quickLookCoordinator
                panel.delegate = quickLookCoordinator
                panel.reloadData()
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func disconnectActive() {
        let side = app.activeSide
        let pane = PaneState(side: side, connection: Connection.localPlaceholder)
        app.setPane(side, to: pane)
        app.appendLog(.warn, "\(side == .left ? "왼쪽" : "오른쪽") 패널 연결 해제")
        app.saveLastPaneState()
        Task { await reloadPane(pane) }
    }

    private func openInfoForActive() {
        let pane = app.pane(app.activeSide)
        if let item = pane.firstSelectedItem {
            showInfoModal(side: app.activeSide, item: item)
        }
    }

    private func showInfoModal(side: PaneSide, item: RemoteItem) {
        infoSide = side
        infoSourceFrame = app.selectedItemGlobalFrame
        infoItem = item
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            infoAnimating = true
        }
    }

    private func dismissInfo() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            infoAnimating = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            infoItem = nil
        }
    }

    @ViewBuilder
    private func infoOverlay(item: RemoteItem) -> some View {
        GeometryReader { geo in
            let overlayFrame = geo.frame(in: .global)
            // 아이콘 중심 → 오버레이 로컬 좌표
            let iconLocalX = infoSourceFrame.midX - overlayFrame.minX
            let iconLocalY = infoSourceFrame.midY - overlayFrame.minY
            // 오버레이 중심 (InfoSheet가 ZStack 중앙에 배치됨)
            let centerX = overlayFrame.width / 2
            let centerY = overlayFrame.height / 2
            // 닫힌 상태에서의 오프셋: 중앙 → 아이콘 위치
            let dx = iconLocalX - centerX
            let dy = iconLocalY - centerY

            ZStack {
                Color.black.opacity(infoAnimating ? 0.35 : 0)
                    .ignoresSafeArea()
                    .onTapGesture { dismissInfo() }

                InfoSheet(item: item, side: infoSide, isPresented: Binding(
                    get: { infoItem != nil },
                    set: { if !$0 { dismissInfo() } }
                ))
                .environmentObject(app)
                .fixedSize(horizontal: false, vertical: true)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .scaleEffect(infoAnimating ? 1 : 0.01)
                .offset(x: infoAnimating ? 0 : dx,
                        y: infoAnimating ? 0 : dy)
                .opacity(infoAnimating ? 1 : 0)
            }
        }
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

    // MARK: - Copy / Paste / Undo

    private func fileCopy() {
        let pane = app.pane(app.activeSide)
        let selected = pane.selectedItems
        guard !selected.isEmpty else {
            app.appendLog(.warn, "복사할 항목을 선택하세요.")
            return
        }
        var paths: [UUID: String] = [:]
        for item in selected {
            paths[item.id] = pane.parentPath(for: item.id)
        }
        app.clipboard = Clipboard(
            items: selected,
            sourcePaths: paths,
            sourcePath: pane.currentPath,
            sourceConnection: pane.connection,
            sourceSide: app.activeSide
        )
        let names = selected.map(\.name).joined(separator: ", ")
        app.appendLog(.info, "\(selected.count)개 항목 복사됨: \(names)")
    }

    private func copySelectedPaths() {
        let pane = app.pane(app.activeSide)
        let selected = pane.selectedItems
        guard !selected.isEmpty else {
            app.appendLog(.warn, "경로를 복사할 항목을 선택하세요.")
            return
        }
        let paths = selected.map { item -> String in
            let parent = pane.parentPath(for: item.id)
            return (parent as NSString).appendingPathComponent(item.name)
        }
        let text = paths.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        app.appendLog(.info, "\(selected.count)개 경로 복사됨")
    }

    private func filePaste() {
        guard !app.clipboard.isEmpty else {
            app.appendLog(.warn, "클립보드가 비어 있습니다.")
            return
        }
        let cb = app.clipboard
        let destPane = app.pane(app.activeSide)
        let srcConn = cb.sourceConnection
        let dstConn = destPane.connection

        let sameLocation = srcConn.proto == dstConn.proto
            && srcConn.host == dstConn.host
            && srcConn.port == dstConn.port
            && srcConn.username == dstConn.username

        let destDir = targetPath(of: destPane)

        if sameLocation && cb.sourcePath == destDir {
            app.appendLog(.warn, "같은 폴더에는 붙혀넣기할 수 없습니다.")
            return
        }

        let pasteLabel = sameLocation ? "복사" : (srcConn.proto == .local ? "업로드" : "다운로드")
        let pasteNames = cb.items.map(\.name).joined(separator: ", ")
        let pasteAlert = NSAlert()
        pasteAlert.messageText = "\(pasteLabel) 확인"
        pasteAlert.informativeText = "\(cb.items.count)개 항목을 \(destDir) 로 \(pasteLabel)하시겠습니까?\n\(pasteNames)"
        pasteAlert.addButton(withTitle: pasteLabel)
        pasteAlert.addButton(withTitle: "취소")
        guard pasteAlert.runModal() == .alertFirstButtonReturn else { return }

        var pastedNames: [String] = []

        if sameLocation {
            // 같은 서버/로컬 내 복사
            if dstConn.proto == .local {
                destPane.suppressWatcherUntil = Date().addingTimeInterval(2)
            }
            for item in cb.items {
                let src = (cb.parentPath(for: item) as NSString).appendingPathComponent(item.name)
                let dst = (destDir as NSString).appendingPathComponent(item.name)
                pastedNames.append(item.name)
                Task {
                    do {
                        try await FileService.shared.copyAcross(
                            source: srcConn, sourcePath: src,
                            dest: dstConn, destPath: dst,
                            totalBytes: item.size) { _ in }
                        transfers.appendLog(.ok, "복사 완료: \(logPath(srcConn, src)) → \(logPath(dstConn, dst))")
                        await reloadTarget(destPane)
                    } catch {
                        transfers.appendLog(.error, "복사 실패: \(logPath(srcConn, src)) → \(logPath(dstConn, dst)) — \(error.localizedDescription)")
                    }
                }
            }
        } else {
            // 서버↔로컬이 다르면 업로드/다운로드로 전송
            let direction: TransferDirection =
                srcConn.proto == .local ? .upload : .download

            for item in cb.items {
                let src = (cb.parentPath(for: item) as NSString).appendingPathComponent(item.name)
                let dst = (destDir as NSString).appendingPathComponent(item.name)
                pastedNames.append(item.name)

                let t = Transfer(
                    name: item.name,
                    sourcePath: src,
                    destinationPath: dst,
                    direction: direction,
                    totalBytes: item.size,
                    source: srcConn,
                    dest: dstConn,
                    isDirectory: item.isDirectory
                )
                transfers.enqueue(t)
                transfers.appendLog(.info, "\(direction == .upload ? "업로드" : "다운로드") 대기열: \(logPath(srcConn, src)) → \(logPath(dstConn, dst))")
            }
        }

        // Undo 스택에 기록
        app.undoStack.append(.paste(
            names: pastedNames,
            path: destDir,
            connection: dstConn
        ))
    }

    private func handleFileCopy() {
        if isTextFieldFocused() {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        } else {
            fileCopy()
        }
    }

    private func handleFilePaste() {
        if isTextFieldFocused() {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        } else {
            filePaste()
        }
    }

    private func fileDelete() {
        let pane = app.pane(app.activeSide)
        let toDelete = pane.selectedItems
        guard !toDelete.isEmpty else { return }
        if pane.connection.proto == .local { pane.suppressWatcherUntil = Date().addingTimeInterval(5) }
        let deletedIDs = Set(toDelete.map(\.id))
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
        Task {
            var originalPaths: [String] = []
            var trashedURLs: [URL] = []
            for item in toDelete {
                let parentDir = pane.parentPath(for: item.id)
                let p = (parentDir as NSString).appendingPathComponent(item.name)
                do {
                    if pane.connection.proto == .local {
                        var resultURL: NSURL?
                        try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: &resultURL)
                        let trashURL = (resultURL as URL?) ?? URL(fileURLWithPath: p)
                        originalPaths.append(p)
                        trashedURLs.append(trashURL)
                    } else {
                        try await FileService.shared.remove(connection: pane.connection, path: p, isDirectory: item.isDirectory)
                    }
                } catch {
                    transfers.appendLog(.error, "삭제 실패: \(logPath(pane.connection, p))")
                }
            }
            if !trashedURLs.isEmpty {
                await MainActor.run {
                    app.undoStack.append(.delete(originalPaths: originalPaths, trashedURLs: trashedURLs))
                }
            }
        }
    }

    private func filePermanentDelete() {
        let pane = app.pane(app.activeSide)
        let toDelete = pane.selectedItems
        guard !toDelete.isEmpty else { return }
        if pane.connection.proto == .local { pane.suppressWatcherUntil = Date().addingTimeInterval(5) }
        let deletedIDs = Set(toDelete.map(\.id))
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
        Task {
            for item in toDelete {
                let parentDir = pane.parentPath(for: item.id)
                let p = (parentDir as NSString).appendingPathComponent(item.name)
                do {
                    if pane.connection.proto == .local {
                        try FileManager.default.removeItem(atPath: p)
                    } else {
                        try await FileService.shared.remove(connection: pane.connection, path: p, isDirectory: item.isDirectory)
                    }
                } catch {
                    transfers.appendLog(.error, "완전삭제 실패: \(logPath(pane.connection, p))")
                }
            }
        }
    }

    private func fileUndo() {
        guard let lastAction = app.undoStack.popLast() else {
            app.appendLog(.warn, "되살리기할 작업이 없습니다.")
            return
        }
        switch lastAction {
        case .paste(let names, let path, let connection):
            Task {
                for name in names {
                    let fullPath = (path as NSString).appendingPathComponent(name)
                    do {
                        try await FileService.shared.remove(
                            connection: connection, path: fullPath,
                            isDirectory: false)
                        app.appendLog(.ok, "되살리기: \(name) 삭제됨")
                    } catch {
                        app.appendLog(.error, "되살리기 실패: \(name) — \(error.localizedDescription)")
                    }
                }
                let activePane = app.pane(app.activeSide)
                await reloadPane(activePane)
            }
        case .delete(let originalPaths, let trashedURLs):
            // 휴지통에서 원래 위치로 복원
            let activePane = app.pane(app.activeSide)
            if activePane.connection.proto == .local {
                activePane.suppressWatcherUntil = Date().addingTimeInterval(5)
            }
            Task {
                for (idx, url) in trashedURLs.enumerated() {
                    let name = url.lastPathComponent
                    let destPath = idx < originalPaths.count ? originalPaths[idx]
                        : (activePane.currentPath as NSString).appendingPathComponent(name)
                    do {
                        try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: destPath))
                        app.appendLog(.ok, "되살리기: \(name) 복원됨")
                    } catch {
                        app.appendLog(.error, "되살리기 실패: \(name) — \(error.localizedDescription)")
                    }
                }
                await reloadPane(activePane)
            }
        }
    }

    // MARK: - Search

    @State private var preSearchItems: [RemoteItem]?
    @State private var preSearchPath: String?

    private func performSearch() {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { clearSearch(); return }
        let pane = app.pane(app.activeSide)

        // 검색 전 상태 백업 (최초 1회)
        if preSearchItems == nil {
            preSearchItems = pane.items
            preSearchPath = pane.currentPath
        }

        if pane.connection.proto == .local {
            // Spotlight 검색
            let searchPath = preSearchPath ?? pane.currentPath
            Task {
                let results = await spotlightSearch(query: query, inPath: searchPath)
                await MainActor.run { pane.items = results }
            }
        } else {
            // 서버: 현재 목록에서 이름 필터
            let base = preSearchItems ?? pane.items
            let lower = query.lowercased()
            pane.items = base.filter { $0.name.lowercased().contains(lower) }
        }
    }

    private func clearSearch() {
        let pane = app.pane(app.activeSide)
        if let saved = preSearchItems {
            pane.items = saved
        }
        preSearchItems = nil
        preSearchPath = nil
    }

    private func spotlightSearch(query: String, inPath searchPath: String) async -> [RemoteItem] {
        // mdfind를 비동기로 실행 (5초 타임아웃)
        let paths: [String] = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                proc.arguments = ["-onlyin", searchPath,
                                  "kMDItemFSName == '*\(query)*'cd"]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = Pipe()
                do {
                    try proc.run()
                    // 5초 타임아웃
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        if proc.isRunning { proc.terminate() }
                    }
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let results = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    cont.resume(returning: results)
                } catch {
                    cont.resume(returning: [])
                }
            }
        }

        let fm = FileManager.default
        var items: [RemoteItem] = []
        for path in paths.prefix(200) {
            do {
                let attrs = try fm.attributesOfItem(atPath: path)
                let fileType = attrs[.type] as? FileAttributeType
                let isDir = fileType == .typeDirectory
                let size = (attrs[.size] as? Int64) ?? 0
                let modified = (attrs[.modificationDate] as? Date) ?? Date()
                let posix = (attrs[.posixPermissions] as? Int) ?? 0o644
                let owner = (attrs[.ownerAccountName] as? String) ?? ""
                let group = (attrs[.groupOwnerAccountName] as? String) ?? ""
                let perms = formatPosix(posix, isDir: isDir)
                items.append(RemoteItem(
                    name: (path as NSString).lastPathComponent,
                    isDirectory: isDir, size: size, modified: modified,
                    permissions: perms, owner: owner, group: group,
                    fullPath: path))
            } catch { continue }
        }
        return items
    }

    private func formatPosix(_ posix: Int, isDir: Bool) -> String {
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

    private func moveSelectedFiles(from sourceSide: PaneSide, to destSide: PaneSide) {
        let sourcePane = app.pane(sourceSide)
        let destPane = app.pane(destSide)
        let selected = sourcePane.selectedItems
        guard !selected.isEmpty else {
            app.appendLog(.warn, "이동: 선택된 항목 없음")
            return
        }
        app.appendLog(.info, "이동 시작: \(selected.count)개, proto=\(sourcePane.connection.proto.displayName)→\(destPane.connection.proto.displayName)")

        let sc = sourcePane.connection
        let dc = destPane.connection
        let destDir = targetPath(of: destPane)

        // 확인 창
        let sameLocal = sc.proto == .local && dc.proto == .local
        let sameServer = sc.proto != .local && dc.proto != .local &&
            sc.proto == dc.proto && sc.host == dc.host &&
            sc.port == dc.port && sc.username == dc.username
        let moveLabel = (sameLocal || sameServer) ? "이동" : (sc.proto == .local ? "업로드" : "다운로드")
        let moveNames = selected.map(\.name).joined(separator: ", ")
        let moveAlert = NSAlert()
        moveAlert.messageText = "\(moveLabel) 확인"
        moveAlert.informativeText = "\(selected.count)개 항목을 \(destDir) 로 \(moveLabel)하시겠습니까?\n\(moveNames)"
        moveAlert.addButton(withTitle: moveLabel)
        moveAlert.addButton(withTitle: "취소")
        guard moveAlert.runModal() == .alertFirstButtonReturn else { return }

        if sameServer {
            Task {
                for item in selected {
                    let srcDir = sourcePane.parentPath(for: item.id)
                    let src = (srcDir as NSString).appendingPathComponent(item.name)
                    let dst = (destDir as NSString).appendingPathComponent(item.name)
                    do {
                        try await FileService.shared.moveFile(connection: sc, from: src, to: dst)
                        transfers.appendLog(.ok, "이동 완료: \(logPath(sc, src)) → \(logPath(sc, destDir))")
                    } catch {
                        transfers.appendLog(.error, "이동 실패: \(logPath(sc, src)) — \(error.localizedDescription)")
                    }
                }
                await reloadPane(sourcePane)
                await reloadTarget(destPane)
            }
            return
        }

        // 같은 로컬 내 이동
        if sc.proto == .local && dc.proto == .local {
            sourcePane.suppressWatcherUntil = Date().addingTimeInterval(3)
            destPane.suppressWatcherUntil = Date().addingTimeInterval(3)
            var movedIDs: Set<UUID> = []
            for item in selected {
                let srcDir = sourcePane.parentPath(for: item.id)
                let src = (srcDir as NSString).appendingPathComponent(item.name)
                let dst = (destDir as NSString).appendingPathComponent(item.name)
                do {
                    try FileManager.default.moveItem(atPath: src, toPath: dst)
                    movedIDs.insert(item.id)
                    transfers.appendLog(.ok, "이동 완료: \(src) → \(destDir)")
                } catch {
                    transfers.appendLog(.error, "이동 실패: \(src) — \(error.localizedDescription)")
                }
            }
            // 소스 폴더 경로 (선택 아이템의 부모)
            let srcDir = selected.first.map { sourcePane.parentPath(for: $0.id) } ?? sourcePane.currentPath

            // 소스 패널에서 이동된 항목 제거 (리플래시 없이)
            sourcePane.selection.subtract(movedIDs)
            sourcePane.items.removeAll { movedIDs.contains($0.id) }
            for (folderID, children) in sourcePane.childrenCache {
                let filtered = children.filter { !movedIDs.contains($0.id) }
                if filtered.count != children.count {
                    sourcePane.childrenCache[folderID] = filtered
                }
            }
            for id in movedIDs {
                sourcePane.expandedFolders.remove(id)
                sourcePane.childrenCache.removeValue(forKey: id)
            }

            // 양쪽 패널의 소스/대상 폴더 모두 갱신
            Task {
                await reloadFolder(pane: sourcePane, path: srcDir)
                await reloadFolder(pane: sourcePane, path: destDir)
                await reloadFolder(pane: destPane, path: destDir)
                await reloadFolder(pane: destPane, path: srcDir)
            }
            return
        }

        // 서버 ↔ 로컬: 전송 큐로 처리
        let direction: TransferDirection = sc.proto == .local ? .upload : .download
        for item in selected {
            let srcDir = sourcePane.parentPath(for: item.id)
            let src = (srcDir as NSString).appendingPathComponent(item.name)
            let dst = (destDir as NSString).appendingPathComponent(item.name)
            let t = Transfer(name: item.name, sourcePath: src, destinationPath: dst,
                             direction: direction, totalBytes: item.size,
                             source: sc, dest: dc,
                             isDirectory: item.isDirectory)
            transfers.enqueue(t)
        }
        let label = direction == .upload ? "업로드" : "다운로드"
        transfers.appendLog(.info, "\(label) 대기열: \(selected.count)개 항목 → \(logPath(dc, destDir))")
    }

    private func connectFromRecent(_ c: Connection) {
        let pane = PaneState(side: app.activeSide, connection: c)
        pane.isConnected = true
        app.setPane(app.activeSide, to: pane)
        app.saveLastPaneState()
        Task {
            do {
                let items = try await FileService.shared.list(connection: c, path: c.remotePath)
                await MainActor.run { pane.items = items; pane.isLoading = false }
                app.appendLog(.ok, "연결됨: \(c.host)")
            } catch {
                app.appendLog(.error, "연결 실패: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - File Notification Handlers

private struct FileNotificationHandlers: ViewModifier {
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onUndo: () -> Void
    let onCopyPath: () -> Void
    let onDelete: () -> Void
    let onPermanentDelete: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .fileCopy))  { _ in onCopy() }
            .onReceive(NotificationCenter.default.publisher(for: .filePaste)) { _ in onPaste() }
            .onReceive(NotificationCenter.default.publisher(for: .fileUndo))  { _ in onUndo() }
            .onReceive(NotificationCenter.default.publisher(for: .copyPath))  { _ in onCopyPath() }
            .onReceive(NotificationCenter.default.publisher(for: .fileDelete)) { _ in onDelete() }
            .onReceive(NotificationCenter.default.publisher(for: .filePermanentDelete)) { _ in onPermanentDelete() }
    }
}

// MARK: - Resizable Divider

struct ResizableDivider: View {
    @Binding var dimension: CGFloat
    let edge: Edge
    let minSize: CGFloat
    let maxSize: CGFloat
    var showLine: Bool = true
    var onDragEnd: (() -> Void)?

    @State private var dragStartDimension: CGFloat?

    init(dimension: Binding<CGFloat>, edge: Edge,
         minSize: CGFloat = 120, maxSize: CGFloat = 600,
         showLine: Bool = true,
         onDragEnd: (() -> Void)? = nil) {
        _dimension = dimension
        self.edge = edge
        self.minSize = minSize
        self.maxSize = maxSize
        self.showLine = showLine
        self.onDragEnd = onDragEnd
    }

    var body: some View {
        let isVert = (edge == .leading || edge == .trailing)
        ZStack {
            if showLine {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: isVert ? 1 : nil, height: isVert ? nil : 1)
            }
        }
        .frame(width: isVert ? 5 : nil, height: isVert ? nil : 5)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                (isVert ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartDimension == nil {
                        dragStartDimension = dimension
                    }
                    let delta: CGFloat
                    switch edge {
                    case .leading:  delta = -value.translation.width
                    case .trailing: delta = value.translation.width
                    case .top:      delta = -value.translation.height
                    case .bottom:   delta = value.translation.height
                    }
                    let newValue = max(minSize, min(maxSize, dragStartDimension! + delta))
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        dimension = newValue
                    }
                }
                .onEnded { _ in
                    dragStartDimension = nil
                    onDragEnd?()
                }
        )
    }
}

// MARK: - Terminal Resize Handle (NSView 기반)

struct TerminalResizeHandle: NSViewRepresentable {
    @Binding var height: CGFloat
    let minH: CGFloat
    let maxH: CGFloat

    func makeNSView(context: Context) -> TerminalResizeNSView {
        let v = TerminalResizeNSView()
        v.currentHeight = height
        v.heightBinding = $height
        v.minH = minH
        v.maxH = maxH
        return v
    }

    func updateNSView(_ nsView: TerminalResizeNSView, context: Context) {
        nsView.currentHeight = height
        nsView.heightBinding = $height
    }

    class TerminalResizeNSView: NSView {
        var currentHeight: CGFloat = 140
        var heightBinding: Binding<CGFloat>?
        var minH: CGFloat = 60
        var maxH: CGFloat = 400
        private var lastY: CGFloat = 0
        private var tracking = false
        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool { true }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: 8)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let ta = trackingArea { removeTrackingArea(ta) }
            let ta = NSTrackingArea(rect: bounds,
                                    options: [.mouseEnteredAndExited, .activeAlways],
                                    owner: self, userInfo: nil)
            addTrackingArea(ta)
            trackingArea = ta
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.resizeUpDown.push()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.pop()
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            let r = NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
            r.fill()
        }

        override func mouseDown(with event: NSEvent) {
            lastY = NSEvent.mouseLocation.y
            tracking = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard tracking else { return }
            let currentY = NSEvent.mouseLocation.y
            let delta = currentY - lastY
            lastY = currentY
            let newH = min(maxH, max(minH, currentHeight + delta))
            currentHeight = newH
            heightBinding?.wrappedValue = newH
        }

        override func mouseUp(with event: NSEvent) {
            tracking = false
        }
    }
}

// MARK: - Pane Resize Handle (NSView 기반, 정확한 delta)

private struct PaneResizeHandleView: NSViewRepresentable {
    @Binding var ratio: CGFloat

    func makeNSView(context: Context) -> PaneResizeNSView {
        let v = PaneResizeNSView()
        v.ratio = ratio
        v.ratioBinding = $ratio
        return v
    }

    func updateNSView(_ nsView: PaneResizeNSView, context: Context) {
        nsView.ratio = ratio
        nsView.ratioBinding = $ratio
    }

    class PaneResizeNSView: NSView {
        var ratio: CGFloat = 0.5
        var ratioBinding: Binding<CGFloat>?
        private var lastX: CGFloat = 0
        private var tracking = false

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            lastX = NSEvent.mouseLocation.x
            tracking = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard tracking else { return }
            let currentX = NSEvent.mouseLocation.x
            let delta = currentX - lastX
            lastX = currentX

            // superview 체인을 통해 실제 pane 영역 너비 계산
            var paneArea: CGFloat = 800
            var view: NSView? = self.superview
            while let v = view {
                if v.bounds.width > 200 {
                    paneArea = v.bounds.width - 46 - 6
                    break
                }
                view = v.superview
            }
            guard paneArea > 0 else { return }
            let deltaRatio = delta / paneArea
            let newRatio = min(0.8, max(0.2, ratio + deltaRatio))
            ratio = newRatio
            ratioBinding?.wrappedValue = newRatio
        }

        override func mouseUp(with event: NSEvent) {
            tracking = false
        }
    }
}

// MARK: - Toast Overlay

private struct ToastOverlay: View {
    let toasts: [AppState.ToastItem]
    let onDismiss: (UUID) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(toasts) { toast in
                ToastBanner(toast: toast, onDismiss: { onDismiss(toast.id) })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.25), value: toasts.count)
    }
}

private struct ToastBanner: View {
    let toast: AppState.ToastItem
    let onDismiss: () -> Void

    private var icon: String {
        switch toast.level {
        case .ok:    return "checkmark.circle.fill"
        case .warn:  return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        default:     return "info.circle.fill"
        }
    }

    private var accentColor: Color {
        switch toast.level {
        case .ok:    return .green
        case .warn:  return .orange
        case .error: return .red
        default:     return .blue
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(accentColor)
                .font(.system(size: 14))
            Text(toast.message)
                .font(.system(size: 12))
                .lineLimit(2)
                .foregroundStyle(.primary)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .frame(maxWidth: 360)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                onDismiss()
            }
        }
    }
}


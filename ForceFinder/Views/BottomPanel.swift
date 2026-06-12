//
//  BottomPanel.swift
//  ForceFinder
//

import SwiftUI

// MARK: - Transfer Panel (shown at bottom of main window)

enum TransferPanelTab {
    case transfers, log
}

struct TransferPanel: View {
    @EnvironmentObject var transferManager: TransferManager
    @State private var selectedTab: TransferPanelTab = .transfers

    var body: some View {
        VStack(spacing: 0) {
            // Header with tabs
            HStack(spacing: 0) {
                tabButton("전송", icon: "arrow.up.arrow.down", tab: .transfers,
                          badge: transferManager.activeCount > 0 ? transferManager.activeCount : nil)
                tabButton("전송 로그", icon: "list.bullet.rectangle", tab: .log, badge: nil)

                Spacer()

                if selectedTab == .transfers {
                    Button("완료 항목 지우기") {
                        transferManager.clearCompleted()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Button("로그 지우기") {
                        transferManager.clearLogs()
                    }
                    .controlSize(.mini)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color.panelHeader)

            Divider()

            // Content
            switch selectedTab {
            case .transfers:
                transferListView
            case .log:
                transferLogView
            }
        }
        .background(Color.panelList)
    }

    @ViewBuilder
    private func tabButton(_ title: String, icon: String, tab: TransferPanelTab, badge: Int?) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14)
                        .background(Color(red: 0.78, green: 0.28, blue: 0.51))
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var transferListView: some View {
        if transferManager.transfers.isEmpty {
            Text("전송 항목 없음")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(transferManager.transfers.enumerated()),
                            id: \.element.id) { idx, t in
                        TransferRow(transfer: t, isAlt: idx % 2 == 1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var transferLogView: some View {
        if transferManager.transferLogs.isEmpty {
            Text("전송 로그 없음")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(transferManager.transferLogs) { entry in
                            HStack(alignment: .top, spacing: 4) {
                                Text("[\(logTimestamp(entry.timestamp))]")
                                    .foregroundStyle(.tertiary)
                                Text(entry.message)
                                    .foregroundStyle(entry.level.color)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .id(entry.id)
                        }
                    }
                }
                .onChange(of: transferManager.transferLogs.count) { _, _ in
                    if let last = transferManager.transferLogs.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func logTimestamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

// MARK: - Transfer Row

struct TransferRow: View {
    @ObservedObject var transfer: Transfer
    @EnvironmentObject var transferManager: TransferManager
    let isAlt: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            // 메인 행
            HStack(spacing: 6) {
                // 폴더면 펼치기 삼각형
                if transfer.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10)
                }

                Image(systemName: transfer.direction == .upload ? "arrow.up" : "arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(transfer.direction == .upload
                                     ? Color.orange : Color(red: 0.78, green: 0.28, blue: 0.51))
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        if transfer.isDirectory {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Text(transfer.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        if transfer.isDirectory && transfer.totalFileCount > 0 {
                            Text("\(transfer.completedFileCount)/\(transfer.totalFileCount)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if transfer.isDirectory, let currentFile = transfer.currentFileName,
                       transfer.status == .active {
                        Text(currentFile)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Progress
                ProgressView(value: transfer.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 100)

                // Status
                HStack(spacing: 3) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(transfer.status.rawValue).font(.system(size: 10))
                }
                .frame(width: 60, alignment: .leading)

                // Cancel button
                if transfer.status == .active || transfer.status == .queued {
                    Button {
                        transferManager.cancel(transfer)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("취소")
                } else {
                    Color.clear.frame(width: 16)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 22)
            .padding(.vertical, transfer.isDirectory && transfer.currentFileName != nil && transfer.status == .active ? 2 : 0)
            .contentShape(Rectangle())
            .onTapGesture {
                guard transfer.isDirectory else { return }
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }
            .onChange(of: transfer.fileEntries.count) { _, newCount in
                if newCount == 1 { isExpanded = true }
            }

            // 펼쳐진 파일 목록
            if isExpanded && transfer.isDirectory {
                VStack(spacing: 0) {
                    ForEach(transfer.fileEntries) { entry in
                        HStack(spacing: 4) {
                            fileStatusIcon(entry.status)
                                .frame(width: 10)
                            Text(entry.name)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .foregroundStyle(entry.status == .transferring ? .primary : .secondary)
                            Spacer()
                            Text(fileStatusLabel(entry.status))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.leading, 28)
                        .frame(height: 18)
                        .background(entry.status == .transferring
                                    ? Color(red: 0.78, green: 0.28, blue: 0.51).opacity(0.08)
                                    : Color.clear)
                    }
                }
            }
        }
        .background(isAlt ? Color.panelCard : .clear)
        .contextMenu {
            Button("취소") { transferManager.cancel(transfer) }
        }
    }

    private var statusColor: Color {
        switch transfer.status {
        case .active:  return Color(red: 0.78, green: 0.28, blue: 0.51)
        case .done:    return .green
        case .error:   return .red
        case .queued:  return .gray
        case .paused:  return .orange
        }
    }

    @ViewBuilder
    private func fileStatusIcon(_ status: FileTransferStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
        case .transferring:
            Image(systemName: "arrow.right.circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(Color(red: 0.78, green: 0.28, blue: 0.51))
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(.red)
        }
    }

    private func fileStatusLabel(_ status: FileTransferStatus) -> String {
        switch status {
        case .pending:      return ""
        case .transferring: return "전송 중"
        case .done:         return "완료"
        case .error:        return "오류"
        }
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var transfers: TransferManager
    @Binding var showTransfers: Bool
    @State private var diskFreeSpace: String = ""

    var body: some View {
        HStack(spacing: 10) {
            // Left pane
            statusDot(app.leftPane.isConnected)
            Text(app.leftPane.connection.proto == .local
                 ? "로컬" : app.leftPane.connection.host)

            Divider().frame(height: 10)

            // Right pane
            statusDot(app.rightPane.isConnected)
            Text(app.rightPane.connection.proto == .local
                 ? "로컬" : app.rightPane.connection.host)

            Spacer()

            // Disk free space (center)
            if !diskFreeSpace.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 8))
                    Text(diskFreeSpace)
                }
                .foregroundStyle(.primary)
            }

            Spacer()

            // Transfer toggle
            if transfers.activeCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 8))
                    Text("\(transfers.activeCount)")
                }
                .foregroundStyle(.secondary)
            }

            Button {
                showTransfers.toggle()
            } label: {
                Image(systemName: showTransfers ? "chevron.down" : "chevron.up")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(Color.white.opacity(0.1))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 20)
        .background(Color.panelHeader)
        .onAppear { updateDiskFreeSpace() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            updateDiskFreeSpace()
        }
    }

    private func updateDiskFreeSpace() {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = values.volumeAvailableCapacityForImportantUsage {
            diskFreeSpace = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " 사용 가능"
        } else if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
                  let bytes = values.volumeAvailableCapacity {
            diskFreeSpace = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " 사용 가능"
        }
    }

    @ViewBuilder
    private func statusDot(_ connected: Bool) -> some View {
        Circle()
            .fill(connected ? Color.green : Color.gray.opacity(0.5))
            .frame(width: 6, height: 6)
    }
}

// MARK: - Log View

struct LogView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(app.logLines) { line in
                        HStack(alignment: .top, spacing: 4) {
                            Text("[\(timestamp(line.timestamp))]")
                                .foregroundStyle(.tertiary)
                            Text(line.text)
                                .foregroundStyle(line.level.color)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .id(line.id)
                    }
                }
            }
            .background(Color.panelList)
            .onChange(of: app.logLines.count) { _, _ in
                if let last = app.logLines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func timestamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

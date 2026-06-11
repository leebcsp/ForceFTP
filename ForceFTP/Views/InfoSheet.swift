//
//  InfoSheet.swift
//  ForceFTP
//

import SwiftUI

struct InfoSheet: View {
    let item: RemoteItem
    let side: PaneSide
    @Binding var isPresented: Bool
    @EnvironmentObject var app: AppState

    @State private var perms: Permissions
    @State private var recursive: Bool = false
    @State private var applying: Bool = false
    @State private var error: String?

    init(item: RemoteItem, side: PaneSide, isPresented: Binding<Bool>) {
        self.item = item
        self.side = side
        self._isPresented = isPresented
        self._perms = State(initialValue: Permissions(from: item.permissions,
                                                      isDirectory: item.isDirectory))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    generalSection
                    Divider().padding(.horizontal, 16)
                    permissionsSection
                }
                .padding(.vertical, 12)
            }
            footer
        }
        .frame(width: 380)
        .background(Color(red: 0.16, green: 0.16, blue: 0.17))
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: item.iconName)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(item.iconTint)
                .frame(width: 56, height: 56)
                .background(
                    item.isDirectory
                        ? RoundedRectangle(cornerRadius: 8).fill(item.iconTint.opacity(0.12))
                        : RoundedRectangle(cornerRadius: 8).fill(Color.clear)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(metaText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var metaText: String {
        if item.isDirectory { return "폴더" }
        return "\(kindFor(name: item.name)) · \(formatSize(item.size))"
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("일반")
            grid {
                kv("종류:", item.isDirectory ? "폴더" : kindFor(name: item.name))
                kv("크기:", item.isDirectory ? "—" : "\(item.size.formatted()) bytes")
                kv("위치:", "\(app.pane(side).currentPath)")
                kv("수정일:", formatDate(item.modified))
                kv("소유자:", "\(item.owner) : \(item.group)")
            }
        }
        .padding(.horizontal, 16)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("공유 및 사용 권한 (chmod)")

            HStack(spacing: 0) {
                Text("").frame(width: 70, alignment: .leading)
                ForEach(["읽기", "쓰기", "실행"], id: \.self) { t in
                    Text(t)
                        .font(.system(size: 10.5, weight: .semibold))
                        .kerning(0.4)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.secondary)
                }
            }

            permRow(label: "소유자",
                    r: $perms.ownerRead, w: $perms.ownerWrite, x: $perms.ownerExec)
            permRow(label: "그룹",
                    r: $perms.groupRead, w: $perms.groupWrite, x: $perms.groupExec)
            permRow(label: "기타",
                    r: $perms.otherRead, w: $perms.otherWrite, x: $perms.otherExec)

            HStack {
                Text("기호:").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(perms.symbolic).font(.system(size: 12, design: .monospaced))
                Spacer()
                Text("옥타:").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(perms.octal).font(.system(size: 13, design: .monospaced).weight(.bold))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(red: 0.16, green: 0.16, blue: 0.17))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if item.isDirectory {
                Toggle("하위 항목에 적용 (chmod -R)", isOn: $recursive)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
            }

            if let err = error {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("취소") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button("적용") { applyChmod() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(applying)
        }
        .padding(14)
        .background(Color(red: 0.16, green: 0.16, blue: 0.17))
    }

    // MARK: - Helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .bold))
            .kerning(0.5)
            .foregroundStyle(.secondary)
    }

    private func grid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) { content() }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
            Text(v).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
    }

    private func permRow(label: String,
                         r: Binding<Bool>, w: Binding<Bool>, x: Binding<Bool>) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 70, alignment: .leading)
            Toggle("", isOn: r).toggleStyle(.checkbox).frame(maxWidth: .infinity)
            Toggle("", isOn: w).toggleStyle(.checkbox).frame(maxWidth: .infinity)
            Toggle("", isOn: x).toggleStyle(.checkbox).frame(maxWidth: .infinity)
        }
    }

    private func formatSize(_ n: Int64) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        if n < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(n) / 1024 / 1024) }
        return String(format: "%.2f GB", Double(n) / 1024 / 1024 / 1024)
    }

    private func formatDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy.MM.dd HH:mm"
        return f.string(from: d)
    }

    private func kindFor(name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let map: [String: String] = [
            "js": "JavaScript 소스", "ts": "TypeScript 소스",
            "swift": "Swift 소스", "py": "Python 소스",
            "json": "JSON 문서", "html": "HTML 문서",
            "css": "CSS 스타일시트", "md": "Markdown 문서",
            "txt": "일반 텍스트",
            "png": "PNG 이미지", "jpg": "JPEG 이미지",
            "pdf": "PDF 문서", "docx": "Word 문서",
            "zip": "ZIP 아카이브", "tar": "Tar 아카이브",
            "gz": "Gzip 아카이브",
            "log": "로그 파일", "conf": "설정 파일",
            "sql": "SQL 스크립트", "sh": "셸 스크립트",
            "mp4": "MP4 비디오", "mov": "QuickTime 비디오",
            "xlsx": "Excel 스프레드시트"
        ]
        return map[ext] ?? (ext.isEmpty ? "파일" : "\(ext.uppercased()) 파일")
    }

    private func applyChmod() {
        applying = true
        let pane = app.pane(side)
        let parentDir = pane.parentPath(for: item.id)
        let full = (parentDir as NSString).appendingPathComponent(item.name)
        let octal = perms.octal
        let recursive = self.recursive

        Task {
            do {
                try await FileService.shared.chmod(connection: pane.connection,
                                                   path: full, octal: octal,
                                                   recursive: recursive)
                let items = try await FileService.shared.list(connection: pane.connection,
                                                              path: pane.currentPath)
                await MainActor.run {
                    pane.items = items
                    app.appendLog(.ok, "chmod \(octal)\(recursive ? " -R" : "") \(item.name)")
                    isPresented = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    applying = false
                    app.appendLog(.error, "chmod 실패: \(error.localizedDescription)")
                }
            }
        }
    }
}

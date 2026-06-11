//
//  InspectorView.swift
//  ForceFTP
//

import SwiftUI
import QuickLookThumbnailing
import MapKit

struct InspectorView: View {
    let item: RemoteItem
    let side: PaneSide
    @EnvironmentObject var app: AppState

    @State private var perms: Permissions
    @State private var showGeneral = true
    @State private var showPermissions = true
    @State private var showMoreInfo = true
    @State private var ownerName: String
    @State private var groupName: String
    @State private var isLocked = false
    @State private var isHidden: Bool
    @State private var hideExtension = false
    @State private var comment: String = ""
    @State private var thumbnail: NSImage?
    @State private var qrContent: QRContent? = nil
    @State private var showQRInfo = true
    @State private var showMediaInfo = true
    @State private var mediaInfo: [MediaInfoRow] = []

    private var pane: PaneState { app.pane(side) }
    private var fullPath: String {
        if let fp = item.fullPath { return fp }
        let parentDir = pane.parentPath(for: item.id)
        return (parentDir as NSString).appendingPathComponent(item.name)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy, h:mm a"
        return f
    }()

    init(item: RemoteItem, side: PaneSide) {
        self.item = item
        self.side = side
        _perms = State(initialValue: Permissions(from: item.permissions, isDirectory: item.isDirectory))
        _ownerName = State(initialValue: item.owner)
        _groupName = State(initialValue: item.group)
        _isHidden = State(initialValue: item.name.hasPrefix("."))

        // 로컬 파일: 실제 속성 읽기
        _ = item.name // will be updated on appear
        _isLocked = State(initialValue: false)
        _hideExtension = State(initialValue: false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // File icon + name header
                fileHeader

                Divider().padding(.vertical, 8)

                // General
                inspectorSection("General", isExpanded: $showGeneral) {
                    pathRow(fullPath)
                    infoRow("Size", formatDetailedSize(item.size))
                    infoRow("Modified", Self.dateFormatter.string(from: item.modified))
                    infoRow("Extension", fileExtension)

                    toggleRow("Hide Extension", $hideExtension)
                    toggleRow("Hidden", $isHidden)
                }

                // Permissions (remote only)
                if pane.connection.proto != .local {
                    inspectorSection("Permissions", isExpanded: $showPermissions) {
                        permissionsGrid

                        Divider().padding(.vertical, 4)

                        // Octal display
                        HStack {
                            Text("Octal")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(perms.symbolic)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(perms.octal)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(red: 0.16, green: 0.16, blue: 0.17))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Divider().padding(.vertical, 4)

                        // Owner / Group
                        HStack {
                            Text("Owner")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            TextField("owner", text: $ownerName)
                                .font(.system(size: 12))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                        }

                        HStack {
                            Text("Group")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            TextField("group", text: $groupName)
                                .font(.system(size: 12))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                        }

                        toggleRow("Locked", $isLocked)
                    }
                }

                // More Info
                inspectorSection("More Info", isExpanded: $showMoreInfo) {
                    infoRow("Content created", Self.dateFormatter.string(from: item.modified))
                    infoRow("Type", item.isDirectory ? "Folder" : fileKind)
                }

                // Media Info
                if !mediaInfo.isEmpty {
                    inspectorSection("미디어 정보", isExpanded: $showMediaInfo) {
                        ForEach(mediaInfo) { row in
                            if row.isHeader {
                                Text(row.label)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            } else {
                                infoRow(row.label, row.value)
                            }
                        }
                    }
                }

                Spacer(minLength: 20)

                // Apply button
                HStack {
                    Spacer()
                    Button("적용") {
                        applyPermissions()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .padding(.vertical, 8)

                // QR Code Content
                if let qr = qrContent {
                    inspectorSection("QR 코드 내용", isExpanded: $showQRInfo) {
                        qrContentView(qr)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.16, green: 0.16, blue: 0.17))
        .task(id: item.id) {
            perms = Permissions(from: item.permissions, isDirectory: item.isDirectory)
            ownerName = item.owner
            groupName = item.group
            isHidden = item.name.hasPrefix(".")
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            loadFileAttributes()
            detectQRCode()
            loadMediaInfo()
        }
    }

    // MARK: - File Header

    private var fileHeader: some View {
        VStack(spacing: 8) {
            // Thumbnail preview
            if let thumb = thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .padding(.horizontal, 8)
            } else if pane.connection.proto == .local {
                Image(nsImage: systemIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
            } else {
                Image(nsImage: item.systemIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
            }

            // File name
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 8)
        .task(id: item.id) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            loadThumbnail()
        }
    }

    private var systemIcon: NSImage {
        let icon = NSWorkspace.shared.icon(forFile: fullPath)
        icon.size = NSSize(width: 128, height: 128)
        return icon
    }

    private func loadThumbnail() {
        thumbnail = nil
        let path = fullPath
        guard pane.connection.proto == .local else { return }
        let url = URL(fileURLWithPath: path)
        let ext = (path as NSString).pathExtension.lowercased()

        // 이미지: CGImageSource로 EXIF orientation 적용
        let imageExts = ["png","jpg","jpeg","gif","webp","heic","bmp","tiff","svg"]
        if imageExts.contains(ext) {
            if let oriented = Self.loadOrientedImage(url: url) {
                thumbnail = oriented
            }
            return
        }

        // 비디오: AVAssetImageGenerator로 회전 적용된 썸네일
        let videoExts = ["mp4","mov","m4v","avi","mkv","webm","ts","mts"]
        if videoExts.contains(ext) {
            Task.detached {
                let img = await Self.generateVideoThumbnail(url: url)
                await MainActor.run { self.thumbnail = img }
            }
            return
        }

        // 기타: QuickLook 썸네일
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 400, height: 320),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            DispatchQueue.main.async {
                if let rep = rep {
                    self.thumbnail = rep.nsImage
                }
            }
        }
    }

    /// EXIF orientation을 적용하여 이미지 로드
    private static func loadOrientedImage(url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        // EXIF orientation 읽기
        var orientation = CGImagePropertyOrientation.up
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = props[kCGImagePropertyOrientation] as? UInt32,
           let o = CGImagePropertyOrientation(rawValue: raw) {
            orientation = o
        }

        // orientation이 기본이면 그대로 반환
        if orientation == .up {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        // CIImage로 orientation 적용
        let ciImage = CIImage(cgImage: cgImage).oriented(orientation)
        let ctx = CIContext()
        guard let oriented = ctx.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return NSImage(cgImage: oriented, size: NSSize(width: oriented.width, height: oriented.height))
    }

    /// 비디오 썸네일 (ffmpeg 사용, Apple Music 접근 권한 방지)
    private static func generateVideoThumbnail(url: URL) async -> NSImage? {
        let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        guard let ffmpegPath = ffmpegCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let tempPath = NSTemporaryDirectory() + "forceftp_thumb_\(UUID().uuidString).jpg"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-i", url.path, "-ss", "00:00:01", "-vframes", "1",
                             "-vf", "scale=400:-1", "-y", tempPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: tempPath),
                  let image = NSImage(contentsOfFile: tempPath) else {
                try? FileManager.default.removeItem(atPath: tempPath)
                return nil
            }
            try? FileManager.default.removeItem(atPath: tempPath)
            return image
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            return nil
        }
    }

    // MARK: - Section builder

    @ViewBuilder
    private func inspectorSection<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 6) {
                    content()
                }
                .padding(.bottom, 8)
            }

            Divider()
        }
    }

    // MARK: - Info row

    @ViewBuilder
    private func pathRow(_ path: String) -> some View {
        let dir = (path as NSString).deletingLastPathComponent
        HStack(alignment: .top) {
            Text("Path")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(path)
                .font(.system(size: 12))
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(3)
                .onTapGesture {
                    pane.navigate(to: dir)
                    pane.tagFilter = nil
                    Task {
                        do {
                            let items = try await FileService.shared.list(
                                connection: pane.connection, path: dir)
                            await MainActor.run { pane.items = items }
                        } catch {}
                    }
                }
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private func toggleRow(_ label: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    // MARK: - Permissions Grid

    private var permissionsGrid: some View {
        VStack(spacing: 4) {
            // Header
            HStack {
                Text("")
                    .frame(width: 60, alignment: .leading)
                Spacer()
                Text("R").font(.system(size: 11, weight: .semibold)).frame(width: 30)
                Text("W").font(.system(size: 11, weight: .semibold)).frame(width: 30)
                Text("X").font(.system(size: 11, weight: .semibold)).frame(width: 30)
            }
            .foregroundStyle(.secondary)

            permRow("Owner", r: $perms.ownerRead, w: $perms.ownerWrite, x: $perms.ownerExec)
            permRow("Group", r: $perms.groupRead, w: $perms.groupWrite, x: $perms.groupExec)
            permRow("Others", r: $perms.otherRead, w: $perms.otherWrite, x: $perms.otherExec)
        }
    }

    @ViewBuilder
    private func permRow(_ label: String,
                         r: Binding<Bool>, w: Binding<Bool>, x: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Spacer()
            Toggle("", isOn: r).toggleStyle(.checkbox).frame(width: 30)
            Toggle("", isOn: w).toggleStyle(.checkbox).frame(width: 30)
            Toggle("", isOn: x).toggleStyle(.checkbox).frame(width: 30)
        }
    }

    // MARK: - Helpers

    private var fileExtension: String {
        let ext = (item.name as NSString).pathExtension
        return ext.isEmpty ? "--" : ext
    }

    private var fileKind: String {
        let ext = (item.name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "Image"
        case "pdf": return "PDF Document"
        case "zip", "tar", "gz", "7z", "rar": return "Archive"
        case "mp4", "mov", "avi", "mkv": return "Video"
        case "mp3", "wav", "aac", "flac": return "Audio"
        case "swift", "js", "ts", "py", "html", "css": return "Source Code"
        case "txt", "md", "rtf": return "Text Document"
        default: return ext.isEmpty ? "Document" : "\(ext.uppercased()) File"
        }
    }

    private func formatDetailedSize(_ n: Int64) -> String {
        let formatted: String
        if n < 1024 {
            formatted = "\(n) bytes"
        } else if n < 1024 * 1024 {
            formatted = String(format: "%.0f KB", Double(n) / 1024.0)
        } else if n < 1024 * 1024 * 1024 {
            formatted = String(format: "%.1f MB", Double(n) / 1024.0 / 1024.0)
        } else {
            formatted = String(format: "%.2f GB", Double(n) / 1024.0 / 1024.0 / 1024.0)
        }
        let bytes = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return "\(formatted) (\(bytes) bytes)"
    }

    private func loadFileAttributes() {
        guard pane.connection.proto == .local else { return }
        let url = URL(fileURLWithPath: fullPath)
        if let vals = try? url.resourceValues(forKeys: [.isUserImmutableKey, .hasHiddenExtensionKey, .isHiddenKey]) {
            isLocked = vals.isUserImmutable ?? false
            hideExtension = vals.hasHiddenExtension ?? false
            isHidden = vals.isHidden ?? item.name.hasPrefix(".")
        }
    }

    // MARK: - Media Info

    struct MediaInfoRow: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        var isHeader = false
    }

    private func loadMediaInfo() {
        mediaInfo = []
        guard pane.connection.proto == .local, !item.isDirectory else { return }
        let path = fullPath
        let ext = (path as NSString).pathExtension.lowercased()

        let imageExts = Set(["png","jpg","jpeg","gif","webp","heic","heif","bmp","tiff","tif","svg","ico"])
        let videoExts = Set(["mp4","mov","m4v","avi","mkv","wmv","flv","webm","ts","mts","3gp"])
        let audioExts = Set(["mp3","aac","m4a","wav","flac","ogg","wma","aiff","aif","opus"])

        if imageExts.contains(ext) {
            loadImageInfo(path: path)
        } else if videoExts.contains(ext) || audioExts.contains(ext) {
            Task.detached {
                let rows = Self.probeMediaInfo(path: path, isAudio: audioExts.contains(ext))
                await MainActor.run { self.mediaInfo = rows }
            }
        }
    }

    private func loadImageInfo(path: String) {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }

        var rows: [MediaInfoRow] = []

        let pw = props[kCGImagePropertyPixelWidth] as? Int
        let ph = props[kCGImagePropertyPixelHeight] as? Int
        if let w = pw, let h = ph {
            rows.append(MediaInfoRow(label: "해상도", value: "\(w) × \(h)"))
            let mp = Double(w * h) / 1_000_000.0
            if mp >= 1 {
                rows.append(MediaInfoRow(label: "화소", value: String(format: "%.1f MP", mp)))
            }
        }

        if let depth = props[kCGImagePropertyDepth] as? Int {
            rows.append(MediaInfoRow(label: "비트 심도", value: "\(depth) bit"))
        }
        if let cs = props[kCGImagePropertyColorModel] as? String {
            rows.append(MediaInfoRow(label: "색상 모델", value: cs))
        }
        if let profileName = props[kCGImagePropertyProfileName] as? String {
            rows.append(MediaInfoRow(label: "색 공간", value: profileName))
        }
        if let dpiW = props[kCGImagePropertyDPIWidth] as? Double {
            rows.append(MediaInfoRow(label: "DPI", value: String(format: "%.0f", dpiW)))
        }
        if let hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool {
            rows.append(MediaInfoRow(label: "투명도", value: hasAlpha ? "있음" : "없음"))
        }

        // EXIF
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            var exifRows: [MediaInfoRow] = []

            if let dateStr = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                exifRows.append(MediaInfoRow(label: "촬영 일시", value: dateStr.replacingOccurrences(of: ":", with: "/", options: [], range: dateStr.startIndex..<dateStr.index(dateStr.startIndex, offsetBy: min(10, dateStr.count)))))
            }
            if let fNum = exif[kCGImagePropertyExifFNumber] as? Double {
                exifRows.append(MediaInfoRow(label: "조리개", value: String(format: "f/%.1f", fNum)))
            }
            if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double {
                if exposure >= 1 {
                    exifRows.append(MediaInfoRow(label: "셔터 속도", value: String(format: "%.1f초", exposure)))
                } else {
                    exifRows.append(MediaInfoRow(label: "셔터 속도", value: "1/\(Int(round(1.0 / exposure)))초"))
                }
            }
            if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = iso.first {
                exifRows.append(MediaInfoRow(label: "ISO", value: "\(first)"))
            }
            if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
                exifRows.append(MediaInfoRow(label: "초점 거리", value: String(format: "%.0fmm", focal)))
            }
            if let focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int {
                exifRows.append(MediaInfoRow(label: "35mm 환산", value: "\(focal35)mm"))
            }
            if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double, bias != 0 {
                exifRows.append(MediaInfoRow(label: "노출 보정", value: String(format: "%+.1f EV", bias)))
            }
            if let flash = exif[kCGImagePropertyExifFlash] as? Int {
                exifRows.append(MediaInfoRow(label: "플래시", value: (flash & 1) != 0 ? "사용" : "미사용"))
            }
            if let wm = exif[kCGImagePropertyExifWhiteBalance] as? Int {
                exifRows.append(MediaInfoRow(label: "화이트밸런스", value: wm == 0 ? "자동" : "수동"))
            }
            if let lensModel = exif[kCGImagePropertyExifLensModel] as? String {
                exifRows.append(MediaInfoRow(label: "렌즈", value: lensModel))
            }

            if !exifRows.isEmpty {
                rows.append(MediaInfoRow(label: "촬영 정보", value: "", isHeader: true))
                rows.append(contentsOf: exifRows)
            }
        }

        // TIFF (카메라 모델)
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let make = tiff[kCGImagePropertyTIFFMake] as? String,
               let model = tiff[kCGImagePropertyTIFFModel] as? String {
                let camera = model.hasPrefix(make) ? model : "\(make) \(model)"
                rows.insert(MediaInfoRow(label: "카메라", value: camera),
                           at: rows.firstIndex(where: { $0.isHeader }) ?? rows.endIndex)
            }
        }

        // GPS
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
               let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
                let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
                let latVal = latRef == "S" ? -lat : lat
                let lonVal = lonRef == "W" ? -lon : lon
                rows.append(MediaInfoRow(label: "GPS", value: String(format: "%.4f, %.4f", latVal, lonVal)))
            }
            if let alt = gps[kCGImagePropertyGPSAltitude] as? Double {
                rows.append(MediaInfoRow(label: "고도", value: String(format: "%.0fm", alt)))
            }
        }

        mediaInfo = rows
    }

    private static func probeMediaInfo(path: String, isAudio: Bool) -> [MediaInfoRow] {
        let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
        guard let ffprobe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return []
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffprobe)
        proc.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format", "-show_streams",
            path
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var rows: [MediaInfoRow] = []
        let streams = json["streams"] as? [[String: Any]] ?? []
        let format = json["format"] as? [String: Any]

        // 동영상 스트림
        if let video = streams.first(where: { ($0["codec_type"] as? String) == "video" }) {
            let w = video["width"] as? Int
            let h = video["height"] as? Int
            if let w, let h {
                rows.append(MediaInfoRow(label: "해상도", value: "\(w) × \(h)"))
            }
            if let codec = video["codec_long_name"] as? String ?? video["codec_name"] as? String {
                rows.append(MediaInfoRow(label: "비디오 코덱", value: codec))
            }
            if let profile = video["profile"] as? String, profile != "unknown" {
                rows.append(MediaInfoRow(label: "프로파일", value: profile))
            }
            if let pixFmt = video["pix_fmt"] as? String {
                rows.append(MediaInfoRow(label: "픽셀 포맷", value: pixFmt))
            }
            if let fpsStr = video["r_frame_rate"] as? String {
                let parts = fpsStr.split(separator: "/")
                if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d > 0 {
                    let fps = n / d
                    rows.append(MediaInfoRow(label: "프레임레이트", value: String(format: "%.2f fps", fps)))
                }
            }
            if let br = video["bit_rate"] as? String, let brInt = Int(br) {
                rows.append(MediaInfoRow(label: "비디오 비트레이트", value: formatBitrate(brInt)))
            }
        }

        // 오디오 스트림
        if let audio = streams.first(where: { ($0["codec_type"] as? String) == "audio" }) {
            if !isAudio { rows.append(MediaInfoRow(label: "오디오", value: "", isHeader: true)) }
            if let codec = audio["codec_long_name"] as? String ?? audio["codec_name"] as? String {
                rows.append(MediaInfoRow(label: "오디오 코덱", value: codec))
            }
            if let sr = audio["sample_rate"] as? String, let srInt = Int(sr) {
                rows.append(MediaInfoRow(label: "샘플레이트", value: "\(srInt / 1000) kHz"))
            }
            if let ch = audio["channels"] as? Int {
                let chStr: String
                switch ch {
                case 1: chStr = "모노"
                case 2: chStr = "스테레오"
                case 6: chStr = "5.1ch"
                case 8: chStr = "7.1ch"
                default: chStr = "\(ch)ch"
                }
                rows.append(MediaInfoRow(label: "채널", value: chStr))
            }
            if let br = audio["bit_rate"] as? String, let brInt = Int(br) {
                rows.append(MediaInfoRow(label: "오디오 비트레이트", value: formatBitrate(brInt)))
            }
            if let bitsPerSample = audio["bits_per_raw_sample"] as? String, let bits = Int(bitsPerSample), bits > 0 {
                rows.append(MediaInfoRow(label: "비트 심도", value: "\(bits) bit"))
            }
        }

        // 포맷 정보
        if let dur = format?["duration"] as? String, let durSec = Double(dur) {
            let total = Int(durSec)
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            let durStr = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
            rows.insert(MediaInfoRow(label: "재생 시간", value: durStr), at: 0)
        }
        if let br = format?["bit_rate"] as? String, let brInt = Int(br) {
            rows.append(MediaInfoRow(label: "전체 비트레이트", value: formatBitrate(brInt)))
        }
        if let formatName = format?["format_long_name"] as? String {
            rows.append(MediaInfoRow(label: "컨테이너", value: formatName))
        }

        return rows
    }

    private static func formatBitrate(_ bps: Int) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bps) / 1_000_000)
        } else {
            return "\(bps / 1000) kbps"
        }
    }

    private func applyPermissions() {
        let octal = perms.octal
        let conn = pane.connection
        let path = fullPath
        let itemId = item.id
        Task {
            do {
                if conn.proto == .local {
                    // 로컬: FileManager로 직접 권한 변경
                    guard let mode = UInt16(octal, radix: 8) else {
                        throw NSError(domain: "InspectorView", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: "잘못된 권한 값: \(octal)"])
                    }
                    try FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: mode)],
                        ofItemAtPath: path
                    )
                    app.appendLog(.ok, "권한 변경: \(item.name) → \(octal)")

                    // owner/group (chown은 root 권한 필요할 수 있음)
                    if ownerName != item.owner || groupName != item.group {
                        try await FileService.shared.chown(
                            connection: conn, path: path,
                            owner: ownerName, group: groupName
                        )
                        app.appendLog(.ok, "소유자 변경: \(ownerName):\(groupName)")
                    }

                    // hidden / locked / hideExtension
                    var url = URL(fileURLWithPath: path)
                    var resValues = URLResourceValues()
                    var changed = false

                    let curHidden = (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden ?? false
                    if curHidden != isHidden {
                        resValues.isHidden = isHidden
                        changed = true
                        app.appendLog(.ok, "숨김 속성 변경: \(isHidden ? "숨김" : "표시")")
                    }

                    let curLocked = (try? url.resourceValues(forKeys: [.isUserImmutableKey]))?.isUserImmutable ?? false
                    if curLocked != isLocked {
                        resValues.isUserImmutable = isLocked
                        changed = true
                        app.appendLog(.ok, "잠금 속성 변경: \(isLocked ? "잠금" : "해제")")
                    }

                    let curHideExt = (try? url.resourceValues(forKeys: [.hasHiddenExtensionKey]))?.hasHiddenExtension ?? false
                    if curHideExt != hideExtension {
                        resValues.hasHiddenExtension = hideExtension
                        changed = true
                        app.appendLog(.ok, "확장자 숨김: \(hideExtension ? "숨김" : "표시")")
                    }

                    if changed {
                        try url.setResourceValues(resValues)
                    }
                } else {
                    // 원격 서버: FileService 사용
                    try await FileService.shared.chmod(
                        connection: conn, path: path,
                        octal: octal, recursive: false
                    )
                    app.appendLog(.ok, "권한 변경: \(item.name) → \(octal)")

                    if ownerName != item.owner || groupName != item.group {
                        try await FileService.shared.chown(
                            connection: conn, path: path,
                            owner: ownerName, group: groupName
                        )
                        app.appendLog(.ok, "소유자 변경: \(ownerName):\(groupName)")
                    }
                }

                // 깜빡임 방지: 전체 리로드 대신 해당 항목만 업데이트
                await MainActor.run {
                    if let idx = pane.items.firstIndex(where: { $0.id == itemId }) {
                        var updated = pane.items[idx]
                        updated.permissions = perms.symbolic
                        updated.owner = ownerName
                        updated.group = groupName
                        pane.items[idx] = updated
                    }
                }
            } catch {
                app.appendLog(.error, "적용 실패: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - QR Code Detection

    private func detectQRCode() {
        qrContent = nil
        guard pane.connection.proto == .local else { return }
        let path = fullPath
        let ext = (path as NSString).pathExtension.lowercased()
        let imageExts = ["png","jpg","jpeg","gif","webp","heic","bmp","tiff"]
        guard imageExts.contains(ext) else { return }

        Task.detached {
            guard let ciImage = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return }
            let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                                       context: nil,
                                       options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            guard let features = detector?.features(in: ciImage),
                  let qr = features.first as? CIQRCodeFeature,
                  let message = qr.messageString, !message.isEmpty else { return }
            let parsed = QRContent.parse(message)
            await MainActor.run { self.qrContent = parsed }
        }
    }

    @ViewBuilder
    private func qrContentView(_ qr: QRContent) -> some View {
        switch qr {
        case .url(let urlString):
            qrCard {
                // 웹 링크 미리보기 카드
                HStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 24))
                        .foregroundStyle(.blue)
                        .frame(width: 40, height: 40)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("웹 링크")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(urlString)
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                qrActionButton("Safari에서 열기", icon: "safari", color: .blue) {
                    if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
                }
                qrActionButton("링크 복사", icon: "doc.on.doc", color: .secondary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urlString, forType: .string)
                    app.appendLog(.ok, "링크 복사됨")
                }
            }

        case .wifi(let ssid, let password, let security):
            qrCard {
                // WiFi 설정 카드
                HStack(spacing: 10) {
                    Image(systemName: "wifi")
                        .font(.system(size: 22))
                        .foregroundStyle(.green)
                        .frame(width: 40, height: 40)
                        .background(Color.green.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wi-Fi 네트워크")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(ssid)
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                Divider().padding(.vertical, 2)
                qrDetailRow(icon: "lock.shield", label: "보안", value: security.isEmpty ? "없음" : security)
                if !password.isEmpty {
                    qrDetailRow(icon: "key", label: "비밀번호", value: password, mono: true)
                }
                qrActionButton("Wi-Fi 연결 (설정 열기)", icon: "wifi.circle", color: .blue) {
                    Self.connectToWiFi(ssid: ssid, password: password)
                }
                qrActionButton("비밀번호 복사", icon: "doc.on.doc", color: .green) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(password, forType: .string)
                    app.appendLog(.ok, "비밀번호 복사됨")
                }
            }

        case .vCard(let info):
            qrCard {
                // 연락처 카드 (macOS 연락처 앱 스타일)
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Text(String(info.name.prefix(1)).uppercased())
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.name)
                            .font(.system(size: 15, weight: .semibold))
                        if !info.title.isEmpty || !info.org.isEmpty {
                            Text([info.title, info.org].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !info.phones.isEmpty || !info.emails.isEmpty {
                    Divider().padding(.vertical, 4)
                }
                ForEach(Array(info.phones.enumerated()), id: \.offset) { _, phone in
                    qrContactRow(icon: "phone.fill", iconColor: .green, label: "전화", value: formatPhoneNumber(phone)) {
                        if let url = URL(string: "tel:\(phone)") { NSWorkspace.shared.open(url) }
                    }
                }
                ForEach(Array(info.emails.enumerated()), id: \.offset) { _, email in
                    qrContactRow(icon: "envelope.fill", iconColor: .blue, label: "이메일", value: email) {
                        if let url = URL(string: "mailto:\(email)") { NSWorkspace.shared.open(url) }
                    }
                }
                if !info.address.isEmpty {
                    qrContactRow(icon: "mappin.circle.fill", iconColor: .red, label: "주소", value: info.address) {}
                }
                if !info.url.isEmpty {
                    qrContactRow(icon: "globe", iconColor: .blue, label: "웹사이트", value: info.url) {
                        if let url = URL(string: info.url) { NSWorkspace.shared.open(url) }
                    }
                }
                if !info.birthday.isEmpty {
                    qrDetailRow(icon: "gift", label: "생일", value: info.birthday)
                }
                if !info.note.isEmpty {
                    qrDetailRow(icon: "note.text", label: "메모", value: info.note)
                }
                qrActionButton("연락처에 추가", icon: "person.badge.plus", color: .blue) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.name, forType: .string)
                    app.appendLog(.ok, "연락처 복사됨: \(info.name)")
                }
            }

        case .email(let addr, let subject, let body):
            qrCard {
                HStack(spacing: 10) {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                        .frame(width: 40, height: 40)
                        .background(Color.blue.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("이메일")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(addr)
                            .font(.system(size: 13, weight: .medium))
                            .textSelection(.enabled)
                    }
                }
                if !subject.isEmpty {
                    Divider().padding(.vertical, 2)
                    qrDetailRow(icon: "text.alignleft", label: "제목", value: subject)
                }
                if !body.isEmpty {
                    qrDetailRow(icon: "doc.text", label: "내용", value: body)
                }
                qrActionButton("메일 작성", icon: "envelope.open", color: .blue) {
                    var mailto = "mailto:\(addr)"
                    var params: [String] = []
                    if !subject.isEmpty { params.append("subject=\(subject)") }
                    if !body.isEmpty { params.append("body=\(body)") }
                    if !params.isEmpty { mailto += "?" + params.joined(separator: "&") }
                    if let url = URL(string: mailto) { NSWorkspace.shared.open(url) }
                }
            }

        case .phone(let number):
            qrCard {
                HStack(spacing: 10) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                        .frame(width: 40, height: 40)
                        .background(Color.green.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("전화번호")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(formatPhoneNumber(number))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .textSelection(.enabled)
                    }
                }
                qrActionButton("FaceTime", icon: "video.fill", color: .green) {
                    if let url = URL(string: "facetime:\(number)") { NSWorkspace.shared.open(url) }
                }
                qrActionButton("번호 복사", icon: "doc.on.doc", color: .secondary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(number, forType: .string)
                    app.appendLog(.ok, "번호 복사됨")
                }
            }

        case .sms(let number, let body):
            qrCard {
                HStack(spacing: 10) {
                    Image(systemName: "message.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.green)
                        .frame(width: 40, height: 40)
                        .background(Color.green.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("문자 메시지")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 4)

                // 받는 사람
                HStack(spacing: 8) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("받는 사람")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(formatPhoneNumber(number))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .textSelection(.enabled)
                    }
                }

                // 내용
                if !body.isEmpty {
                    Divider().padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text("내용")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Text(body)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(8)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                Divider().padding(.vertical, 4)
                qrActionButton("메시지 보내기", icon: "paperplane.fill", color: .green) {
                    var smsURL = "sms:\(number)"
                    if !body.isEmpty {
                        smsURL += "?body=\(body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body)"
                    }
                    if let url = URL(string: smsURL) { NSWorkspace.shared.open(url) }
                }
                qrActionButton("번호 복사", icon: "doc.on.doc", color: .secondary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(number, forType: .string)
                    app.appendLog(.ok, "번호 복사됨")
                }
            }

        case .calendar(let event):
            qrCard {
                HStack(spacing: 10) {
                    VStack(spacing: 0) {
                        Text(Self.calendarMonth(event.dtstart))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.red)
                            .textCase(.uppercase)
                        Text(Self.calendarDay(event.dtstart))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                    .frame(width: 40, height: 40)
                    .background(Color(white: 0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.summary.isEmpty ? "일정" : event.summary)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2)
                    }
                }
                Divider().padding(.vertical, 4)
                qrDetailRow(icon: "clock", label: "시작", value: Self.formatEventDate(event.dtstart))
                if !event.dtend.isEmpty {
                    qrDetailRow(icon: "clock.badge.checkmark", label: "종료", value: Self.formatEventDate(event.dtend))
                }
                if !event.location.isEmpty {
                    qrDetailRow(icon: "mappin.and.ellipse", label: "장소", value: event.location)
                }
                if !event.organizer.isEmpty {
                    qrDetailRow(icon: "person", label: "주최", value: event.organizer.replacingOccurrences(of: "mailto:", with: ""))
                }
                if !event.description_.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("설명")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(event.description_.replacingOccurrences(of: "\\n", with: "\n"))
                            .font(.system(size: 11))
                            .lineLimit(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                qrActionButton("캘린더에 추가", icon: "calendar.badge.plus", color: .red) {
                    Self.addToCalendar(event)
                }
            }

        case .bank(let info):
            qrCard {
                HStack(spacing: 10) {
                    Image(systemName: "banknote")
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                        .frame(width: 40, height: 40)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("은행 정보")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        if !info.bankName.isEmpty {
                            Text(info.bankName)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                }
                Divider().padding(.vertical, 4)
                if !info.accountHolder.isEmpty {
                    qrDetailRow(icon: "person", label: "예금주", value: info.accountHolder)
                }
                if !info.accountNumber.isEmpty {
                    qrDetailRow(icon: "number", label: "계좌번호", value: info.accountNumber, mono: true)
                }
                if !info.amount.isEmpty {
                    let formatted: String = {
                        let digits = info.amount.filter(\.isNumber)
                        guard let num = Int(digits) else { return info.amount }
                        let fmt = NumberFormatter()
                        fmt.numberStyle = .decimal
                        return fmt.string(from: NSNumber(value: num)) ?? info.amount
                    }()
                    qrDetailRow(icon: "wonsign.circle", label: "금액", value: formatted)
                }
                ForEach(Array(info.fields.enumerated()), id: \.offset) { _, field in
                    if !field.value.isEmpty {
                        qrDetailRow(icon: "doc.text", label: field.key.isEmpty ? "정보" : field.key, value: field.value)
                    }
                }
                if !info.accountNumber.isEmpty {
                    qrActionButton("계좌번호 복사", icon: "doc.on.doc", color: .orange) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(info.accountNumber, forType: .string)
                        app.appendLog(.ok, "계좌번호 복사됨")
                    }
                }
            }

        case .geo(let lat, let lon):
            qrCard {
                HStack(spacing: 10) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)
                        .frame(width: 40, height: 40)
                        .background(Color.red.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("위치")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.4f", lat)), \(String(format: "%.4f", lon))")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                }
                // 지도 미리보기
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))) {
                    Marker("", coordinate: coord)
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)

                qrActionButton("지도에서 열기", icon: "map", color: .red) {
                    if let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                qrActionButton("좌표 복사", icon: "doc.on.doc", color: .secondary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(lat), \(lon)", forType: .string)
                    app.appendLog(.ok, "좌표 복사됨")
                }
            }

        case .text(let content):
            qrCard {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 20))
                        .foregroundStyle(.orange)
                        .frame(width: 40, height: 40)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("텍스트")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(content)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(white: 0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                qrActionButton("복사", icon: "doc.on.doc", color: .orange) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    app.appendLog(.ok, "텍스트 복사됨")
                }
            }
        }
    }

    // MARK: - QR Card Components

    @ViewBuilder
    private func qrCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func qrDetailRow(icon: String, label: String, value: String, mono: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func qrContactRow(icon: String, iconColor: Color, label: String, value: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 20, height: 20)
                .background(iconColor.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }

    @ViewBuilder
    private func qrActionButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Calendar Helpers

    private static func parseEventDate(_ str: String) -> Date? {
        let clean = str.trimmingCharacters(in: .whitespaces)
        let fmts = ["yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmmss", "yyyyMMdd"]
        for fmt in fmts {
            let df = DateFormatter()
            df.dateFormat = fmt
            if fmt.hasSuffix("'Z'") { df.timeZone = TimeZone(identifier: "UTC") }
            if let d = df.date(from: clean) { return d }
        }
        return nil
    }

    private static func formatEventDate(_ str: String) -> String {
        guard let date = parseEventDate(str) else { return str }
        let df = DateFormatter()
        df.dateFormat = "yyyy년 M월 d일 (E) a h:mm"
        df.locale = Locale(identifier: "ko_KR")
        return df.string(from: date)
    }

    private static func calendarMonth(_ str: String) -> String {
        guard let date = parseEventDate(str) else { return "" }
        let df = DateFormatter()
        df.dateFormat = "MMM"
        df.locale = Locale(identifier: "ko_KR")
        return df.string(from: date)
    }

    private static func calendarDay(_ str: String) -> String {
        guard let date = parseEventDate(str) else { return "" }
        let df = DateFormatter()
        df.dateFormat = "d"
        return df.string(from: date)
    }

    private static func addToCalendar(_ event: CalendarEventInfo) {
        // .ics 파일 생성 후 열기 → 캘린더 앱이 자동으로 처리
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//ForceFTP//QR//KO
        BEGIN:VEVENT
        SUMMARY:\(event.summary)
        DTSTART:\(event.dtstart)
        DTEND:\(event.dtend.isEmpty ? event.dtstart : event.dtend)
        LOCATION:\(event.location)
        DESCRIPTION:\(event.description_)
        END:VEVENT
        END:VCALENDAR
        """
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qr_event.ics")
        try? ics.write(to: tmpURL, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(tmpURL)
    }

    // MARK: - WiFi Helper

    private static func connectToWiFi(ssid: String, password: String) {
        // networksetup 또는 시스템 환경설정으로 WiFi 설정 열기
        let script = """
        tell application "System Preferences"
            activate
            reveal pane id "com.apple.preference.network"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
        // SSID와 비밀번호 클립보드에 복사
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
    }
}

// MARK: - Phone Number Formatter

private func formatPhoneNumber(_ raw: String) -> String {
    let digits = raw.filter { $0.isNumber || $0 == "+" }
    // 한국 번호: 010-1234-5678, 02-123-4567, 031-123-4567
    let d = digits.hasPrefix("+82") ? "0" + digits.dropFirst(3) : (digits.hasPrefix("+") ? String(digits.dropFirst()) : digits)
    let count = d.count
    if count == 11 && d.hasPrefix("01") {
        let i3 = d.index(d.startIndex, offsetBy: 3)
        let i7 = d.index(d.startIndex, offsetBy: 7)
        return "\(d[d.startIndex..<i3])-\(d[i3..<i7])-\(d[i7...])"
    }
    if count == 10 && d.hasPrefix("02") {
        let i2 = d.index(d.startIndex, offsetBy: 2)
        let i6 = d.index(d.startIndex, offsetBy: 6)
        return "\(d[d.startIndex..<i2])-\(d[i2..<i6])-\(d[i6...])"
    }
    if count == 10 {
        let i3 = d.index(d.startIndex, offsetBy: 3)
        let i6 = d.index(d.startIndex, offsetBy: 6)
        return "\(d[d.startIndex..<i3])-\(d[i3..<i6])-\(d[i6...])"
    }
    if count == 9 && d.hasPrefix("02") {
        let i2 = d.index(d.startIndex, offsetBy: 2)
        let i5 = d.index(d.startIndex, offsetBy: 5)
        return "\(d[d.startIndex..<i2])-\(d[i2..<i5])-\(d[i5...])"
    }
    // 이미 하이픈 있으면 그대로
    if raw.contains("-") { return raw }
    return raw
}

// MARK: - VCard Info

struct VCardInfo {
    var name = ""
    var phones: [String] = []
    var emails: [String] = []
    var org = ""
    var title = ""
    var address = ""
    var url = ""
    var note = ""
    var birthday = ""
}

// MARK: - Calendar Event Info

struct CalendarEventInfo {
    var summary = ""
    var location = ""
    var description_ = ""
    var dtstart = ""
    var dtend = ""
    var organizer = ""
}

// MARK: - Bank QR Info

struct BankQRInfo {
    var bankName = ""
    var accountNumber = ""
    var accountHolder = ""
    var amount = ""
    var fields: [(key: String, value: String)] = []
}

// MARK: - QR Content Model

enum QRContent {
    case url(String)
    case wifi(ssid: String, password: String, security: String)
    case vCard(VCardInfo)
    case calendar(CalendarEventInfo)
    case bank(BankQRInfo)
    case email(address: String, subject: String, body: String)
    case phone(String)
    case sms(number: String, body: String)
    case geo(lat: Double, lon: Double)
    case text(String)

    static func parse(_ raw: String) -> QRContent {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // WiFi: WIFI:T:WPA;S:MyNetwork;P:MyPassword;;
        if trimmed.hasPrefix("WIFI:") {
            var ssid = "", password = "", security = ""
            let body = String(trimmed.dropFirst(5))
            for part in body.components(separatedBy: ";") {
                if part.hasPrefix("S:") { ssid = String(part.dropFirst(2)) }
                else if part.hasPrefix("P:") { password = String(part.dropFirst(2)) }
                else if part.hasPrefix("T:") { security = String(part.dropFirst(2)) }
            }
            return .wifi(ssid: ssid, password: password, security: security)
        }

        // vCard
        if trimmed.hasPrefix("BEGIN:VCARD") {
            var info = VCardInfo()
            for line in trimmed.components(separatedBy: .newlines) {
                let upper = line.uppercased()
                if upper.hasPrefix("FN:") {
                    info.name = String(line.dropFirst(3))
                } else if upper.hasPrefix("N:") && info.name.isEmpty {
                    // N:Last;First;Middle;Prefix;Suffix
                    let parts = String(line.dropFirst(2)).components(separatedBy: ";")
                    let last = parts.count > 0 ? parts[0] : ""
                    let first = parts.count > 1 ? parts[1] : ""
                    info.name = "\(first) \(last)".trimmingCharacters(in: .whitespaces)
                } else if upper.hasPrefix("TEL") {
                    if let idx = line.firstIndex(of: ":") {
                        let val = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                        if !val.isEmpty { info.phones.append(val) }
                    }
                } else if upper.hasPrefix("EMAIL") {
                    if let idx = line.firstIndex(of: ":") {
                        let val = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                        if !val.isEmpty { info.emails.append(val) }
                    }
                } else if upper.hasPrefix("ORG:") || upper.hasPrefix("ORG;") {
                    if let idx = line.firstIndex(of: ":") {
                        info.org = String(line[line.index(after: idx)...]).replacingOccurrences(of: ";", with: " ")
                    }
                } else if upper.hasPrefix("TITLE:") || upper.hasPrefix("TITLE;") {
                    if let idx = line.firstIndex(of: ":") { info.title = String(line[line.index(after: idx)...]) }
                } else if upper.hasPrefix("ADR") {
                    if let idx = line.firstIndex(of: ":") {
                        let raw = String(line[line.index(after: idx)...])
                        // ADR: PO;Ext;Street;City;Region;Zip;Country
                        let parts = raw.components(separatedBy: ";").filter { !$0.isEmpty }
                        info.address = parts.joined(separator: " ")
                    }
                } else if upper.hasPrefix("URL") {
                    if let idx = line.firstIndex(of: ":") { info.url = String(line[line.index(after: idx)...]) }
                } else if upper.hasPrefix("NOTE:") || upper.hasPrefix("NOTE;") {
                    if let idx = line.firstIndex(of: ":") { info.note = String(line[line.index(after: idx)...]) }
                } else if upper.hasPrefix("BDAY:") {
                    info.birthday = String(line.dropFirst(5))
                }
            }
            return .vCard(info)
        }

        // Calendar (VEVENT)
        if trimmed.contains("BEGIN:VEVENT") {
            var event = CalendarEventInfo()
            for line in trimmed.components(separatedBy: .newlines) {
                let upper = line.uppercased()
                if upper.hasPrefix("SUMMARY:") { event.summary = String(line.dropFirst(8)) }
                else if upper.hasPrefix("LOCATION:") { event.location = String(line.dropFirst(9)) }
                else if upper.hasPrefix("DESCRIPTION:") { event.description_ = String(line.dropFirst(12)) }
                else if upper.hasPrefix("DTSTART") {
                    if let idx = line.firstIndex(of: ":") { event.dtstart = String(line[line.index(after: idx)...]) }
                }
                else if upper.hasPrefix("DTEND") {
                    if let idx = line.firstIndex(of: ":") { event.dtend = String(line[line.index(after: idx)...]) }
                }
                else if upper.hasPrefix("ORGANIZER") {
                    if let idx = line.firstIndex(of: ":") { event.organizer = String(line[line.index(after: idx)...]) }
                }
            }
            return .calendar(event)
        }

        // Bank QR
        if trimmed.uppercased().contains("BANK") || trimmed.hasPrefix("bank:") || trimmed.hasPrefix("BANK:") {
            var info = BankQRInfo()
            // key:value 또는 key=value 형식 파싱
            let lines = trimmed.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "|;&")))
            for line in lines {
                let trimLine = line.trimmingCharacters(in: .whitespaces)
                // URL이나 의미 없는 줄 건너뛰기
                if trimLine.lowercased().hasPrefix("http://") || trimLine.lowercased().hasPrefix("https://") { continue }
                if trimLine.lowercased() == "bank" || trimLine.lowercased() == "type" { continue }
                let sep: Character = line.contains("=") ? "=" : ":"
                guard let idx = line.firstIndex(of: sep) else {
                    if !trimLine.isEmpty {
                        info.fields.append((key: "", value: trimLine))
                    }
                    continue
                }
                let key = String(line[line.startIndex..<idx]).trimmingCharacters(in: .whitespaces).uppercased()
                let rawVal = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                let val = rawVal.removingPercentEncoding ?? rawVal
                switch key {
                case "BANK", "BANKNAME", "BANK_NAME":
                    info.bankName = val
                case "ACCOUNT", "ACCOUNTNUMBER", "ACCOUNT_NUMBER", "ACCT":
                    info.accountNumber = val
                case "NAME", "HOLDER", "ACCOUNT_HOLDER", "ACCOUNTHOLDER":
                    info.accountHolder = val
                case "AMOUNT", "AMT":
                    info.amount = val
                case "TYPE":
                    break
                default:
                    info.fields.append((key: key, value: val))
                }
            }
            return .bank(info)
        }

        // mailto:
        if trimmed.lowercased().hasPrefix("mailto:") {
            let rest = String(trimmed.dropFirst(7))
            let parts = rest.components(separatedBy: "?")
            let addr = parts[0]
            var subject = "", body = ""
            if parts.count > 1 {
                for param in parts[1].components(separatedBy: "&") {
                    if param.lowercased().hasPrefix("subject=") { subject = String(param.dropFirst(8)).removingPercentEncoding ?? "" }
                    else if param.lowercased().hasPrefix("body=") { body = String(param.dropFirst(5)).removingPercentEncoding ?? "" }
                }
            }
            return .email(address: addr, subject: subject, body: body)
        }

        // tel:
        if trimmed.lowercased().hasPrefix("tel:") {
            return .phone(String(trimmed.dropFirst(4)))
        }

        // SMS
        if trimmed.lowercased().hasPrefix("sms:") || trimmed.lowercased().hasPrefix("smsto:") {
            let prefix = trimmed.lowercased().hasPrefix("smsto:") ? 6 : 4
            let rest = String(trimmed.dropFirst(prefix))
            var number = rest
            var smsBody = ""
            // sms:number?body=text 형식
            if let qIdx = rest.firstIndex(of: "?") {
                number = String(rest[rest.startIndex..<qIdx])
                let query = String(rest[rest.index(after: qIdx)...])
                for param in query.components(separatedBy: "&") {
                    if param.lowercased().hasPrefix("body=") {
                        smsBody = String(param.dropFirst(5)).removingPercentEncoding ?? String(param.dropFirst(5))
                    }
                }
            } else if rest.contains(":") {
                // sms:number:body 형식
                let parts = rest.components(separatedBy: ":")
                number = parts[0]
                smsBody = parts.dropFirst().joined(separator: ":")
            }
            return .sms(number: number, body: smsBody)
        }

        // geo:
        if trimmed.lowercased().hasPrefix("geo:") {
            let coords = String(trimmed.dropFirst(4)).components(separatedBy: ",")
            if coords.count >= 2, let lat = Double(coords[0]), let lon = Double(coords[1].components(separatedBy: "?")[0]) {
                return .geo(lat: lat, lon: lon)
            }
        }

        // URL
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return .url(trimmed)
        }

        return .text(trimmed)
    }
}

// MARK: - Multi-selection Inspector

struct MultiInspectorView: View {
    let items: [RemoteItem]
    let side: PaneSide
    @EnvironmentObject var app: AppState

    private var pane: PaneState { app.pane(side) }

    // 권한 필드: nil = 혼합 상태 (비활성)
    @State private var ownerRead: Bool? = nil
    @State private var ownerWrite: Bool? = nil
    @State private var ownerExec: Bool? = nil
    @State private var groupRead: Bool? = nil
    @State private var groupWrite: Bool? = nil
    @State private var groupExec: Bool? = nil
    @State private var otherRead: Bool? = nil
    @State private var otherWrite: Bool? = nil
    @State private var otherExec: Bool? = nil
    @State private var ownerName: String = ""
    @State private var groupName: String = ""
    @State private var ownerMixed = false
    @State private var groupMixed = false
    // 사용자가 활성화한 필드 추적
    @State private var dirtyFields: Set<String> = []

    @State private var showPermissions = true

    private var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    private var folderCount: Int { items.filter { $0.isDirectory }.count }
    private var fileCount: Int { items.filter { !$0.isDirectory }.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 20)

                stackedIcons.frame(height: 160)

                Text("\(items.count)개 항목 선택됨")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.bottom, 4)

                // 요약 정보
                VStack(alignment: .leading, spacing: 6) {
                    if fileCount > 0 { infoRow("파일", "\(fileCount)개") }
                    if folderCount > 0 { infoRow("폴더", "\(folderCount)개") }
                    infoRow("총 크기", formatSize(totalSize))
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                Divider().padding(.vertical, 8).padding(.horizontal, 14)

                // Permissions (remote only)
                if pane.connection.proto != .local {
                    multiSection("Permissions", isExpanded: $showPermissions) {
                        multiPermissionsGrid

                        Divider().padding(.vertical, 4)

                        // Octal
                        HStack {
                            Text("Octal")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(multiOctal)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(red: 0.16, green: 0.16, blue: 0.17))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Divider().padding(.vertical, 4)

                        // Owner
                        HStack {
                            Text("Owner")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            TextField("owner", text: $ownerName)
                                .font(.system(size: 12))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                                .disabled(ownerMixed && !dirtyFields.contains("owner"))
                                .opacity(ownerMixed && !dirtyFields.contains("owner") ? 0.4 : 1)
                                .onTapGesture { dirtyFields.insert("owner") }
                        }

                        HStack {
                            Text("Group")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            TextField("group", text: $groupName)
                                .font(.system(size: 12))
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 120)
                                .disabled(groupMixed && !dirtyFields.contains("group"))
                                .opacity(groupMixed && !dirtyFields.contains("group") ? 0.4 : 1)
                                .onTapGesture { dirtyFields.insert("group") }
                        }
                    }

                }

                if pane.connection.proto != .local {
                    Spacer(minLength: 20)

                    HStack {
                        Spacer()
                        Button("일괄 적용") { applyToAll() }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.16, green: 0.16, blue: 0.17))
        .task(id: items.map(\.id)) {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            computeInitialState()
        }
    }

    // MARK: - Compute initial mixed state

    private func computeInitialState() {
        dirtyFields = []
        let perms = items.map { Permissions(from: $0.permissions, isDirectory: $0.isDirectory) }
        func uniform(_ kp: KeyPath<Permissions, Bool>) -> Bool? {
            let vals = Set(perms.map { $0[keyPath: kp] })
            return vals.count == 1 ? vals.first : nil
        }
        ownerRead = uniform(\.ownerRead)
        ownerWrite = uniform(\.ownerWrite)
        ownerExec = uniform(\.ownerExec)
        groupRead = uniform(\.groupRead)
        groupWrite = uniform(\.groupWrite)
        groupExec = uniform(\.groupExec)
        otherRead = uniform(\.otherRead)
        otherWrite = uniform(\.otherWrite)
        otherExec = uniform(\.otherExec)

        let owners = Set(items.map(\.owner))
        ownerMixed = owners.count > 1
        ownerName = ownerMixed ? "(다중)" : (owners.first ?? "")

        let groups = Set(items.map(\.group))
        groupMixed = groups.count > 1
        groupName = groupMixed ? "(다중)" : (groups.first ?? "")
    }

    // MARK: - Permissions Grid

    private var multiPermissionsGrid: some View {
        VStack(spacing: 4) {
            HStack {
                Text("").frame(width: 60, alignment: .leading)
                Spacer()
                Text("R").font(.system(size: 11, weight: .semibold)).frame(width: 30)
                Text("W").font(.system(size: 11, weight: .semibold)).frame(width: 30)
                Text("X").font(.system(size: 11, weight: .semibold)).frame(width: 30)
            }
            .foregroundStyle(.secondary)

            multiPermRow("Owner", r: $ownerRead, w: $ownerWrite, x: $ownerExec,
                          keys: ["or", "ow", "ox"])
            multiPermRow("Group", r: $groupRead, w: $groupWrite, x: $groupExec,
                          keys: ["gr", "gw", "gx"])
            multiPermRow("Others", r: $otherRead, w: $otherWrite, x: $otherExec,
                          keys: ["tr", "tw", "tx"])
        }
    }

    @ViewBuilder
    private func multiPermRow(_ label: String,
                               r: Binding<Bool?>, w: Binding<Bool?>, x: Binding<Bool?>,
                               keys: [String]) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Spacer()
            mixedToggle(value: r, key: keys[0]).frame(width: 30)
            mixedToggle(value: w, key: keys[1]).frame(width: 30)
            mixedToggle(value: x, key: keys[2]).frame(width: 30)
        }
    }

    @ViewBuilder
    private func mixedToggle(value: Binding<Bool?>, key: String) -> some View {
        let isMixed = value.wrappedValue == nil && !dirtyFields.contains(key)
        let isOn = value.wrappedValue ?? false
        Toggle("", isOn: Binding(
            get: { isOn },
            set: { newVal in
                value.wrappedValue = newVal
                dirtyFields.insert(key)
            }
        ))
        .toggleStyle(.checkbox)
        .disabled(isMixed)
        .opacity(isMixed ? 0.35 : 1)
        .onTapGesture {
            if isMixed {
                value.wrappedValue = false
                dirtyFields.insert(key)
            }
        }
    }

    private var multiOctal: String {
        func bit(_ v: Bool?) -> String { v == nil ? "-" : (v! ? "1" : "0") }
        func digit(_ r: Bool?, _ w: Bool?, _ x: Bool?) -> String {
            if r == nil || w == nil || x == nil {
                return "?"
            }
            let n = (r! ? 4 : 0) + (w! ? 2 : 0) + (x! ? 1 : 0)
            return "\(n)"
        }
        let o = digit(ownerRead, ownerWrite, ownerExec)
        let g = digit(groupRead, groupWrite, groupExec)
        let t = digit(otherRead, otherWrite, otherExec)
        return "\(o)\(g)\(t)"
    }

    // MARK: - Apply

    private func applyToAll() {
        let conn = pane.connection
        // 변경된 필드만 적용
        let applyOwnerPerms = dirtyFields.contains("or") || dirtyFields.contains("ow") || dirtyFields.contains("ox")
        let applyGroupPerms = dirtyFields.contains("gr") || dirtyFields.contains("gw") || dirtyFields.contains("gx")
        let applyOtherPerms = dirtyFields.contains("tr") || dirtyFields.contains("tw") || dirtyFields.contains("tx")
        let applyPerms = applyOwnerPerms || applyGroupPerms || applyOtherPerms
        let applyOwner = dirtyFields.contains("owner")
        let applyGroup = dirtyFields.contains("group")

        guard applyPerms || applyOwner || applyGroup else {
            app.appendLog(.warn, "변경된 항목이 없습니다.")
            return
        }

        Task {
            for item in items {
                let parentDir = pane.parentPath(for: item.id)
                let path = (parentDir as NSString).appendingPathComponent(item.name)

                if applyPerms {
                    // 기존 권한을 기반으로 변경된 필드만 덮어쓰기
                    var p = Permissions(from: item.permissions, isDirectory: item.isDirectory)
                    if dirtyFields.contains("or") { p.ownerRead = ownerRead ?? p.ownerRead }
                    if dirtyFields.contains("ow") { p.ownerWrite = ownerWrite ?? p.ownerWrite }
                    if dirtyFields.contains("ox") { p.ownerExec = ownerExec ?? p.ownerExec }
                    if dirtyFields.contains("gr") { p.groupRead = groupRead ?? p.groupRead }
                    if dirtyFields.contains("gw") { p.groupWrite = groupWrite ?? p.groupWrite }
                    if dirtyFields.contains("gx") { p.groupExec = groupExec ?? p.groupExec }
                    if dirtyFields.contains("tr") { p.otherRead = otherRead ?? p.otherRead }
                    if dirtyFields.contains("tw") { p.otherWrite = otherWrite ?? p.otherWrite }
                    if dirtyFields.contains("tx") { p.otherExec = otherExec ?? p.otherExec }
                    let octal = p.octal
                    do {
                        if conn.proto == .local {
                            guard let mode = UInt16(octal, radix: 8) else { continue }
                            try FileManager.default.setAttributes(
                                [.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path)
                        } else {
                            try await FileService.shared.chmod(
                                connection: conn, path: path, octal: octal, recursive: false)
                        }
                        await MainActor.run {
                            if let idx = pane.items.firstIndex(where: { $0.id == item.id }) {
                                pane.items[idx].permissions = p.symbolic
                            }
                        }
                    } catch {
                        app.appendLog(.error, "권한 변경 실패: \(item.name) — \(error.localizedDescription)")
                    }
                }

                if applyOwner || applyGroup {
                    let o = applyOwner ? ownerName : item.owner
                    let g = applyGroup ? groupName : item.group
                    do {
                        try await FileService.shared.chown(
                            connection: conn, path: path, owner: o, group: g)
                        await MainActor.run {
                            if let idx = pane.items.firstIndex(where: { $0.id == item.id }) {
                                if applyOwner { pane.items[idx].owner = o }
                                if applyGroup { pane.items[idx].group = g }
                            }
                        }
                    } catch {
                        app.appendLog(.error, "소유자 변경 실패: \(item.name) — \(error.localizedDescription)")
                    }
                }
            }
            app.appendLog(.ok, "\(items.count)개 항목에 속성 일괄 적용 완료")
        }
    }

    // MARK: - Section

    @ViewBuilder
    private func multiSection<Content: View>(
        _ title: String, isExpanded: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
            } label: {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 6) { content() }
                    .padding(.bottom, 8)
            }
            Divider()
        }
    }

    // MARK: - Stacked icons

    private var stackedIcons: some View {
        let display = Array(items.prefix(5))
        let count = display.count
        return ZStack {
            ForEach(Array(display.indices), id: \.self) { i in
                let item = display[i]
                let xOff = CGFloat(i - count / 2) * 12
                let rotation = Double(i - count / 2) * 6
                iconView(for: item)
                    .frame(width: 128, height: 128)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .rotationEffect(.degrees(rotation))
                    .offset(x: xOff, y: abs(xOff) * 0.15)
            }
            if items.count > 1 {
                Text("\(items.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(red: 0.78, green: 0.28, blue: 0.51)))
                    .offset(x: CGFloat(min(count, 5) / 2) * 12 + 16, y: -28)
            }
        }
    }

    @ViewBuilder
    private func iconView(for item: RemoteItem) -> some View {
        if pane.connection.proto == .local {
            let parentDir = pane.parentPath(for: item.id)
            let path = (parentDir as NSString).appendingPathComponent(item.name)
            let icon = NSWorkspace.shared.icon(forFile: path)
            Image(nsImage: icon)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            Image(nsImage: item.systemIcon)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Spacer()
            Text(value).font(.system(size: 12))
        }
    }

    private func formatSize(_ n: Int64) -> String {
        if n < 1024 { return "\(n) bytes" }
        if n < 1024 * 1024 { return String(format: "%.0f KB", Double(n) / 1024.0) }
        if n < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(n) / 1024.0 / 1024.0) }
        return String(format: "%.2f GB", Double(n) / 1024.0 / 1024.0 / 1024.0)
    }
}

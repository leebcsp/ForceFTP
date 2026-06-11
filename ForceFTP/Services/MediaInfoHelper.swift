//
//  MediaInfoHelper.swift
//  ForceFTP
//

import Foundation
import CoreImage

struct MediaInfoRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    var isHeader = false
}

enum MediaInfoHelper {

    static func loadInfo(path: String) -> [MediaInfoRow] {
        let ext = (path as NSString).pathExtension.lowercased()

        let imageExts: Set = ["png","jpg","jpeg","gif","webp","heic","heif","bmp","tiff","tif","svg","ico"]
        let videoExts: Set = ["mp4","mov","m4v","avi","mkv","wmv","flv","webm","ts","mts","3gp"]
        let audioExts: Set = ["mp3","aac","m4a","wav","flac","ogg","wma","aiff","aif","opus"]

        if imageExts.contains(ext) {
            return loadImageInfo(path: path)
        } else if videoExts.contains(ext) || audioExts.contains(ext) {
            return probeMediaInfo(path: path, isAudio: audioExts.contains(ext))
        }
        return []
    }

    static func loadImageInfo(path: String) -> [MediaInfoRow] {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [] }

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

        return rows
    }

    static func probeMediaInfo(path: String, isAudio: Bool) -> [MediaInfoRow] {
        let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"]
        guard let ffprobe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return []
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffprobe)
        proc.arguments = [
            "-nostdin", "-v", "quiet",
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

    static func detectQRCode(path: String) -> QRContent? {
        let ext = (path as NSString).pathExtension.lowercased()
        let imageExts = ["png","jpg","jpeg","gif","webp","heic","bmp","tiff"]
        guard imageExts.contains(ext) else { return nil }
        guard let ciImage = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                                   context: nil,
                                   options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        guard let features = detector?.features(in: ciImage),
              let qr = features.first as? CIQRCodeFeature,
              let message = qr.messageString, !message.isEmpty else { return nil }
        return QRContent.parse(message)
    }

    private static func formatBitrate(_ bps: Int) -> String {
        if bps >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bps) / 1_000_000)
        } else {
            return "\(bps / 1000) kbps"
        }
    }
}

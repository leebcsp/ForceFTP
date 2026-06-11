//
//  ConversionService.swift
//  ForceFTP
//
//  파일 변환 서비스: 이미지 포맷, 문서→PDF, 압축, 동영상/오디오 변환
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import CoreImage

final class ConversionService {
    static let shared = ConversionService()
    private init() {}

    // MARK: - File Type Detection

    enum FileCategory {
        case image, document, pdf, video, audio, other
    }

    static func category(for path: String) -> FileCategory {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "bmp", "tiff", "tif", "ico", "svg":
            return .image
        case "pdf":
            return .pdf
        case "doc", "docx", "rtf", "rtfd", "odt", "html", "htm", "txt", "md",
             "pages", "key", "numbers",
             "xls", "xlsx", "ppt", "pptx", "csv":
            return .document
        case "mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm", "ts", "mts", "3gp":
            return .video
        case "mp3", "aac", "m4a", "wav", "flac", "ogg", "wma", "aiff", "aif", "opus":
            return .audio
        default:
            return .other
        }
    }

    // MARK: - Image Conversion

    struct ImageFormat {
        let name: String
        let ext: String
        let utType: UTType

        static let png  = ImageFormat(name: "PNG",  ext: "png",  utType: .png)
        static let jpeg = ImageFormat(name: "JPEG", ext: "jpg",  utType: .jpeg)
        static let heic = ImageFormat(name: "HEIC", ext: "heic", utType: .heic)
        static let tiff = ImageFormat(name: "TIFF", ext: "tiff", utType: .tiff)
        static let bmp  = ImageFormat(name: "BMP",  ext: "bmp",  utType: .bmp)
        static let gif  = ImageFormat(name: "GIF",  ext: "gif",  utType: .gif)

        static let all: [ImageFormat] = [.png, .jpeg, .heic, .tiff, .bmp, .gif]
    }

    func convertImage(at sourcePath: String, to format: ImageFormat,
                       progress: @escaping (String) -> Void,
                       percentProgress: ((Double) -> Void)? = nil,
                       processHandler: ((Process) -> Void)? = nil) async throws -> String {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let baseName = (sourcePath as NSString).deletingPathExtension
        var destPath = "\(baseName).\(format.ext)"
        destPath = uniquePath(destPath)

        progress("이미지 변환 중: \(format.name)...")
        percentProgress?(0.0)

        // sips 사용 (macOS 내장, 고품질)
        let sipsFormat: String
        switch format.ext {
        case "png":  sipsFormat = "png"
        case "jpg":  sipsFormat = "jpeg"
        case "heic": sipsFormat = "heic"
        case "tiff": sipsFormat = "tiff"
        case "bmp":  sipsFormat = "bmp"
        case "gif":  sipsFormat = "gif"
        default:     sipsFormat = format.ext
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = ["-s", "format", sipsFormat, sourcePath, "--out", destPath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        processHandler?(process)
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 15 || process.terminationStatus == 9 {
            try? FileManager.default.removeItem(atPath: destPath)
            throw ConversionError.failed("변환이 취소되었습니다")
        }

        if process.terminationStatus != 0 {
            // sips 실패 시 CoreImage fallback
            try await convertImageWithCoreImage(source: sourceURL, destPath: destPath, format: format)
        }

        guard FileManager.default.fileExists(atPath: destPath) else {
            throw ConversionError.failed("이미지 변환 실패")
        }

        percentProgress?(1.0)
        progress("변환 완료: \((destPath as NSString).lastPathComponent)")
        return destPath
    }

    private func convertImageWithCoreImage(source: URL, destPath: String, format: ImageFormat) async throws {
        guard let ciImage = CIImage(contentsOf: source) else {
            throw ConversionError.failed("이미지를 읽을 수 없습니다")
        }
        let context = CIContext()
        let destURL = URL(fileURLWithPath: destPath)
        let colorSpace = ciImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

        switch format.ext {
        case "png":
            try context.writePNGRepresentation(of: ciImage, to: destURL, format: .RGBA8, colorSpace: colorSpace)
        case "jpg":
            try context.writeJPEGRepresentation(of: ciImage, to: destURL, colorSpace: colorSpace, options: [:])
        case "heic":
            try context.writeHEIFRepresentation(of: ciImage, to: destURL, format: .RGBA8, colorSpace: colorSpace)
        case "tiff":
            try context.writeTIFFRepresentation(of: ciImage, to: destURL, format: .RGBA8, colorSpace: colorSpace)
        default:
            throw ConversionError.failed("지원하지 않는 형식: \(format.name)")
        }
    }

    // MARK: - PDF to Image

    func convertPDFToImages(at sourcePath: String, format: ImageFormat,
                            progress: @escaping (String) -> Void,
                            percentProgress: ((Double) -> Void)? = nil) async throws -> [String] {
        let url = URL(fileURLWithPath: sourcePath)
        guard let pdfDoc = CGPDFDocument(url as CFURL) else {
            throw ConversionError.failed("PDF를 열 수 없습니다")
        }
        let pageCount = pdfDoc.numberOfPages
        guard pageCount > 0 else { throw ConversionError.failed("PDF에 페이지가 없습니다") }

        let baseName = (sourcePath as NSString).deletingPathExtension
        let dir = (sourcePath as NSString).deletingLastPathComponent
        var results: [String] = []

        for i in 1...pageCount {
            percentProgress?(Double(i - 1) / Double(pageCount))
            progress("PDF 변환 중: \(i)/\(pageCount) 페이지...")
            guard let page = pdfDoc.page(at: i) else { continue }
            let mediaBox = page.getBoxRect(.mediaBox)
            let scale: CGFloat = 2.0  // Retina
            let w = Int(mediaBox.width * scale)
            let h = Int(mediaBox.height * scale)

            guard let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }

            ctx.setFillColor(CGColor.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.drawPDFPage(page)

            guard let cgImage = ctx.makeImage() else { continue }

            let suffix = pageCount > 1 ? "_\(i)" : ""
            var destPath = (dir as NSString).appendingPathComponent("\(baseName)\(suffix).\(format.ext)")
            destPath = uniquePath(destPath)

            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: mediaBox.width, height: mediaBox.height))
            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData) else { continue }

            let data: Data?
            switch format.ext {
            case "png":
                data = bitmap.representation(using: .png, properties: [:])
            case "jpg":
                data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            case "tiff":
                data = bitmap.representation(using: .tiff, properties: [:])
            default:
                data = bitmap.representation(using: .png, properties: [:])
            }

            if let data = data {
                try data.write(to: URL(fileURLWithPath: destPath))
                results.append(destPath)
            }
        }

        guard !results.isEmpty else { throw ConversionError.failed("PDF 이미지 변환 실패") }
        percentProgress?(1.0)
        progress("변환 완료: \(results.count)개 이미지")
        return results
    }

    // MARK: - PDF Compression

    func compressPDF(at sourcePath: String, quality: Int,
                     progress: @escaping (String) -> Void,
                     percentProgress: @escaping (Double) -> Void = { _ in },
                     processHandler: @escaping (Process) -> Void = { _ in }) async throws -> String {
        let baseName = ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let dir = (sourcePath as NSString).deletingLastPathComponent
        var destPath = (dir as NSString).appendingPathComponent("\(baseName)_compressed.pdf")
        destPath = uniquePath(destPath)

        let origSize = (try? FileManager.default.attributesOfItem(atPath: sourcePath)[.size] as? Int) ?? 0
        progress("PDF 압축 중 (품질 \(quality)%)...")
        percentProgress(0.0)

        // Ghostscript 품질 설정 매핑
        let gsSetting: String
        switch quality {
        case ...30:  gsSetting = "/screen"
        case ...50:  gsSetting = "/ebook"
        case ...75:  gsSetting = "/printer"
        default:     gsSetting = "/prepress"
        }

        // 1단계: Ghostscript 시도
        let gsPaths = ["/opt/homebrew/bin/gs", "/usr/local/bin/gs", "/usr/bin/gs"]
        var gsPath = gsPaths.first { FileManager.default.fileExists(atPath: $0) }

        if gsPath == nil {
            let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            if let brew = brewPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                progress("Ghostscript 설치 중...")
                percentProgress(0.05)
                let install = Process()
                install.executableURL = URL(fileURLWithPath: brew)
                install.arguments = ["install", "ghostscript"]
                install.standardOutput = FileHandle.nullDevice
                install.standardError = FileHandle.nullDevice
                try? install.run()
                install.waitUntilExit()
                gsPath = gsPaths.first { FileManager.default.fileExists(atPath: $0) }
            }
        }

        if let gs = gsPath {
            progress("Ghostscript로 PDF 압축 중...")
            percentProgress(0.1)

            // gs는 stderr에 페이지 처리 메시지를 출력 — 진행률 파싱을 위해 -dQUIET 제거하고 stderr 캡처
            // 먼저 페이지 수 파악
            let url = URL(fileURLWithPath: sourcePath)
            let pageCount = CGPDFDocument(url as CFURL)?.numberOfPages ?? 0

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: gs)
            proc.arguments = [
                "-sDEVICE=pdfwrite",
                "-dCompatibilityLevel=1.4",
                "-dPDFSETTINGS=\(gsSetting)",
                "-dNOPAUSE", "-dBATCH",
                "-dColorImageDownsampleType=/Bicubic",
                "-dGrayImageDownsampleType=/Bicubic",
                "-dMonoImageDownsampleType=/Bicubic",
                "-sOutputFile=\(destPath)",
                sourcePath
            ]
            proc.standardOutput = FileHandle.nullDevice
            let errPipe = Pipe()
            proc.standardError = errPipe
            processHandler(proc)
            try proc.run()

            // stderr에서 "Page N" 메시지를 읽어 진행률 갱신
            if pageCount > 0 {
                Task.detached {
                    let handle = errPipe.fileHandleForReading
                    var buffer = Data()
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        buffer.append(chunk)
                        if let text = String(data: buffer, encoding: .utf8) {
                            let lines = text.components(separatedBy: .newlines)
                            for line in lines where line.hasPrefix("Page ") {
                                let parts = line.split(separator: " ")
                                if parts.count >= 2, let pg = Int(parts[1]) {
                                    let pct = min(0.95, 0.1 + 0.85 * Double(pg) / Double(pageCount))
                                    percentProgress(pct)
                                }
                            }
                        }
                    }
                }
            }

            proc.waitUntilExit()

            if proc.terminationStatus == 0,
               FileManager.default.fileExists(atPath: destPath) {
                let newSize = (try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? Int) ?? 0
                if newSize > 0 && newSize < origSize {
                    percentProgress(1.0)
                    let ratio = origSize > 0 ? Int(Double(newSize) / Double(origSize) * 100) : 100
                    progress("PDF 압축 완료: \(ratio)% (\(Self.formatFileSize(newSize)))")
                    return destPath
                }
                try? FileManager.default.removeItem(atPath: destPath)
            } else {
                try? FileManager.default.removeItem(atPath: destPath)
            }
        }

        // 2단계: JPEG 래스터 폴백
        let url = URL(fileURLWithPath: sourcePath)
        guard let pdfDoc = CGPDFDocument(url as CFURL) else {
            throw ConversionError.failed("PDF를 열 수 없습니다")
        }
        let pageCount = pdfDoc.numberOfPages
        guard pageCount > 0 else { throw ConversionError.failed("PDF에 페이지가 없습니다") }

        progress("이미지 기반 PDF 압축 중...")
        let jpegQuality = CGFloat(quality) / 100.0

        guard let pdfContext = CGContext(URL(fileURLWithPath: destPath) as CFURL, mediaBox: nil, nil) else {
            throw ConversionError.failed("PDF 생성 실패")
        }

        for i in 1...pageCount {
            guard let page = pdfDoc.page(at: i) else { continue }
            let mediaBox = page.getBoxRect(.mediaBox)
            var box = mediaBox
            pdfContext.beginPage(mediaBox: &box)

            let w = Int(mediaBox.width)
            let h = Int(mediaBox.height)

            if let bitmapCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) {
                bitmapCtx.setFillColor(CGColor.white)
                bitmapCtx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                bitmapCtx.drawPDFPage(page)

                if let cgImage = bitmapCtx.makeImage() {
                    let mutableData = NSMutableData()
                    if let dest = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, cgImage, [
                            kCGImageDestinationLossyCompressionQuality: jpegQuality
                        ] as CFDictionary)
                        CGImageDestinationFinalize(dest)
                        if let source = CGImageSourceCreateWithData(mutableData, nil),
                           let compressedCG = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                            pdfContext.draw(compressedCG, in: mediaBox)
                        }
                    }
                }
            }

            pdfContext.endPage()
            let pct = Double(i) / Double(pageCount)
            percentProgress(pct)
            if i % 5 == 0 || i == pageCount {
                progress("PDF 압축 중: \(i)/\(pageCount) 페이지...")
            }
        }

        pdfContext.closePDF()

        guard FileManager.default.fileExists(atPath: destPath) else {
            throw ConversionError.failed("PDF 압축 실패")
        }

        let newSize = (try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? Int) ?? 0
        if newSize >= origSize {
            try? FileManager.default.removeItem(atPath: destPath)
            throw ConversionError.failed("압축 효과 없음: 원본(\(Self.formatFileSize(origSize)))보다 작아지지 않습니다")
        }

        percentProgress(1.0)
        let ratio = origSize > 0 ? Int(Double(newSize) / Double(origSize) * 100) : 100
        progress("PDF 압축 완료: \(ratio)% (\(Self.formatFileSize(newSize)))")
        return destPath
    }

    private static func formatFileSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    // MARK: - Document to PDF

    func convertToPDF(at sourcePath: String,
                      progress: @escaping (String) -> Void,
                      percentProgress: ((Double) -> Void)? = nil,
                      processHandler: ((Process) -> Void)? = nil) async throws -> String {
        let ext = (sourcePath as NSString).pathExtension.lowercased()
        let baseName = (sourcePath as NSString).deletingPathExtension
        var destPath = "\(baseName).pdf"
        destPath = uniquePath(destPath)

        progress("PDF 변환 중...")
        percentProgress?(0.0)

        // textutil 지원 형식 (doc/docx 제외 — 별도 fallback 체인 처리)
        let textutilOnlyExts = ["txt", "rtf", "rtfd", "html", "htm", "odt", "md"]
        // doc/docx: textutil → soffice → MS Word → qlmanage
        let wordExts = ["doc", "docx"]
        // Office 스프레드시트/프레젠테이션
        let officeExts = ["xls", "xlsx", "ppt", "pptx", "csv"]
        // iWork 앱으로 변환 가능한 형식
        let iworkExts = ["key", "pages", "numbers"]

        if textutilOnlyExts.contains(ext) {
            try await runTextutilToPDF(sourcePath: sourcePath, destPath: destPath)
        } else if wordExts.contains(ext) || officeExts.contains(ext) {
            // soffice(LibreOffice) 찾기/설치
            var soffice = findSoffice()
            if soffice == nil {
                soffice = await installLibreOffice(progress: progress)
            }

            var converted = false

            // 1) doc/docx는 textutil 먼저 시도
            if wordExts.contains(ext) {
                do {
                    try await runTextutilToPDF(sourcePath: sourcePath, destPath: destPath)
                    if FileManager.default.fileExists(atPath: destPath) {
                        // textutil 성공했지만 파일 크기가 0이면 실패로 간주
                        let sz = (try? FileManager.default.attributesOfItem(atPath: destPath)[.size] as? Int) ?? 0
                        converted = sz > 0
                        if !converted { try? FileManager.default.removeItem(atPath: destPath) }
                    }
                } catch {
                    try? FileManager.default.removeItem(atPath: destPath)
                }
            }

            // 2) soffice (LibreOffice)
            if !converted, let s = soffice {
                do {
                    try await runSofficeToPDF(soffice: s, sourcePath: sourcePath, destPath: destPath)
                    converted = FileManager.default.fileExists(atPath: destPath)
                } catch {
                    try? FileManager.default.removeItem(atPath: destPath)
                }
            }

            // 3) MS Office AppleScript fallback
            if !converted {
                if wordExts.contains(ext),
                   FileManager.default.fileExists(atPath: "/Applications/Microsoft Word.app") {
                    do {
                        try await runMSOfficeToPDF(sourcePath: sourcePath, destPath: destPath, appName: "Microsoft Word")
                        converted = FileManager.default.fileExists(atPath: destPath)
                    } catch {
                        try? FileManager.default.removeItem(atPath: destPath)
                    }
                } else if ["ppt", "pptx"].contains(ext),
                          FileManager.default.fileExists(atPath: "/Applications/Microsoft PowerPoint.app") {
                    do {
                        try await runMSOfficeToPDF(sourcePath: sourcePath, destPath: destPath, appName: "Microsoft PowerPoint")
                        converted = FileManager.default.fileExists(atPath: destPath)
                    } catch {
                        try? FileManager.default.removeItem(atPath: destPath)
                    }
                } else if ["xls", "xlsx"].contains(ext),
                          FileManager.default.fileExists(atPath: "/Applications/Microsoft Excel.app") {
                    do {
                        try await runMSOfficeToPDF(sourcePath: sourcePath, destPath: destPath, appName: "Microsoft Excel")
                        converted = FileManager.default.fileExists(atPath: destPath)
                    } catch {
                        try? FileManager.default.removeItem(atPath: destPath)
                    }
                }
            }

            // 4) qlmanage 최종 fallback
            if !converted {
                try await runQlmanageToPDF(sourcePath: sourcePath, destPath: destPath)
            }
        } else if iworkExts.contains(ext) {
            try await runIWorkToPDF(sourcePath: sourcePath, destPath: destPath, ext: ext)
        } else {
            try await runQlmanageToPDF(sourcePath: sourcePath, destPath: destPath)
        }

        guard FileManager.default.fileExists(atPath: destPath) else {
            throw ConversionError.failed("PDF 변환 실패")
        }

        percentProgress?(1.0)
        progress("변환 완료: \((destPath as NSString).lastPathComponent)")
        return destPath
    }

    private func runTextutilToPDF(sourcePath: String, destPath: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "pdf", "-output", destPath, sourcePath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            throw ConversionError.failed("textutil 실패: \(msg)")
        }
    }

    private func runQlmanageToPDF(sourcePath: String, destPath: String) async throws {
        // qlmanage -p -o <dir> 으로 미리보기 PDF 생성
        let destDir = (destPath as NSString).deletingLastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", "-o", destDir, sourcePath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        // qlmanage는 <filename>.qlpreview 폴더를 생성할 수 있음
        let srcName = (sourcePath as NSString).lastPathComponent
        let qlOutput = (destDir as NSString).appendingPathComponent("\(srcName).pdf")
        if FileManager.default.fileExists(atPath: qlOutput) && qlOutput != destPath {
            try FileManager.default.moveItem(atPath: qlOutput, toPath: destPath)
        } else if !FileManager.default.fileExists(atPath: destPath) {
            throw ConversionError.failed("qlmanage로 PDF 생성 실패. 이 파일 형식은 지원되지 않습니다.")
        }
    }

    private func runIWorkToPDF(sourcePath: String, destPath: String, ext: String) async throws {
        let appName: String
        switch ext {
        case "key":     appName = "Keynote"
        case "pages":   appName = "Pages"
        case "numbers": appName = "Numbers"
        default:        throw ConversionError.failed("지원하지 않는 iWork 형식")
        }

        let script = """
        tell application "\(appName)"
            open POSIX file "\(sourcePath)"
            delay 2
            set theDoc to front document
            export theDoc to POSIX file "\(destPath)" as PDF
            close theDoc saving no
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 && !FileManager.default.fileExists(atPath: destPath) {
            // AppleScript 실패 시 qlmanage fallback
            try await runQlmanageToPDF(sourcePath: sourcePath, destPath: destPath)
        }
    }

    private func runMSOfficeToPDF(sourcePath: String, destPath: String, appName: String) async throws {
        let script = """
        tell application "\(appName)"
            open POSIX file "\(sourcePath)"
            delay 3
            set theDoc to active document
            save theDoc in POSIX file "\(destPath)" as save as PDF
            close theDoc saving no
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        if !FileManager.default.fileExists(atPath: destPath) {
            // AppleScript 실패 시 qlmanage fallback
            try await runQlmanageToPDF(sourcePath: sourcePath, destPath: destPath)
        }
    }

    private func findSoffice() -> String? {
        let candidates = [
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice",
            "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func installLibreOffice(progress: @escaping (String) -> Void) async -> String? {
        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let brew = brewPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }
        progress("LibreOffice 설치 중 (최초 1회)...")
        let install = Process()
        install.executableURL = URL(fileURLWithPath: brew)
        install.arguments = ["install", "--cask", "libreoffice"]
        install.standardOutput = FileHandle.nullDevice
        install.standardError = FileHandle.nullDevice
        try? install.run()
        install.waitUntilExit()
        return findSoffice()
    }

    private func runSofficeToPDF(soffice: String, sourcePath: String, destPath: String) async throws {
        let destDir = (destPath as NSString).deletingLastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: soffice)
        process.arguments = ["--headless", "--convert-to", "pdf", "--outdir", destDir, sourcePath]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        // soffice는 원본파일명.pdf로 생성
        let srcName = ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let generated = (destDir as NSString).appendingPathComponent("\(srcName).pdf")
        if generated != destPath && FileManager.default.fileExists(atPath: generated) {
            try FileManager.default.moveItem(atPath: generated, toPath: destPath)
        }

        if !FileManager.default.fileExists(atPath: destPath) {
            throw ConversionError.failed("LibreOffice PDF 변환 실패")
        }
    }

    // MARK: - Compress (ZIP)

    enum CompressionLevel: String, CaseIterable {
        case fastest = "최고 속도"
        case normal  = "보통"
        case best    = "최고 압축"

        var zipFlag: String {
            switch self {
            case .fastest: return "-1"
            case .normal:  return "-6"
            case .best:    return "-9"
            }
        }
    }

    func compress(paths: [String], level: CompressionLevel = .normal,
                  progress: @escaping (String) -> Void,
                  percentProgress: ((Double) -> Void)? = nil,
                  processHandler: ((Process) -> Void)? = nil) async throws -> String {
        guard !paths.isEmpty else { throw ConversionError.failed("압축할 파일이 없습니다") }

        let parentDir: String
        let archiveName: String

        if paths.count == 1 {
            let name = (paths[0] as NSString).lastPathComponent
            parentDir = (paths[0] as NSString).deletingLastPathComponent
            archiveName = "\(name).zip"
        } else {
            parentDir = (paths[0] as NSString).deletingLastPathComponent
            archiveName = "Archive.zip"
        }

        var destPath = (parentDir as NSString).appendingPathComponent(archiveName)
        destPath = uniquePath(destPath)

        progress("압축 중: \(paths.count)개 항목 (\(level.rawValue))...")
        percentProgress?(0.0)

        if level == .normal {
            // ditto 사용 (기본 압축)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.currentDirectoryURL = URL(fileURLWithPath: parentDir)
            var args = ["-c", "-k", "--sequesterRsrc"]
            for path in paths {
                args.append((path as NSString).lastPathComponent)
            }
            args.append(destPath)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            processHandler?(process)
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 15 || process.terminationStatus == 9 {
                try? FileManager.default.removeItem(atPath: destPath)
                throw ConversionError.failed("압축이 취소되었습니다")
            }
            if process.terminationStatus != 0 {
                try await compressWithZip(paths: paths, destPath: destPath, parentDir: parentDir, level: level, processHandler: processHandler)
            }
        } else {
            // zip 명령으로 압축률 지정
            try await compressWithZip(paths: paths, destPath: destPath, parentDir: parentDir, level: level, processHandler: processHandler)
        }

        guard FileManager.default.fileExists(atPath: destPath) else {
            throw ConversionError.failed("압축 실패")
        }

        percentProgress?(1.0)
        progress("압축 완료: \((destPath as NSString).lastPathComponent)")
        return destPath
    }

    private func compressWithZip(paths: [String], destPath: String, parentDir: String, level: CompressionLevel = .normal, processHandler: ((Process) -> Void)? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = URL(fileURLWithPath: parentDir)
        var args = [level.zipFlag, "-r", destPath]
        for path in paths {
            args.append((path as NSString).lastPathComponent)
        }
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        processHandler?(process)
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 15 || process.terminationStatus == 9 {
            throw ConversionError.failed("압축이 취소되었습니다")
        }
        if process.terminationStatus != 0 {
            throw ConversionError.failed("zip 명령 실패")
        }
    }

    // MARK: - Decompress ZIP

    /// ZIP 파일을 같은 디렉토리에 압축 해제하고 생성된 항목 이름 목록을 반환
    /// 파일 1개짜리 ZIP은 폴더 없이 바로 해제
    func decompressZip(at zipPath: String,
                       progress: @escaping (String) -> Void) async throws -> [String] {
        let parentDir = (zipPath as NSString).deletingLastPathComponent

        progress("압축 해제 중: \((zipPath as NSString).lastPathComponent)...")

        // 먼저 임시 디렉토리에 해제하여 내용물 확인
        let tempDir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let ok = try await runDittoExtract(zipPath: zipPath, destDir: tempDir)
        if !ok {
            try await runUnzipExtract(zipPath: zipPath, destDir: tempDir)
        }

        // 실제 항목 (메타 폴더 제외)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: tempDir)) ?? []
        let filtered = contents.filter { !$0.hasPrefix("__MACOSX") && !$0.hasPrefix(".") }

        guard !filtered.isEmpty else {
            throw ConversionError.failed("압축 해제 실패: 내용물 없음")
        }

        var resultNames: [String] = []

        if filtered.count == 1 {
            // 파일 1개: 폴더 없이 바로 상위 디렉토리에 배치
            let itemName = filtered[0]
            let srcPath = (tempDir as NSString).appendingPathComponent(itemName)
            var dstPath = (parentDir as NSString).appendingPathComponent(itemName)
            dstPath = uniquePath(dstPath)
            let finalName = (dstPath as NSString).lastPathComponent
            try FileManager.default.moveItem(atPath: srcPath, toPath: dstPath)
            resultNames.append(finalName)
            progress("압축 해제 완료: \(finalName)")
        } else {
            // 파일 여러개: 폴더에 담아서 배치
            let zipName = ((zipPath as NSString).lastPathComponent as NSString).deletingPathExtension
            var destDir = (parentDir as NSString).appendingPathComponent(zipName)
            destDir = uniquePath(destDir)
            try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
            for name in filtered {
                let src = (tempDir as NSString).appendingPathComponent(name)
                let dst = (destDir as NSString).appendingPathComponent(name)
                try FileManager.default.moveItem(atPath: src, toPath: dst)
            }
            let folderName = (destDir as NSString).lastPathComponent
            resultNames.append(folderName)
            progress("압축 해제 완료: \(folderName) (\(filtered.count)개 항목)")
        }

        return resultNames
    }

    private func runDittoExtract(zipPath: String, destDir: String) async throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipPath, destDir]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func runUnzipExtract(zipPath: String, destDir: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipPath, "-d", destDir]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ConversionError.failed("압축 해제 실패")
        }
    }

    // MARK: - Video Conversion

    struct VideoFormat {
        let name: String
        let ext: String

        static let mp4 = VideoFormat(name: "MP4 (H.264)", ext: "mp4")
        static let mov = VideoFormat(name: "MOV (H.264)", ext: "mov")
        static let m4v = VideoFormat(name: "M4V (H.264)", ext: "m4v")

        static let all: [VideoFormat] = [.mp4, .mov, .m4v]
    }

    func convertVideo(at sourcePath: String, to format: VideoFormat,
                      progress: @escaping (String) -> Void,
                      percentProgress: ((Double) -> Void)? = nil,
                      processHandler: ((Process) -> Void)? = nil) async throws -> String {
        let baseName = (sourcePath as NSString).deletingPathExtension
        var destPath = "\(baseName).\(format.ext)"
        destPath = uniquePath(destPath)

        progress("동영상 변환 중: \(format.name)...")

        guard let ffmpegPath = findExecutable("ffmpeg") else {
            throw ConversionError.failed("ffmpeg가 설치되어 있지 않습니다. brew install ffmpeg")
        }
        let duration = await getMediaDuration(path: sourcePath)
        do {
            try await runFFmpegWithProgress(
                ffmpegPath: ffmpegPath,
                args: ["-i", sourcePath, "-c:v", "libx264", "-c:a", "aac",
                       "-preset", "medium", "-crf", "23", "-y", destPath],
                totalDuration: duration,
                progress: progress,
                percentProgress: percentProgress,
                processHandler: processHandler
            )
        } catch {
            try? FileManager.default.removeItem(atPath: destPath)
            throw error
        }

        guard FileManager.default.fileExists(atPath: destPath) else {
            throw ConversionError.failed("동영상 변환 실패")
        }

        progress("변환 완료: \((destPath as NSString).lastPathComponent)")
        return destPath
    }


    // MARK: - Audio Conversion

    struct AudioFormat {
        let name: String
        let ext: String

        static let mp3  = AudioFormat(name: "MP3",  ext: "mp3")
        static let aac  = AudioFormat(name: "AAC",  ext: "m4a")
        static let wav  = AudioFormat(name: "WAV",  ext: "wav")
        static let aiff = AudioFormat(name: "AIFF", ext: "aiff")
        static let alac = AudioFormat(name: "ALAC", ext: "m4a")

        static let all: [AudioFormat] = [.mp3, .aac, .wav, .aiff, .alac]
    }

    func convertAudio(at sourcePath: String, to format: AudioFormat,
                      progress: @escaping (String) -> Void,
                      percentProgress: ((Double) -> Void)? = nil,
                      processHandler: ((Process) -> Void)? = nil) async throws -> String {
        let baseName = (sourcePath as NSString).deletingPathExtension
        var destPath = "\(baseName).\(format.ext)"
        destPath = uniquePath(destPath)

        progress("오디오 변환 중: \(format.name)...")

        guard let ffmpegPath = findExecutable("ffmpeg") else {
            throw ConversionError.failed("ffmpeg가 설치되어 있지 않습니다. brew install ffmpeg")
        }
        let duration = await getMediaDuration(path: sourcePath)
        let args: [String]
        switch format.ext {
        case "mp3":
            args = ["-i", sourcePath, "-codec:a", "libmp3lame", "-qscale:a", "2", "-y", destPath]
        case "m4a":
            args = ["-i", sourcePath, "-c:a", "aac", "-b:a", "256k", "-y", destPath]
        case "wav":
            args = ["-i", sourcePath, "-c:a", "pcm_s16le", "-y", destPath]
        case "aiff":
            args = ["-i", sourcePath, "-c:a", "pcm_s16be", "-y", destPath]
        default:
            args = ["-i", sourcePath, "-y", destPath]
        }
        do {
            try await runFFmpegWithProgress(
                ffmpegPath: ffmpegPath,
                args: args,
                totalDuration: duration,
                progress: progress,
                percentProgress: percentProgress,
                processHandler: processHandler
            )
        } catch {
            try? FileManager.default.removeItem(atPath: destPath)
            throw error
        }

        guard FileManager.default.fileExists(atPath: destPath) else {
            throw ConversionError.failed("오디오 변환 실패")
        }

        progress("변환 완료: \((destPath as NSString).lastPathComponent)")
        return destPath
    }



    // MARK: - FFmpeg Helper

    private func runFFmpeg(ffmpegPath: String, args: [String],
                           progress: @escaping (String) -> Void) async throws {
        try await runFFmpegWithProgress(ffmpegPath: ffmpegPath, args: args,
                                         totalDuration: nil, progress: progress)
    }

    /// ffmpeg 시간 문자열(HH:MM:SS.xx)을 초로 변환
    private func parseTimeToSeconds(_ timeStr: String) -> Double? {
        let parts = timeStr.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// 원본 미디어 파일 길이(초) 파악
    private func getMediaDuration(path: String) async -> Double? {
        // ffprobe로 길이 파악 (AVURLAsset은 Apple Music 접근 권한 창을 유발)
        if let ffprobePath = findExecutable("ffprobe") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobePath)
            process.arguments = ["-nostdin", "-v", "quiet", "-show_entries", "format=duration",
                                 "-of", "default=noprint_wrappers=1:nokey=1", path]
            process.environment = Self.restrictedEnv
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   let dur = Double(str), dur > 0 {
                    return dur
                }
            } catch {}
        }
        // ffprobe 없으면 ffmpeg -i 로 파싱
        if let ffmpegPath = findExecutable("ffmpeg") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = ["-nostdin", "-i", path]
            process.environment = Self.restrictedEnv
            let pipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8),
                   let range = output.range(of: "Duration: ") {
                    let timeStr = String(output[range.upperBound...].prefix(11))
                    return parseTimeToSeconds(timeStr)
                }
            } catch {}
        }
        return nil
    }

    private func runFFmpegWithProgress(ffmpegPath: String, args: [String],
                                        totalDuration: Double?,
                                        progress: @escaping (String) -> Void,
                                        percentProgress: ((Double) -> Void)? = nil,
                                        processHandler: ((Process) -> Void)? = nil) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-nostdin"] + args
        process.environment = Self.restrictedEnv
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            if line.contains("time=") {
                if let range = line.range(of: "time=") {
                    let timeStr = String(line[range.upperBound...].prefix(11))
                    if let totalDuration, totalDuration > 0,
                       let current = self?.parseTimeToSeconds(timeStr) {
                        let pct = min(1.0, current / totalDuration)
                        DispatchQueue.main.async {
                            progress("변환 중... \(Int(pct * 100))%")
                            percentProgress?(pct)
                        }
                    } else {
                        DispatchQueue.main.async { progress("변환 중... \(timeStr)") }
                    }
                }
            }
        }

        processHandler?(process)
        try process.run()
        process.waitUntilExit()
        handle.readabilityHandler = nil

        if process.terminationStatus != 0 {
            if let destArg = args.last, FileManager.default.fileExists(atPath: destArg) {
                try? FileManager.default.removeItem(atPath: destArg)
            }
            let code = process.terminationStatus
            if code == 15 || code == 9 || code == 255 {
                throw ConversionError.failed("변환이 취소되었습니다")
            }
            throw ConversionError.failed("ffmpeg 변환 실패 (종료 코드: \(code))")
        }
    }

    // MARK: - Utilities

    private func findExecutable(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// AudioToolbox/AVFoundation이 ~/Music 미디어 보관함에 접근하지 못하도록 제한된 환경변수
    static let restrictedEnv: [String: String] = {
        var env: [String: String] = [
            "HOME": "/tmp",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": Locale.current.identifier
        ]
        if let dyld = ProcessInfo.processInfo.environment["DYLD_LIBRARY_PATH"] {
            env["DYLD_LIBRARY_PATH"] = dyld
        }
        return env
    }()

    func uniquePath(_ path: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return path }
        let dir = (path as NSString).deletingLastPathComponent
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let ext = (path as NSString).pathExtension
        var i = 2
        while true {
            let candidate = (dir as NSString).appendingPathComponent("\(name) \(i).\(ext)")
            if !fm.fileExists(atPath: candidate) { return candidate }
            i += 1
        }
    }

    enum ConversionError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let msg): return msg
            }
        }
    }
}


//
//  ForceFTPApp.swift
//  ForceFTP — Mock build (bundled demo file systems)
//

import SwiftUI
import QuickLookThumbnailing

enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "시스템"
        case .light:  return "라이트"
        case .dark:   return "다크"
        }
    }

    var icon: String {
        switch self {
        case .light:  return "sun.max"
        case .dark:   return "moon"
        case .system: return "circle.lefthalf.filled"
        }
    }

    var iconFilled: String {
        switch self {
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@main
struct ForceFTPApp: App {
    private var transferManager: TransferManager { .shared }
    @AppStorage("listZoomLevel") private var zoomLevel: Int = 1
    @AppStorage("appearance") private var appearance: AppAppearance = .system

    var body: some Scene {
        WindowGroup(id: "browser") {
            ContentView()
                .environmentObject(transferManager)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    appearance.apply()
                    Self.preflightMediaAccess()
                }
        }
        .defaultSize(width: 1400, height: 900)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                NewWindowButton()

                Divider()

                Button("새 연결…") {
                    NotificationCenter.default.post(name: .openConnect, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("연결 해제") {
                    NotificationCenter.default.post(name: .disconnect, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            CommandMenu("전송") {
                Button("업로드") {
                    NotificationCenter.default.post(name: .upload, object: nil)
                }
                .keyboardShortcut("u", modifiers: .command)

                Button("다운로드") {
                    NotificationCenter.default.post(name: .download, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)

                Divider()

                Button("새로고침") {
                    NotificationCenter.default.post(name: .refresh, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Divider()
                Button("확대") {
                    zoomLevel = min(zoomLevel + 1, 3)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("축소") {
                    zoomLevel = max(zoomLevel - 1, 1)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("원래 크기") {
                    zoomLevel = 1
                }
                .keyboardShortcut("0", modifiers: .command)
            }

            CommandGroup(after: .appSettings) {
                Button("전체 디스크 접근 권한 열기…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("미디어 및 Apple Music 권한 열기…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            CommandGroup(replacing: .undoRedo) {
                Button("되살리기") {
                    NotificationCenter.default.post(name: .fileUndo, object: nil)
                }
                .keyboardShortcut("z", modifiers: .command)
            }

            CommandGroup(replacing: .pasteboard) {
                Button("파일 복사") {
                    NotificationCenter.default.post(name: .fileCopy, object: nil)
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("파일 붙여넣기") {
                    NotificationCenter.default.post(name: .filePaste, object: nil)
                }
                .keyboardShortcut("v", modifiers: .command)

                Divider()

                Button("경로 복사") {
                    NotificationCenter.default.post(name: .copyPath, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("정보 가져오기 (chmod)") {
                    NotificationCenter.default.post(name: .getInfo, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }
    }

    /// 앱 시작 시 미디어 보관함 접근 권한을 미리 요청 (최초 1회만 다이얼로그 표시)
    private static func preflightMediaAccess() {
        DispatchQueue.global(qos: .utility).async {
            let soundPath = "/System/Library/Sounds/Tink.aiff"
            guard FileManager.default.fileExists(atPath: soundPath) else { return }
            let url = URL(fileURLWithPath: soundPath)
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: 64, height: 64),
                scale: 1.0,
                representationTypes: .all
            )
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { _, _ in }
        }
    }
}

private struct NewWindowButton: View {
    @Environment(\.openWindow) var openWindow
    var body: some View {
        Button("새 창") {
            // 현재 창 크기 기억
            let currentFrame = NSApp.keyWindow?.frame
            openWindow(id: "browser")
            // 새 창에 같은 크기 적용
            if let frame = currentFrame {
                DispatchQueue.main.async {
                    if let newWindow = NSApp.keyWindow {
                        newWindow.setFrame(frame, display: true)
                        // 약간 오프셋하여 겹치지 않게
                        newWindow.setFrameOrigin(NSPoint(x: frame.origin.x + 30,
                                                          y: frame.origin.y - 30))
                    }
                }
            }
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

extension Notification.Name {
    static let openConnect = Notification.Name("TL.openConnect")
    static let disconnect  = Notification.Name("TL.disconnect")
    static let upload      = Notification.Name("TL.upload")
    static let download    = Notification.Name("TL.download")
    static let refresh     = Notification.Name("TL.refresh")
    static let getInfo     = Notification.Name("TL.getInfo")
    static let fileCopy    = Notification.Name("TL.fileCopy")
    static let filePaste   = Notification.Name("TL.filePaste")
    static let fileUndo    = Notification.Name("TL.fileUndo")
    static let fileDelete  = Notification.Name("TL.fileDelete")
    static let filePermanentDelete = Notification.Name("TL.filePermanentDelete")
    static let fileRename  = Notification.Name("TL.fileRename")
    static let newFolder   = Notification.Name("TL.newFolder")
    static let copyPath    = Notification.Name("TL.copyPath")
}

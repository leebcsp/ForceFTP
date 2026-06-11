//
//  QuickLookPreview.swift
//  ForceFTP
//

import SwiftUI
import Quartz

// MARK: - QLPreviewPanel coordinator

final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var fileURL: URL?
    /// 선택된 파일 행의 화면 좌표 (줌 애니메이션용)
    var sourceFrame: NSRect = .zero
    /// 방향키 콜백 (Up/Down으로 파일 탐색)
    var onArrowKey: ((UInt16) -> Void)?

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        fileURL != nil ? 1 : 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        fileURL as? QLPreviewItem
    }

    // MARK: - Delegate: 줌 애니메이션 소스 프레임

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        return sourceFrame
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = fileURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: - 방향키로 파일 탐색

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown {
            let key = event.keyCode
            // Up(126), Down(125) 방향키 처리
            if key == 126 || key == 125 {
                onArrowKey?(key)
                return true
            }
        }
        return false
    }
}

// Global coordinator instance
let quickLookCoordinator = QuickLookCoordinator()

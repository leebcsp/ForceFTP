//
//  TransferManager.swift
//  ForceFinder — Mock backend
//

import Foundation
import SwiftUI

@MainActor
final class TransferManager: ObservableObject {
    static let shared = TransferManager()

    @Published var transfers: [Transfer] = []
    @Published var globalUploadBps: Int64 = 0
    @Published var globalDownloadBps: Int64 = 0
    @Published var transferLogs: [TransferLogEntry] = []

    private let maxConcurrent = 2
    private var timer: Timer?
    private var taskMap: [UUID: Task<Void, Never>] = [:]

    /// 파일 전송 완료 시 호출 (대상 경로 전달)
    var onTransferDone: ((Transfer) -> Void)?

    private let maxLogEntries = 500

    init() { startTicker() }

    func appendLog(_ level: TransferLogLevel, _ message: String) {
        let entry = TransferLogEntry(timestamp: Date(), message: message, level: level)
        transferLogs.append(entry)
        if transferLogs.count > maxLogEntries {
            transferLogs.removeFirst(transferLogs.count - maxLogEntries)
        }
    }

    func clearLogs() {
        transferLogs.removeAll()
    }

    var activeCount: Int {
        transfers.filter { $0.status == .active || $0.status == .queued }.count
    }

    var doneCount: Int { transfers.filter { $0.status == .done }.count }

    func enqueue(_ t: Transfer) {
        // 로컬 소스 디렉토리면 파일 목록 미리 채우기
        if t.isDirectory && t.sourceConnection.proto == .local {
            let fm = FileManager.default
            if let enumerator = fm.enumerator(atPath: t.sourcePath) {
                while let file = enumerator.nextObject() as? String {
                    let fullPath = (t.sourcePath as NSString).appendingPathComponent(file)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: fullPath, isDirectory: &isDir)
                    if !isDir.boolValue {
                        t.fileEntries.append(FileTransferEntry(name: file))
                    }
                }
                t.totalFileCount = t.fileEntries.count
            }
        }
        transfers.append(t)
        pump()
    }

    func clearCompleted() {
        transfers.removeAll { $0.status == .done || $0.status == .error }
    }

    func cancel(_ t: Transfer) {
        taskMap[t.id]?.cancel()
        t.status = .error
        t.errorMessage = "사용자가 취소함"
        pump()
    }

    func pauseAll() {
        for t in transfers where t.status == .active {
            t.status = .paused
            taskMap[t.id]?.cancel()
        }
    }

    func resumeAll() {
        for t in transfers where t.status == .paused {
            t.status = .queued
        }
        pump()
    }

    // MARK: - Queue pump

    private func pump() {
        let active = transfers.filter { $0.status == .active }.count
        guard active < maxConcurrent else { return }
        guard let next = transfers.first(where: { $0.status == .queued }) else { return }
        next.status = .active
        let task = Task { await self.execute(next) }
        taskMap[next.id] = task
        // Trigger another pump iteration in case more slots are free.
        if transfers.filter({ $0.status == .active }).count < maxConcurrent {
            DispatchQueue.main.async { self.pump() }
        }
    }

    private func execute(_ t: Transfer) async {
        let label = t.direction == .upload ? "업로드" : "다운로드"
        let dirInfo = t.isDirectory ? " (폴더)" : ""
        await MainActor.run {
            let srcLog = t.sourceConnection.proto == .local ? t.sourcePath : "\(t.sourceConnection.host):\(t.sourcePath)"
            let dstLog = t.destConnection.proto == .local ? t.destinationPath : "\(t.destConnection.host):\(t.destinationPath)"
            self.appendLog(.info, "\(label) 시작: \(srcLog) → \(dstLog)\(dirInfo)")
        }
        do {
            let fileProgressCb: (@Sendable (String, Int, Int) -> Void)?
            if t.isDirectory {
                fileProgressCb = { [weak self, weak t] (fn: String, tot: Int, done: Int) -> Void in
                    let _ = Task<Void, Never> { @MainActor in
                        guard let t = t else { return }
                        // 이전 파일을 완료 처리
                        if let prevIdx = t.fileEntries.lastIndex(where: { $0.status == .transferring }) {
                            t.fileEntries[prevIdx].status = .done
                            let num = done
                            self?.appendLog(.ok, "[\(num)] \(t.fileEntries[prevIdx].name) 전송완료.")
                        }
                        // 미리 채워진 fileEntries에서 매칭 시도
                        if let idx = t.fileEntries.firstIndex(where: { $0.name == fn && $0.status == .pending }) {
                            t.fileEntries[idx].status = .transferring
                        } else {
                            // 미리 채워지지 않은 경우 (다운로드 등)
                            var entry = FileTransferEntry(name: fn)
                            entry.status = .transferring
                            t.fileEntries.append(entry)
                        }
                        let num = done + 1
                        let total = tot > 0 ? "/\(tot)" : ""
                        self?.appendLog(.info, "[\(num)\(total)] \(fn) 전송 중...")
                        t.currentFileName = fn
                        t.totalFileCount = tot
                        t.completedFileCount = done
                    }
                }
            } else {
                fileProgressCb = nil
            }
            try await FileService.shared.copyAcross(
                source: t.sourceConnection, sourcePath: t.sourcePath,
                dest: t.destConnection, destPath: t.destinationPath,
                totalBytes: t.totalBytes,
                isDirectory: t.isDirectory,
                onFileProgress: fileProgressCb
            ) { [weak t] bytesSoFar in
                let _ = Task<Void, Never> { @MainActor in t?.transferredBytes = bytesSoFar }
            }
            await MainActor.run {
                if t.totalBytes > 0 { t.transferredBytes = t.totalBytes }
                if t.isDirectory && t.totalFileCount > 0 { t.completedFileCount = t.totalFileCount }
                // 마지막 전송 중 파일을 완료 처리
                if let lastIdx = t.fileEntries.lastIndex(where: { $0.status == .transferring }) {
                    t.fileEntries[lastIdx].status = .done
                    let num = t.completedFileCount + 1
                    self.appendLog(.ok, "[\(num)] \(t.fileEntries[lastIdx].name) 전송완료.")
                }
                t.status = .done
                let totalInfo = t.isDirectory && t.totalFileCount > 0 ? " (\(t.totalFileCount)개 파일)" : ""
                let srcL = t.sourceConnection.proto == .local ? t.sourcePath : "\(t.sourceConnection.host):\(t.sourcePath)"
                let dstL = t.destConnection.proto == .local ? t.destinationPath : "\(t.destConnection.host):\(t.destinationPath)"
                self.appendLog(.ok, "\(label) 완료: \(srcL) → \(dstL)\(totalInfo)")
                self.taskMap.removeValue(forKey: t.id)
                self.onTransferDone?(t)
                self.pump()
            }
        } catch is CancellationError {
            await MainActor.run {
                let srcL = t.sourceConnection.proto == .local ? t.sourcePath : "\(t.sourceConnection.host):\(t.sourcePath)"
                let dstL = t.destConnection.proto == .local ? t.destinationPath : "\(t.destConnection.host):\(t.destinationPath)"
                self.appendLog(.error, "\(label) 취소: \(srcL) → \(dstL)")
                self.taskMap.removeValue(forKey: t.id)
                self.pump()
            }
        } catch {
            await MainActor.run {
                t.status = .error
                t.errorMessage = error.localizedDescription
                let srcL = t.sourceConnection.proto == .local ? t.sourcePath : "\(t.sourceConnection.host):\(t.sourcePath)"
                let dstL = t.destConnection.proto == .local ? t.destinationPath : "\(t.destConnection.host):\(t.destinationPath)"
                self.appendLog(.error, "\(label) 오류: \(srcL) → \(dstL) — \(error.localizedDescription)")
                self.taskMap.removeValue(forKey: t.id)
                self.pump()
            }
        }
    }

    // MARK: - Ticker

    private var lastSnapshot: [UUID: (Int64, Date)] = [:]

    private func startTicker() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        var totalUp: Int64 = 0
        var totalDown: Int64 = 0
        let now = Date()
        for t in transfers {
            guard t.status == .active else {
                if t.status != .done { lastSnapshot[t.id] = nil }
                continue
            }
            let prev = lastSnapshot[t.id] ?? (t.transferredBytes, now)
            let dt = now.timeIntervalSince(prev.1)
            let dB = t.transferredBytes - prev.0
            let bps = dt > 0.05 ? Int64(Double(dB) / dt) : t.speedBps
            t.speedBps = bps
            t.etaSeconds = bps > 0
                ? Int(Double(max(0, t.totalBytes - t.transferredBytes)) / Double(bps))
                : 0
            if t.direction == .upload { totalUp += bps } else { totalDown += bps }
            lastSnapshot[t.id] = (t.transferredBytes, now)
        }
        globalUploadBps = totalUp
        globalDownloadBps = totalDown
    }
}

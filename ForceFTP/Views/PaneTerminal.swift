//
//  PaneTerminal.swift
//  ForceFTP
//

import SwiftUI

/// Inline terminal embedded in each pane, synced with the pane's current directory.
/// stdin 스트리밍 + 실시간 출력 지원
struct PaneTerminal: View {
    let side: PaneSide
    @EnvironmentObject var app: AppState
    @StateObject private var shell = ShellSession()
    @State private var input: String = ""
    @FocusState private var focused: Bool

    var pane: PaneState { app.pane(side) }

    var body: some View {
        VStack(spacing: 0) {
            // Terminal output
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shell.lines) { line in
                            Text(line.attributed)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(nil)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: shell.lines.count) { _, _ in
                    if let last = shell.lines.last {
                        withAnimation(.none) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Input line
            HStack(spacing: 0) {
                if shell.isRunning {
                    // 실행 중: 입력은 stdin으로 전달
                    Text("> ")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.3))
                        .lineLimit(1)
                } else {
                    Text(shell.prompt)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color(red: 0.44, green: 0.88, blue: 0.55))
                        .lineLimit(1)
                }
                TextField("", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit {
                        let text = input
                        input = ""
                        if shell.isRunning {
                            shell.sendInput(text)
                        } else {
                            shell.execute(text, pane: pane) { newPath in
                                pane.navigate(to: newPath)
                                Task { await reloadPane() }
                            }
                        }
                    }
                if shell.isRunning {
                    Button {
                        shell.interrupt()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.52))
                    }
                    .buttonStyle(.plain)
                    .help("중단 (Ctrl+C)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.25))
        }
        .background(Color(red: 0.16, green: 0.16, blue: 0.17))
        .onAppear {
            shell.showWelcome(pane: pane)
            shell.syncDirectory(pane.currentPath)
        }
        .onReceive(pane.$currentPath) { newPath in
            shell.syncDirectory(newPath)
        }
        .onReceive(pane.$connection) { (newConn: Connection) in
            shell.updateConnection(newConn)
            shell.syncDirectory(pane.currentPath)
            shell.showWelcome(pane: pane)
        }
    }

    private func reloadPane() async {
        await MainActor.run { pane.isLoading = true; pane.errorMessage = nil }
        do {
            let items = try await FileService.shared.list(
                connection: pane.connection, path: pane.currentPath)
            await MainActor.run {
                pane.items = items
                pane.isLoading = false
                pane.isConnected = true
            }
        } catch {
            await MainActor.run {
                pane.isLoading = false
                pane.errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Shell Session

final class ShellSession: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        let attributed: AttributedString
    }

    @Published var lines: [Line] = []
    @Published var prompt: String = "$ "
    @Published var isRunning: Bool = false
    private var cwd: String = NSHomeDirectory()
    private var didWelcome = false
    private var connection: Connection?

    // 실행 중인 프로세스 및 stdin
    private var runningProcess: Process?
    private var stdinPipe: Pipe?

    // 출력 버퍼 (줄 단위로 끊기 위해)
    private var outBuffer = Data()
    private var errBuffer = Data()

    func syncDirectory(_ path: String) {
        cwd = path
        updatePrompt()
    }

    func showWelcome(pane: PaneState) {
        connection = pane.connection
        guard !didWelcome else { return }
        didWelcome = true
        let host = pane.connection.proto == .local
            ? (Host.current().localizedName ?? "Mac")
            : "\(pane.connection.username)@\(pane.connection.host)"
        addLine("Terminal — \(host)", color: Color(red: 0.55, green: 0.55, blue: 0.58))
        if pane.connection.proto != .local {
            addLine("SSH connected to \(pane.connection.host):\(pane.connection.port)",
                    color: Color(red: 0.55, green: 0.55, blue: 0.58))
        }
        addLine("Type commands below. Use 'cd' to navigate.", color: Color(red: 0.55, green: 0.55, blue: 0.58))
        addLine("", color: .clear)
    }

    func updateConnection(_ conn: Connection) {
        connection = conn
        didWelcome = false
    }

    // MARK: - stdin 입력 전송

    func sendInput(_ text: String) {
        guard let pipe = stdinPipe else { return }
        addLine(text, color: Color(red: 0.85, green: 0.85, blue: 0.85))
        let data = (text + "\n").data(using: .utf8) ?? Data()
        pipe.fileHandleForWriting.write(data)
    }

    // MARK: - 프로세스 중단 (Ctrl+C)

    func interrupt() {
        guard let process = runningProcess, process.isRunning else { return }
        process.interrupt() // SIGINT
    }

    // MARK: - 명령 실행

    func execute(_ raw: String, pane: PaneState, onCd: @escaping (String) -> Void) {
        connection = pane.connection
        let cmd = raw.trimmingCharacters(in: .whitespaces)
        echoPrompt(cmd)
        guard !cmd.isEmpty else { return }

        if cmd == "cd" || cmd.hasPrefix("cd ") {
            if pane.connection.proto == .local {
                handleLocalCd(cmd, onCd: onCd)
            } else {
                handleRemoteCd(cmd, connection: pane.connection, onCd: onCd)
            }
            return
        }

        if cmd == "clear" {
            lines.removeAll()
            return
        }

        if pane.connection.proto == .local {
            runLocal(cmd)
        } else {
            runRemote(cmd, connection: pane.connection)
        }
    }

    // MARK: - Local cd

    private func handleLocalCd(_ cmd: String, onCd: @escaping (String) -> Void) {
        let parts = cmd.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        var target: String
        if parts.count < 2 {
            target = NSHomeDirectory()
        } else {
            target = String(parts[1])
        }

        if target == "~" {
            target = NSHomeDirectory()
        } else if target.hasPrefix("~/") {
            target = (NSHomeDirectory() as NSString)
                .appendingPathComponent(String(target.dropFirst(2)))
        } else if !target.hasPrefix("/") {
            target = (cwd as NSString).appendingPathComponent(target)
        }

        target = (target as NSString).standardizingPath

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue {
            cwd = target
            updatePrompt()
            onCd(target)
        } else {
            addLine("cd: no such directory: \(target)", color: Color(red: 1.0, green: 0.55, blue: 0.52))
        }
    }

    // MARK: - Remote cd

    private func handleRemoteCd(_ cmd: String, connection: Connection, onCd: @escaping (String) -> Void) {
        let parts = cmd.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        var target: String
        if parts.count < 2 {
            target = connection.remotePath
        } else {
            target = String(parts[1])
        }

        if target == "~" {
            target = connection.remotePath
        } else if target.hasPrefix("~/") {
            target = (connection.remotePath as NSString)
                .appendingPathComponent(String(target.dropFirst(2)))
        } else if !target.hasPrefix("/") {
            target = (cwd as NSString).appendingPathComponent(target)
        }

        target = (target as NSString).standardizingPath
        cwd = target
        updatePrompt()
        onCd(target)
    }

    // MARK: - Local execution

    private func runLocal(_ cmd: String) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", cmd]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        process.environment = ProcessInfo.processInfo.environment

        runningProcess = process
        stdinPipe = inPipe
        isRunning = true
        outBuffer = Data()
        errBuffer = Data()

        // 실시간 stdout 스트리밍
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleStreamData(data, isError: false)
        }

        // 실시간 stderr 스트리밍
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleStreamData(data, isError: true)
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self?.flushBuffers()
                if proc.terminationStatus != 0 {
                    self?.addLine("exit code: \(proc.terminationStatus)",
                                  color: Color(red: 1.0, green: 0.55, blue: 0.52))
                }
                self?.runningProcess = nil
                self?.stdinPipe = nil
                self?.isRunning = false
            }
        }

        do {
            try process.run()
        } catch {
            addLine("Error: \(error.localizedDescription)",
                    color: Color(red: 1.0, green: 0.55, blue: 0.52))
            runningProcess = nil
            stdinPipe = nil
            isRunning = false
        }
    }

    // MARK: - Remote execution (SSH)

    private func findSshpass() -> String? {
        let paths = ["/opt/homebrew/bin/sshpass", "/usr/local/bin/sshpass"]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func runRemote(_ cmd: String, connection: Connection) {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()

        let remoteCmd = "cd \(shellEscape(cwd)) && \(cmd)"
        let port = connection.port > 0 ? connection.port : 22

        let sshArgs = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "ConnectTimeout=5",
            "-tt",  // 강제 TTY 할당 (대화형 입력 지원)
            "-p", "\(port)",
            "\(connection.username)@\(connection.host)",
            remoteCmd
        ]

        // script -q /dev/null 로 로컬 파이프 버퍼링 해제
        var sshCmd: [String]
        if !connection.password.isEmpty, let sshpassPath = findSshpass() {
            sshCmd = [sshpassPath, "-p", connection.password, "/usr/bin/ssh"] + sshArgs
        } else {
            sshCmd = ["/usr/bin/ssh"] + sshArgs
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null"] + sshCmd

        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        process.environment = ProcessInfo.processInfo.environment

        runningProcess = process
        stdinPipe = inPipe
        isRunning = true
        outBuffer = Data()
        errBuffer = Data()

        // 실시간 stdout 스트리밍
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleStreamData(data, isError: false)
        }

        // 실시간 stderr 스트리밍
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleStreamData(data, isError: true)
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self?.flushBuffers()
                if proc.terminationStatus != 0 && proc.terminationStatus != 130 {
                    self?.addLine("exit code: \(proc.terminationStatus)",
                                  color: Color(red: 1.0, green: 0.55, blue: 0.52))
                }
                self?.runningProcess = nil
                self?.stdinPipe = nil
                self?.isRunning = false
            }
        }

        do {
            try process.run()
        } catch {
            addLine("SSH Error: \(error.localizedDescription)",
                    color: Color(red: 1.0, green: 0.55, blue: 0.52))
            runningProcess = nil
            stdinPipe = nil
            isRunning = false
        }
    }

    // MARK: - 스트리밍 처리

    private func handleStreamData(_ data: Data, isError: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isError {
                self.errBuffer.append(data)
                self.processBuffer(isError: true)
            } else {
                self.outBuffer.append(data)
                self.processBuffer(isError: false)
            }
        }
    }

    /// 버퍼에서 완성된 줄을 추출하여 표시
    private func processBuffer(isError: Bool) {
        let buffer = isError ? errBuffer : outBuffer
        guard let text = String(data: buffer, encoding: .utf8) else { return }

        // 마지막 줄바꿈까지를 완성된 줄로 처리
        if let lastNewline = text.lastIndex(of: "\n") {
            let completedText = String(text[text.startIndex...lastNewline])
            let remaining = String(text[text.index(after: lastNewline)...])

            let lines = completedText.components(separatedBy: "\n")
                .filter { !$0.isEmpty }

            let color: Color = isError
                ? Color(red: 1.0, green: 0.55, blue: 0.52)
                : .white

            for line in lines {
                // SSH post-quantum 경고는 무시
                if isError && (line.contains("WARNING: connection is not using a post-quantum") ||
                               line.contains("store now, decrypt later") ||
                               line.contains("server may need to be upgraded") ||
                               line.contains("openssh.com/pq")) {
                    continue
                }
                addLine(line, color: color)
            }

            if isError {
                errBuffer = remaining.data(using: .utf8) ?? Data()
            } else {
                outBuffer = remaining.data(using: .utf8) ?? Data()
            }
        }
    }

    /// 프로세스 종료 시 남은 버퍼 플러시
    private func flushBuffers() {
        // stdout 잔여
        if !outBuffer.isEmpty, let text = String(data: outBuffer, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addLine(text.trimmingCharacters(in: .newlines), color: .white)
        }
        outBuffer = Data()

        // stderr 잔여
        if !errBuffer.isEmpty, let text = String(data: errBuffer, encoding: .utf8) {
            let filtered = text.components(separatedBy: "\n")
                .filter { !$0.contains("WARNING: connection is not using a post-quantum") &&
                          !$0.contains("store now, decrypt later") &&
                          !$0.contains("server may need to be upgraded") &&
                          !$0.contains("openssh.com/pq") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !filtered.isEmpty {
                addLine(filtered, color: Color(red: 1.0, green: 0.55, blue: 0.52))
            }
        }
        errBuffer = Data()
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Prompt

    private func updatePrompt() {
        if let conn = connection, conn.proto != .local {
            let shortDisplay = (cwd as NSString).lastPathComponent
            let dir = shortDisplay.isEmpty ? "/" : shortDisplay
            prompt = "\(conn.username)@\(conn.host) \(dir) $ "
        } else {
            let home = NSHomeDirectory()
            let display: String
            if cwd == home {
                display = "~"
            } else if cwd.hasPrefix(home + "/") {
                display = "~" + String(cwd.dropFirst(home.count))
            } else {
                display = cwd
            }
            let shortDisplay = (display as NSString).lastPathComponent
            prompt = "\(NSUserName())@\(Host.current().localizedName ?? "Mac") \(shortDisplay) $ "
        }
    }

    private func echoPrompt(_ cmd: String) {
        var s = AttributedString(prompt)
        s.foregroundColor = Color(red: 0.44, green: 0.88, blue: 0.55)
        var c = AttributedString(cmd)
        c.foregroundColor = .white
        lines.append(Line(attributed: s + c))
        cap()
    }

    private func addLine(_ text: String, color: Color) {
        var attr = AttributedString(text)
        attr.foregroundColor = color
        lines.append(Line(attributed: attr))
        cap()
    }

    private func cap() {
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }
}

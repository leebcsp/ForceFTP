//
//  ConnectSheet.swift
//  ForceFinder
//

import SwiftUI

struct ConnectSheet: View {
    let side: PaneSide
    @Binding var isPresented: Bool
    @EnvironmentObject var app: AppState
    var editConnection: Connection? = nil

    @State private var proto: TransferProtocol = .sftp
    @State private var serverName: String = ""
    @State private var host: String = ""
    @State private var portText: String = "22"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var path: String = "/"
    @State private var keyPath: String = "~/.ssh/id_ed25519"
    // 프로토콜별 입력값 기억
    @State private var savedForms: [TransferProtocol: ProtoForm] = [:]

    private struct ProtoForm {
        var host: String = ""
        var port: String = ""
        var username: String = ""
        var password: String = ""
        var path: String = "/"
    }
    @State private var anonymous: Bool = false
    @State private var saveToKeychain: Bool = true
    @State private var auth: AuthMode = .password
    @State private var saveAsFavorite: Bool = false
    @State private var isConnecting: Bool = false
    @State private var isTesting: Bool = false
    @State private var testResult: String?
    @State private var testSuccess: Bool = false
    @State private var showPassword: Bool = false
    @State private var error: String?
    // Google Drive
    @State private var gdClientId: String = GoogleDriveService.clientId
    @State private var gdClientSecret: String = GoogleDriveService.clientSecret
    @State private var gdAuthenticating: Bool = false
    @State private var gdEmail: String = ""

    enum AuthMode: String, CaseIterable {
        case password = "비밀번호"
        case key = "SSH 키"
        case agent = "SSH 에이전트"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            protoTabs
            Divider()
            form
            footer
        }
        .frame(width: 540)
        .background(Color.panelCard)
        .onAppear {
            if let c = editConnection {
                proto = c.proto
                serverName = c.name
                host = c.host
                portText = "\(c.port)"
                username = c.username
                password = c.password
                path = c.remotePath
                anonymous = c.anonymous
            }
        }
        .onChange(of: proto) { _, _ in
            // 프로토콜별 값은 saveCurrentForm/loadForm에서 처리
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [Color(red: 0.37, green: 0.63, blue: 1.0),
                                                   Color(red: 0.04, green: 0.42, blue: 1.0)],
                                          startPoint: .top, endPoint: .bottom))
                Image(systemName: "globe")
                    .foregroundStyle(.white)
                    .font(.system(size: 22, weight: .semibold))
            }
            .frame(width: 44, height: 44)
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(editConnection != nil ? "연결 정보 수정" : "서버에 연결")
                    .font(.system(size: 15, weight: .bold))
                Text("선택된 패널: \(side == .left ? "왼쪽" : "오른쪽")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
    }

    private var protoTabs: some View {
        HStack(spacing: 2) {
            ForEach(TransferProtocol.allCases.filter { $0 != .local && $0 != .googleDrive }) { p in
                let selected = proto == p
                Button {
                    saveCurrentForm()
                    proto = p
                    loadForm(for: p)
                } label: {
                    Text(p.displayName)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .white : .secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(minWidth: 44)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(selected ? Color(red: 0.78, green: 0.28, blue: 0.51) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
    }

    private var form: some View {
        VStack(spacing: 8) {
            if proto == .googleDrive {
                googleDriveForm
            } else {
                standardForm
            }

            if proto != .googleDrive {
                HStack(spacing: 16) {
                    Toggle("익명 로그인", isOn: $anonymous)
                    Toggle("키체인에 저장", isOn: $saveToKeychain)
                    Toggle("즐겨찾기에 추가", isOn: $saveAsFavorite)
                    Spacer()
                }
                .toggleStyle(.checkbox)
                .padding(.leading, 110)
                .font(.system(size: 11.5))
            }

            if let err = error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err).font(.system(size: 11)).foregroundStyle(.red)
                }
                .padding(.leading, 110)
            }
            if let result = testResult {
                HStack {
                    Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testSuccess ? .green : .red)
                    Text(result).font(.system(size: 11))
                        .foregroundStyle(testSuccess ? .green : .red)
                }
                .padding(.leading, 110)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder
    private var standardForm: some View {
        Group {
            row(label: "서버명") {
                TextField("내 서버", text: $serverName).textFieldStyle(.roundedBorder)
            }
            row(label: "호스트") {
                TextField("example.com", text: $host).textFieldStyle(.roundedBorder)
                Text("포트:").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("22", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }
            row(label: "사용자 이름") {
                TextField("username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .disabled(anonymous)
            }
            row(label: "암호") {
                Group {
                    if showPassword {
                        TextField("password", text: $password)
                    } else {
                        SecureField("••••••••", text: $password)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(anonymous || (proto == .sftp && auth != .password))
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(showPassword ? "비밀번호 숨기기" : "비밀번호 보기")
            }
            if proto == .sftp {
                row(label: "인증") {
                    Picker("", selection: $auth) {
                        ForEach(AuthMode.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                if auth == .key {
                    row(label: "키 경로") {
                        TextField("~/.ssh/id_ed25519", text: $keyPath)
                            .textFieldStyle(.roundedBorder)
                        Button("선택…") { chooseKey() }
                    }
                }
            }
            row(label: "원격 경로") {
                TextField("/", text: $path).textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private var googleDriveForm: some View {
        Group {
            row(label: "Client ID") {
                TextField("Google Cloud Console에서 발급", text: $gdClientId)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: gdClientId) { _, newVal in
                        GoogleDriveService.clientId = newVal
                    }
            }
            row(label: "Client Secret") {
                SecureField("Client Secret", text: $gdClientSecret)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: gdClientSecret) { _, newVal in
                        GoogleDriveService.clientSecret = newVal
                    }
            }

            Divider().padding(.vertical, 4)

            if gdEmail.isEmpty {
                HStack {
                    Spacer()
                    Button {
                        authenticateGoogleDrive()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                            Text("Google 계정으로 로그인")
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.26, green: 0.52, blue: 0.96))
                    .disabled(gdClientId.isEmpty || gdClientSecret.isEmpty || gdAuthenticating)

                    if gdAuthenticating {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            } else {
                row(label: "계정") {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(gdEmail)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("로그아웃") {
                            gdEmail = ""
                            password = ""
                        }
                        .font(.system(size: 11))
                    }
                }
                row(label: "시작 경로") {
                    TextField("/", text: $path).textFieldStyle(.roundedBorder)
                }
            }

            if gdClientId.isEmpty || gdClientSecret.isEmpty {
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text("Google Cloud Console에서 OAuth 2.0 자격 증명을 생성하세요.\n리디렉션 URI: http://localhost (데스크탑 앱)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 110)
            }
        }
    }

    @ViewBuilder
    private func row<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 100, alignment: .trailing)
                .foregroundStyle(.primary)
            content()
        }
    }

    private var footer: some View {
        HStack {
            if proto != .googleDrive {
                Button("연결 테스트") { testConnection() }
                    .disabled(isTesting || host.isEmpty)

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 4)
                }
            }

            Spacer()

            Button("취소") { isPresented = false }
                .keyboardShortcut(.cancelAction)

            if proto == .googleDrive {
                Button("연결") {
                    connectGoogleDrive()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting || gdEmail.isEmpty || password.isEmpty)
            } else {
                Button("연결") {
                    connect()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isConnecting || host.isEmpty)
            }
        }
        .padding(16)
        .background(Color.panelCard)
    }

    private func saveCurrentForm() {
        savedForms[proto] = ProtoForm(
            host: host, port: portText, username: username,
            password: password, path: path)
    }

    private func loadForm(for p: TransferProtocol) {
        if let saved = savedForms[p] {
            host = saved.host
            portText = saved.port.isEmpty ? "\(p.defaultPort)" : saved.port
            username = saved.username
            password = saved.password
            path = saved.path.isEmpty ? "/" : saved.path
        } else {
            host = ""
            portText = "\(p.defaultPort)"
            username = ""
            password = ""
            path = "/"
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            keyPath = url.path
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        error = nil

        let displayName = serverName.trimmingCharacters(in: .whitespaces).isEmpty ? host : serverName.trimmingCharacters(in: .whitespaces)
        let c = Connection(
            name: displayName, proto: proto, host: host, port: Int(portText) ?? proto.defaultPort,
            username: anonymous ? "anonymous" : username,
            password: password,
            remotePath: path,
            anonymous: anonymous
        )

        Task {
            let start = Date()
            do {
                _ = try await FileService.shared.list(connection: c, path: c.remotePath)
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
                await MainActor.run {
                    testSuccess = true
                    testResult = "연결 성공 (\(elapsed)초)"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testSuccess = false
                    testResult = "연결 실패: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }

    private func connect() {
        isConnecting = true
        error = nil

        let displayName = serverName.trimmingCharacters(in: .whitespaces).isEmpty ? host : serverName.trimmingCharacters(in: .whitespaces)
        let c = Connection(
            name: displayName, proto: proto, host: host, port: Int(portText) ?? proto.defaultPort,
            username: anonymous ? "anonymous" : username,
            password: password,
            remotePath: path,
            anonymous: anonymous
        )

        let pane = PaneState(side: side, connection: c)
        pane.isConnected = true
        app.setPane(side, to: pane)
        app.setActive(side)
        app.saveLastPaneState()

        Task {
            do {
                let items = try await FileService.shared.list(connection: c, path: c.remotePath)
                await MainActor.run {
                    pane.items = items
                    pane.isLoading = false
                    isPresented = false
                    app.addRecentConnection(c)
                    app.appendLog(.ok, "\(c.name) 연결됨 (\(proto.displayName))")
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isConnecting = false
                    app.appendLog(.error, "연결 실패: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Google Drive

    private func authenticateGoogleDrive() {
        gdAuthenticating = true
        error = nil
        testResult = nil

        Task {
            do {
                let result = try await GoogleDriveService.shared.authenticate()
                await MainActor.run {
                    gdEmail = result.email
                    username = result.email
                    host = "drive.google.com"
                    password = result.token.refreshToken
                    gdAuthenticating = false
                    testSuccess = true
                    testResult = "Google 인증 성공: \(result.email)"

                    // 토큰을 임시 저장 (연결 시 사용)
                    Task {
                        // 미리 연결 ID를 만들어 토큰 매핑
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    gdAuthenticating = false
                }
            }
        }
    }

    private func connectGoogleDrive() {
        isConnecting = true
        error = nil

        let c = Connection(
            name: gdEmail,
            proto: .googleDrive,
            host: "drive.google.com",
            port: 443,
            username: gdEmail,
            password: password,  // refresh token
            remotePath: path.isEmpty ? "/" : path
        )

        let pane = PaneState(side: side, connection: c)
        pane.isConnected = true
        app.setPane(side, to: pane)
        app.setActive(side)
        app.saveLastPaneState()

        Task {
            do {
                // refresh token으로 새 access token 발급
                let token = GoogleOAuthToken(
                    accessToken: "", refreshToken: c.password,
                    expiresAt: Date.distantPast)
                await GoogleDriveService.shared.setToken(token, for: c.id)

                let items = try await FileService.shared.list(connection: c, path: c.remotePath)
                await MainActor.run {
                    pane.items = items
                    pane.isLoading = false
                    isPresented = false
                    app.addRecentConnection(c)
                    app.appendLog(.ok, "Google Drive 연결됨 (\(gdEmail))")
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isConnecting = false
                    app.appendLog(.error, "Google Drive 연결 실패: \(error.localizedDescription)")
                }
            }
        }
    }
}

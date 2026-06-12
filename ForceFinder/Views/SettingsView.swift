//
//  SettingsView.swift
//  ForceFinder
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("maxConcurrentTransfers") private var maxConcurrent: Int = 2
    @AppStorage("preferKeychain") private var preferKeychain: Bool = true
    @AppStorage("strictHostKey") private var strictHostKey: Bool = false
    @AppStorage("showHiddenFiles") private var showHidden: Bool = false

    var body: some View {
        TabView {
            general
                .tabItem { Label("일반", systemImage: "gearshape") }
            transfer
                .tabItem { Label("전송", systemImage: "arrow.up.arrow.down") }
            about
                .tabItem { Label("정보", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 280)
    }

    private var general: some View {
        Form {
            Section {
                Toggle("연결 정보를 키체인에 저장", isOn: $preferKeychain)
                Toggle("Strict Host Key Checking (SSH)", isOn: $strictHostKey)
                Toggle("숨겨진 파일 표시", isOn: $showHidden)
            }
        }
        .padding()
    }

    private var transfer: some View {
        Form {
            Section {
                Stepper("동시 전송 수: \(maxConcurrent)", value: $maxConcurrent, in: 1...8)
                Text("권장: 1–3. 너무 높으면 일부 서버가 연결을 거부할 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var about: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color(red: 0.04, green: 0.42, blue: 1.0))
            Text("ForceFinder").font(.system(size: 16, weight: .bold))
            Text("v1.0").font(.caption).foregroundStyle(.secondary)
            Text("듀얼 패인 파일 매니저 — SFTP/FTP 지원")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

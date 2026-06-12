//
//  TerminalView.swift
//  ForceFinder
//
//  Legacy terminal view - kept for backward compatibility.
//  Each pane now has its own inline terminal (PaneTerminal).
//

import SwiftUI

struct TerminalView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("각 패인 하단의 터미널을 사용하세요")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color.panelList)
    }
}

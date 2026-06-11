import SwiftUI

struct DependencyCheckView: View {
    @ObservedObject var service: DependencyService

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)

                Text("필수 프로그램 설치")
                    .font(.system(size: 16, weight: .semibold))

                Text("앱 실행에 필요한 프로그램을 확인하고 설치합니다.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    ForEach(service.dependencies) { dep in
                        HStack(spacing: 10) {
                            statusIcon(dep.status)
                                .frame(width: 20)

                            Text(dep.name)
                                .font(.system(size: 13, weight: .medium))

                            Spacer()

                            statusLabel(dep.status)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.horizontal, 8)

                if !service.logMessages.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(service.logMessages.enumerated()), id: \.offset) { idx, msg in
                                    Text(msg)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .id(idx)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                        .frame(height: 80)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .onChange(of: service.logMessages.count) { _, _ in
                            if let last = service.logMessages.indices.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }

                if service.isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(32)
            .frame(width: 380)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 6)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.45))
    }

    @ViewBuilder
    private func statusIcon(_ status: DependencyService.Dependency.Status) -> some View {
        switch status {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .installing:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func statusLabel(_ status: DependencyService.Dependency.Status) -> some View {
        switch status {
        case .checking:
            Text("확인 중...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .installed:
            Text("설치됨")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .installing:
            Text("설치 중...")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
        case .failed(let msg):
            Text(msg)
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
    }
}

import Foundation

@MainActor
final class DependencyService: ObservableObject {
    static let shared = DependencyService()

    struct Dependency: Identifiable {
        let id: String
        let name: String
        var status: Status = .checking

        enum Status: Equatable {
            case checking
            case installed
            case installing
            case failed(String)
        }
    }

    @Published var dependencies: [Dependency] = [
        Dependency(id: "brew", name: "Homebrew"),
        Dependency(id: "ffmpeg", name: "ffmpeg"),
        Dependency(id: "yt-dlp", name: "yt-dlp"),
    ]
    @Published var isChecking = false
    @Published var allReady = false
    @Published var logMessages: [String] = []

    private let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    private let toolSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    private init() {}

    func checkAndInstallAll() async {
        isChecking = true
        logMessages = []

        // 1) Homebrew
        await checkAndInstallBrew()

        // 2) ffmpeg
        await checkAndInstallBrewPackage(id: "ffmpeg", formula: "ffmpeg")

        // 3) yt-dlp
        await checkAndInstallBrewPackage(id: "yt-dlp", formula: "yt-dlp")

        allReady = dependencies.allSatisfy { $0.status == .installed }
        isChecking = false
    }

    private func findBrew() -> String? {
        brewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func findTool(_ name: String) -> String? {
        for dir in toolSearchPaths {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func updateStatus(id: String, _ status: Dependency.Status) {
        if let idx = dependencies.firstIndex(where: { $0.id == id }) {
            dependencies[idx].status = status
        }
    }

    private func appendLog(_ msg: String) {
        logMessages.append(msg)
    }

    // MARK: - Homebrew

    private func checkAndInstallBrew() async {
        updateStatus(id: "brew", .checking)
        appendLog("Homebrew 확인 중...")

        if findBrew() != nil {
            updateStatus(id: "brew", .installed)
            appendLog("Homebrew 설치됨")
            return
        }

        updateStatus(id: "brew", .installing)
        appendLog("Homebrew 설치 중... (시간이 걸릴 수 있습니다)")

        let success = await runProcess(
            "/bin/bash",
            args: ["-c", "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""],
            environment: ["NONINTERACTIVE": "1"]
        )

        if success && findBrew() != nil {
            updateStatus(id: "brew", .installed)
            appendLog("Homebrew 설치 완료")
        } else {
            updateStatus(id: "brew", .failed("Homebrew 설치 실패"))
            appendLog("Homebrew 설치 실패")
        }
    }

    // MARK: - Brew packages

    private func checkAndInstallBrewPackage(id: String, formula: String) async {
        updateStatus(id: id, .checking)
        appendLog("\(formula) 확인 중...")

        if findTool(formula) != nil {
            updateStatus(id: id, .installed)
            appendLog("\(formula) 설치됨")
            return
        }

        guard let brew = findBrew() else {
            updateStatus(id: id, .failed("Homebrew 없음"))
            appendLog("\(formula) 설치 불가: Homebrew 없음")
            return
        }

        updateStatus(id: id, .installing)
        appendLog("\(formula) 설치 중...")

        let success = await runProcess(brew, args: ["install", formula])

        if success && findTool(formula) != nil {
            updateStatus(id: id, .installed)
            appendLog("\(formula) 설치 완료")
        } else {
            updateStatus(id: id, .failed("\(formula) 설치 실패"))
            appendLog("\(formula) 설치 실패")
        }
    }

    // MARK: - Process runner

    private func runProcess(_ path: String, args: [String], environment: [String: String]? = nil) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                if let env = environment {
                    var procEnv = ProcessInfo.processInfo.environment
                    for (k, v) in env { procEnv[k] = v }
                    process.environment = procEnv
                }
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    cont.resume(returning: process.terminationStatus == 0)
                } catch {
                    cont.resume(returning: false)
                }
            }
        }
    }
}

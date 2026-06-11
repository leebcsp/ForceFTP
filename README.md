# Transmit Lite — macOS Native (Mock Build)

UI가 완성된 macOS 네이티브 듀얼 패널 FTP/SFTP 클라이언트입니다.
**모든 데이터는 메모리 안의 모의 파일시스템에서 동작하며**, 네트워크 호출은 일체 없습니다.
실제 동작하는 UI 흐름을 끝까지 시연할 수 있도록 만들어져 있어요.

## 빌드 방법

1. **Xcode 15+ 필요** (macOS 13.0 이상 타겟)
2. `ForceFTP.xcodeproj`를 더블클릭해서 Xcode에서 엽니다
3. **Signing & Capabilities** 탭에서 본인 Team을 선택 (Personal Team으로도 됩니다)
4. `⌘R`로 빌드/실행

> 외부 의존성, 빌드 스크립트, 추가 설치 모두 필요 없습니다. 5초 안에 실행됩니다.

## 무엇을 시연하나요

앱이 켜지면 이렇게 보입니다:

- **왼쪽 패널**: 로컬 Mac (`/Users/kim`) - Documents, Downloads, Pictures, Movies, Developer 등 익숙한 폴더와 파일들
- **오른쪽 패널**: SFTP로 prod.example.com에 이미 연결된 상태 - `/var/www` 안의 nginx 사이트, 로그, DB 백업이 있는 리눅스 서버

### 시연할 수 있는 흐름들

1. **폴더 진입**: 더블클릭으로 깊이 들어가기, breadcrumb pathbar로 한 번에 점프
2. **다중 선택**: 클릭, ⌘-클릭, ⇧-클릭 모두 동작
3. **업로드**: 왼쪽에서 파일 선택 → ⌘U → 하단 전송 탭에서 진행률 실시간 관찰
4. **다운로드**: 오른쪽에서 큰 파일(`db-2026-05-21.sql.gz` 80MB+) 선택 → ⌘D → 일시정지 → 재개
5. **chmod**: 파일 선택 → ⌘I → 9개 체크박스 클릭 → 옥타값이 실시간 변동 → 적용 → 패널 권한 컬럼 갱신
6. **새 연결**: ⌘K → 6개 프로토콜 탭(SFTP/FTP/FTPS/WebDAV/S3/SMB) → 임의의 host:port 입력 → 연결 → 해당 프로토콜에 맞는 가짜 디렉토리 트리가 펼쳐짐
7. **터미널**: 하단 터미널 탭 → `ls -la`, `cd Documents`, `pwd`, `chmod 755 file`, `help` 등 동작
8. **로그**: 하단 로그 탭 → 모든 사용자 액션이 색상 구분되어 기록됨
9. **새 폴더 / 삭제**: 툴바 버튼으로 가상 파일시스템에 실제로 반영됨

각 프로토콜마다 **네트워크 지연이 시뮬레이션**돼 있어요 (로컬 30ms, SFTP 280ms, FTP 360ms, S3 220ms 등) — 그래서 새로고침이나 디렉토리 진입 시 자연스러운 로딩 인디케이터가 잠깐 보입니다. 전송 속도도 프로토콜별로 다르게 (S3가 가장 빠르고, WebDAV가 가장 느림) 시뮬레이션됩니다.

## 폴더 구조

```
ForceFTP/
├── ForceFTPApp.swift          # 앱 진입점, 메뉴/단축키
├── Info.plist
├── ForceFTP.entitlements      # Sandbox 활성화 (Mock이라 외부 도구 불필요)
├── Assets.xcassets/
├── Models/
│   ├── Models.swift               # TransferProtocol, Connection, RemoteItem, Permissions
│   └── AppState.swift             # AppState, PaneState, Log
├── Views/
│   ├── ContentView.swift          # 메인 레이아웃 (Toolbar + 듀얼 패널 + 하단 패널)
│   ├── Toolbar.swift              # Aqua 스타일 툴바 + 최근 연결 메뉴
│   ├── PaneView.swift             # Finder 스타일 4열 리스트 + Pathbar
│   ├── BottomPanel.swift          # 전송 큐 / 터미널 / 로그 탭 + 상태바
│   ├── TerminalView.swift         # Mock 셸 (실제 명령은 실행 안 됨)
│   ├── ConnectSheet.swift         # 6개 프로토콜 연결 시트
│   ├── InfoSheet.swift            # ⌘I chmod 다이얼로그
│   └── SettingsView.swift         # 환경설정 (3개 탭)
└── Services/
    ├── FileService.swift          # 메모리 가상 파일시스템 + 시뮬레이션된 지연
    └── TransferManager.swift      # 전송 큐 + 가짜 진행률 ticker
```

## 단축키

| 단축키 | 동작 |
|---|---|
| ⌘K | 새 연결 |
| ⇧⌘E | 연결 해제 |
| ⌘U | 업로드 |
| ⌘D | 다운로드 |
| ⌘R | 새로고침 |
| ⌘I | 정보 가져오기 (chmod) |

## 실제 백엔드로 교체하기

이 빌드의 모든 동작은 `Services/FileService.swift`와 `Services/TransferManager.swift` 두 파일에 격리되어 있습니다.

```swift
// FileService의 list / chmod / mkdir / remove / copyAcross 메서드를
// 실제 ssh/scp/curl 또는 libssh2/SwiftNIO 호출로 교체하면 끝.
```

UI 계층(`Views/`)과 모델(`Models/`)은 백엔드에 대해 알지 못하므로 한 줄도 수정할 필요 없습니다. `FileService.shared`가 `actor`이기 때문에 모든 호출이 비동기로 안전하게 처리됩니다.

## 보너스: 모의 데이터

각 호스트는 별도의 가상 파일 트리를 가집니다.

- `local:localhost` — Mac 홈 디렉토리 (Documents, Downloads, …)
- `sftp:prod.example.com` — Ubuntu 서버 (`/var/www/html`, `/var/www/logs`, `/var/www/backups`)
- `ftp:files.acme.co` — 공유 FTP (`/public_html`, `/private`, `/downloads`)
- `webdav:demo` — Nextcloud 풍 (Photos, Documents, Calendar, …)
- `s3:bucket` — S3 버킷 (assets/, backups/, logs/)
- `smb:nas` — NAS (공유문서, 사진, 음악, 백업)

같은 호스트로 다시 연결하면 이전에 변경한 내용(chmod, mkdir 등)이 그대로 유지됩니다.

## 코딩 수정시
항상 뭔가를 수정하면 가상 테스트든 오류체크든 문제가 없는지 확인을 해줘.

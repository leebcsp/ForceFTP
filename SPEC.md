# ForceFTP - 기능 정의서

## 1. 개요

ForceFTP는 macOS용 듀얼 패널 파일 관리자 및 FTP/SFTP 클라이언트입니다.
로컬 파일 시스템과 원격 서버 간 파일 탐색, 전송, 관리를 하나의 인터페이스에서 수행합니다.

- **플랫폼**: macOS (SwiftUI)
- **최소 윈도우**: 1100 × 700
- **기본 윈도우**: 1400 × 900
- **아키텍처**: MVVM + Actor (async/await)

---

## 2. 지원 프로토콜

| 프로토콜 | 기본 포트 | 구현 방식 | 상태 |
|----------|-----------|-----------|------|
| Local | — | FileManager | 완료 |
| SFTP | 22 | ssh/scp + ControlMaster | 완료 |
| FTP | 21 | curl | 완료 |
| FTPS | 990 | curl --ssl-reqd | 완료 |
| Google Drive | — | REST API v3 + OAuth2 | 완료 |
| WebDAV | 443 | — | UI만 |
| S3 | 443 | — | UI만 |
| SMB | 445 | — | UI만 |

---

## 3. 화면 구성

```
┌────────┬────────────────────────────────────────────────┬──────────┐
│        │  Left Pane          │ ← → │  Right Pane         │          │
│ Side   │  ┌─ Header ───────┐ │     │ ┌─ Header ────────┐ │ Inspec-  │
│ bar    │  ├─ Path Bar ─────┤ │     │ ├─ Path Bar ──────┤ │ tor      │
│        │  ├─ Column Header ┤ │     │ ├─ Column Header ─┤ │ Panel    │
│ (180   │  ├─ File List ────┤ │     │ ├─ File List ─────┤ │ (280px)  │
│ ~280px)│  ├─ Pane Status ──┤ │     │ ├─ Pane Status ───┤ │          │
│        │  └─ Terminal ─────┘ │     │ └─ Terminal ──────┘ │          │
├────────┴────────────────────┴─────┴─────────────────────┴──────────┤
│ Transfer Panel (60~400px, 접기 가능)                                │
├────────────────────────────────────────────────────────────────────┤
│ Status Bar                                                         │
└────────────────────────────────────────────────────────────────────┘
```

### 3.1 사이드바

| 섹션 | 설명 |
|------|------|
| 장치 | 로컬 Mac (디스크 여유 공간 표시) |
| 최근 접속 | 최근 접속한 서버 목록 (최대 10개) |
| 태그 | Finder 태그 7색 (빨강/주황/노랑/초록/파랑/보라/회색) |
| 즐겨찾기 | 로컬 폴더 + 원격 경로 (드래그 정렬, Finder 드롭 추가) |

- 태그 클릭 시 해당 색상 파일만 필터링 (로컬: Spotlight, 원격: TagStore)
- 즐겨찾기 더블클릭: 로컬은 해당 경로 이동, 원격은 접속 + 이동
- 하단: 앱 버전 + 빌드 날짜

### 3.2 패널 (좌/우)

각 패널은 독립된 파일 브라우저입니다.

**패널 헤더 (30px)**
- 접속 아이콘 + 이름/호스트
- 프로토콜 배지 (색상 구분)
- 상태: 디스크 여유 공간 (로컬) 또는 항목 수 (원격)
- 터미널 토글, 새로고침 버튼

**경로 바 (24px)**
- 브레드크럼 방식 경로 표시
- 각 경로 요소 클릭 시 해당 디렉토리로 이동

**컬럼 헤더 (22px)**
- 정렬 가능 컬럼: 이름, 크기 (80px), 수정일 (140px)
- 클릭 시 정렬 방향 토글 (오름차순/내림차순)

**파일 목록**
- 트리 구조 (폴더 펼치기/접기)
- 파일 아이콘: 시스템 아이콘 + 확장자별 캐시 (IconCache, LRU 500개)
- 선택: 단일 / Shift 범위 / Cmd 다중 / 마키 영역 선택
- 인라인 이름 변경 (Enter 키)
- 드래그 앤 드롭 (패널 간 / Finder 연동)
- 전송 중 파일에 프로그레스 원형 오버레이 표시

**패널 상태 바 (18px)**
- 선택 항목 수 및 크기 표시

**내장 터미널 (60~400px, 접기 가능)**
- 로컬: bash 실행
- 원격: SSH 세션 (sshpass 인증, PTY 할당)
- cd, clear 등 기본 명령 지원
- 실시간 출력 스트리밍

### 3.3 인스펙터 패널 (280px)

**단일 파일 선택 시**
- 128×128 아이콘 (로컬: QuickLook 썸네일, 이미지 EXIF 보정, 동영상 프레임 추출)
- 파일 정보: 경로, 크기, 수정일, 확장자
- 토글: 확장자 숨기기, 숨김 파일
- 권한 편집: Owner/Group/Other (rwx), 옥타/심볼릭 표시
- 소유자/그룹 변경
- 잠금 토글 (로컬 전용)

**다중 선택 시**
- 아이콘 스택 (최대 5개, 회전/오프셋)
- 요약: 항목 수, 파일/폴더 수, 총 크기
- 일괄 권한 변경 (변경된 필드만 적용)

### 3.4 전송 패널

**전송 탭**
- 전송 항목별 표시: 방향 아이콘 (↑ 업로드/↓ 다운로드), 파일명, 진행률 바, 상태, 취소 버튼
- 폴더 전송: 펼쳐서 개별 파일 상태 확인
- 완료 항목 일괄 삭제

**로그 탭**
- 타임스탬프 [HH:MM:SS] + 컬러 메시지
- 레벨: info (회색), ok (초록), error (빨강)
- 최대 500개 유지

### 3.5 상태 바

- 현재 전송 상태 요약
- 전송 패널 토글 버튼

---

## 4. 주요 기능

### 4.1 파일 탐색

| 기능 | 설명 |
|------|------|
| 디렉토리 이동 | 더블클릭 또는 경로 바 클릭 |
| 뒤로/앞으로 | 히스토리 기반 탐색 (Cmd+[ / Cmd+]) |
| 트리 확장 | 폴더 좌측 화살표 클릭 또는 → 키 |
| 트리 접기 | ← 키 또는 전체 접기 |
| 숨김 파일 | 토글로 표시/숨김 (앱 전체) |
| 검색 | 로컬: Spotlight (mdfind), 원격: 이름 필터링 |
| 태그 필터 | 사이드바 태그 클릭으로 색상별 필터 |
| 파일 감시 | 로컬 디렉토리 변경 자동 감지 및 새로고침 |

### 4.2 파일 전송

| 시나리오 | 구현 방식 |
|----------|-----------|
| Local → SFTP | scp |
| Local → FTP/FTPS | curl -T |
| SFTP → Local | scp |
| FTP/FTPS → Local | curl -o |
| Local → Google Drive | REST multipart upload |
| Google Drive → Local | REST download |
| Server → Server | 로컬 임시 폴더 경유 (다운로드 + 업로드) |
| SFTP 동일 서버 | 서버측 cp (최적화) |

- 최대 동시 전송: 2개 (설정 가능, 1~8)
- 폴더 전송: 재귀 수집 후 병렬 처리 (최대 4개 동시)
- 속도 측정: 0.5초 간격 (bps, ETA 계산)
- 전역 속도: 업로드/다운로드 합산 표시

### 4.3 파일 관리

| 기능 | 로컬 | SFTP | FTP | Google Drive |
|------|------|------|-----|-------------|
| 새 폴더 | O | O | O | O |
| 이름 변경 | O | O | O | O |
| 삭제 | O (휴지통) | O | O | O |
| 복사/붙여넣기 | O | O | O | — |
| 이동 | O | O | — | — |
| 권한 변경 (chmod) | O | O | — | — |
| 소유자 변경 (chown) | O | O | — | — |
| 태그 지정 | O (xattr) | O (TagStore) | O (TagStore) | — |
| 실행 취소 | O (붙여넣기/삭제) | — | — | — |

### 4.4 미리보기

- **QuickLook**: 스페이스바로 로컬 파일 미리보기
- **줌 애니메이션**: 파일 아이콘에서 확대되며 열리고, 닫힐 때 아이콘으로 축소
- **전환 이미지**: 파일 시스템 아이콘을 트랜지션에 사용

### 4.5 정보보기

- **줌 애니메이션**: 파일 아이콘에서 확대되며 오버레이 표시, 닫힐 때 축소
- **일반 정보**: 종류, 크기, 위치, 수정일, 소유자:그룹
- **권한 편집**: Owner/Group/Other × Read/Write/Execute 체크박스
- **옥타/심볼릭 표시**: 실시간 변환 (예: 755 ↔ rwxr-xr-x)
- **하위 적용**: 폴더 선택 시 chmod -R 옵션
- **적용 후 자동 새로고침**

### 4.6 접속 관리

**접속 대화상자**
- 프로토콜별 탭 전환 (SFTP, FTP, FTPS, WebDAV, S3, SMB)
- Google Drive 별도 OAuth2 로그인 폼
- 서버, 포트, 사용자명, 비밀번호, 원격 경로 입력
- SFTP 인증 방식: 비밀번호 / SSH 키 / SSH Agent
- 익명 접속 (FTP)
- 접속 테스트 버튼
- 즐겨찾기 추가 옵션

**Google Drive OAuth2 흐름**
1. 클라이언트 ID/Secret 입력 (설정에서 저장)
2. 브라우저 열기 → Google 계정 승인
3. 로컬 루프백 서버 (자동 포트)로 인증 코드 수신
4. 토큰 교환 → refresh_token 저장
5. 만료 시 자동 갱신

### 4.7 SSH ControlMaster

- 소켓 경로: `~/.ControlMaster/ssh-%r@%h:%p`
- 재사용 시간: 60초 (ControlPersist)
- 동일 서버 연속 명령 시 재인증 없이 소켓 재사용
- StrictHostKeyChecking=no (기본)

### 4.8 드래그 앤 드롭

| 소스 → 대상 | 동작 |
|-------------|------|
| 패널 → 패널 | 파일 전송 (업로드/다운로드/서버간) |
| Finder → 패널 | 파일 업로드/복사 |
| 파일 → 사이드바 즐겨찾기 | 폴더를 즐겨찾기에 추가 |
| 즐겨찾기 → 즐겨찾기 | 순서 변경 |

- 커스텀 UTType: `com.transmitlite.dragitem`
- 드래그 이미지: Finder 스타일 다중 파일 배지 + 개수 표시

---

## 5. 데이터 모델

### 5.1 Connection

```swift
struct Connection: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var proto: TransferProtocol
    var host: String
    var port: Int
    var username: String
    var password: String
    var remotePath: String
    var anonymous: Bool
}
```

### 5.2 RemoteItem

```swift
struct RemoteItem: Identifiable, Hashable {
    var id: UUID
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date
    var permissions: String    // "rwxr-xr-x"
    var owner: String
    var group: String
    var tagColorName: String?  // Finder 태그 색상
    var fullPath: String?      // 검색 결과용
}
```

### 5.3 Transfer

```swift
class Transfer: ObservableObject, Identifiable {
    let id: UUID
    let name, sourcePath, destinationPath: String
    let direction: TransferDirection  // .upload / .download
    let totalBytes: Int64
    let isDirectory: Bool
    @Published var transferredBytes: Int64
    @Published var status: TransferStatus  // .queued/.active/.completed/.failed/.cancelled
    @Published var speedBps: Int64
    @Published var etaSeconds: Double
    @Published var currentFileName: String?
    @Published var totalFileCount, completedFileCount: Int
}
```

### 5.4 Permissions

```swift
struct Permissions {
    var ownerRead, ownerWrite, ownerExec: Bool
    var groupRead, groupWrite, groupExec: Bool
    var otherRead, otherWrite, otherExec: Bool
    var octal: String      // "755"
    var symbolic: String   // "rwxr-xr-x"
}
```

---

## 6. 데이터 영속성

| 데이터 | 저장 방식 |
|--------|-----------|
| 저장된 접속 | UserDefaults (JSON) |
| 최근 접속 | UserDefaults (JSON) |
| 즐겨찾기 | UserDefaults (JSON) |
| 태그 (원격) | UserDefaults (TagStore, key: host:port/path) |
| 레이아웃 설정 | @AppStorage |
| 마지막 패널 상태 | UserDefaults |
| Google Drive 토큰 | Connection.password (refresh_token) |
| Google API 키 | UserDefaults (googleDrive.clientId/clientSecret) |
| 아이콘 캐시 | 메모리 (IconCache, LRU 500개) |

---

## 7. 파일 구조

```
ForceFTP/
├── ForceFTPApp.swift              # 앱 진입점, 메뉴, 단축키
├── Models/
│   ├── Models.swift               # 데이터 모델 (Connection, RemoteItem, Transfer 등)
│   └── AppState.swift             # 앱 상태 (PaneState, Clipboard, UndoAction 등)
├── Services/
│   ├── FileService.swift          # 파일 작업 (모든 프로토콜)
│   ├── TransferManager.swift      # 전송 큐 관리
│   └── GoogleDriveService.swift   # Google Drive API + OAuth2
└── Views/
    ├── ContentView.swift          # 메인 윈도우 레이아웃
    ├── PaneView.swift             # 파일 브라우저 패널
    ├── SidebarView.swift          # 사이드바 (장치/접속/태그/즐겨찾기)
    ├── ConnectSheet.swift         # 접속 대화상자
    ├── InfoSheet.swift            # 파일 정보 / chmod
    ├── InspectorView.swift        # 인스펙터 패널
    ├── BottomPanel.swift          # 전송/로그 패널
    ├── SettingsView.swift         # 설정 (일반/전송/정보)
    ├── PaneTerminal.swift         # 내장 터미널
    ├── TerminalView.swift         # (미사용)
    └── QuickLookPreview.swift     # QuickLook 미리보기
```

---

## 8. 키보드 단축키

### 8.1 전역 (메뉴)

| 단축키 | 기능 |
|--------|------|
| Cmd+K | 새 접속 |
| Cmd+Shift+E | 접속 해제 |
| Cmd+U | 업로드 |
| Cmd+D | 다운로드 |
| Cmd+R | 새로고침 |
| Cmd+I | 정보보기 (chmod) |
| Cmd+C | 파일 복사 |
| Cmd+V | 파일 붙여넣기 |
| Cmd+Shift+C | 경로 복사 |

### 8.2 파일 목록

| 단축키 | 기능 |
|--------|------|
| Space | QuickLook 미리보기 |
| Enter | 이름 변경 |
| ↑ / ↓ | 선택 이동 |
| → | 폴더 펼치기 |
| ← | 폴더 접기 / 상위로 |
| Cmd+A | 전체 선택 |
| Cmd+⌫ | 삭제 |
| Shift+클릭 | 범위 선택 |
| Cmd+클릭 | 다중 선택 |

### 8.3 정보보기

| 단축키 | 기능 |
|--------|------|
| Escape | 취소 (닫기) |
| Return | 적용 |

---

## 9. 설정

| 항목 | 기본값 | 설명 |
|------|--------|------|
| 숨김 파일 표시 | false | .으로 시작하는 파일 표시 |
| 최대 동시 전송 | 2 | 1~8 범위 |
| 전송 패널 표시 | true | 하단 전송/로그 패널 |
| 인스펙터 표시 | true | 우측 인스펙터 패널 |
| 인스펙터 너비 | 280px | 조절 가능 |
| 좌우 패널 비율 | 0.5 | 0.2~0.8 범위 |

---

## 10. 외부 의존성

| 도구 | 용도 | 경로 |
|------|------|------|
| ssh | SFTP 접속/명령 | /usr/bin/ssh |
| scp | SFTP 파일 전송 | /usr/bin/scp |
| curl | FTP/FTPS 전송 | /usr/bin/curl |
| sshpass | SSH 비밀번호 인증 | /opt/homebrew/bin 또는 /usr/local/bin |
| chmod | 권한 변경 | /bin/chmod |
| chown | 소유자 변경 | /usr/sbin/chown |
| mdfind | Spotlight 검색 | /usr/bin/mdfind |
| script | PTY 할당 (터미널) | /usr/bin/script |
| bash | 로컬 터미널 | /bin/bash |

---

## 11. 애니메이션

| 대상 | 효과 |
|------|------|
| QuickLook 미리보기 | 파일 아이콘에서 줌인 → 닫힐 때 줌아웃 |
| 정보보기 | 파일 아이콘에서 줌인 → 닫힐 때 줌아웃 |
| 드래그 앤 드롭 | Finder 스타일 다중 파일 배지 |
| 전송 진행 | 파일 아이콘 위 원형 프로그레스 |
| 패널 리사이즈 | 드래그 핸들로 실시간 조절 |

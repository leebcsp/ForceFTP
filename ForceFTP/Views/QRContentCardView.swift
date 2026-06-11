//
//  QRContentCardView.swift
//  ForceFTP
//

import SwiftUI
import MapKit

struct QRContentCardView: View {
    let qr: QRContent
    @EnvironmentObject var app: AppState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch qr {
        case .url(let urlString):
            qrCard {
                HStack(spacing: 10) {
                    iconBox("globe", .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("웹 링크")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(urlString)
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
                qrActionButton("Safari에서 열기", icon: "safari", color: .blue) {
                    if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
                }
                qrActionButton("링크 복사", icon: "doc.on.doc", color: .secondary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urlString, forType: .string)
                    app.appendLog(.ok, "링크 복사됨")
                }
            }

        case .wifi(let ssid, let password, let security):
            qrCard {
                HStack(spacing: 10) {
                    iconBox("wifi", .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wi-Fi 네트워크")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(ssid)
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                Divider().padding(.vertical, 2)
                qrDetailRow(icon: "lock.shield", label: "보안", value: security.isEmpty ? "없음" : security)
                if !password.isEmpty {
                    qrDetailRow(icon: "key", label: "비밀번호", value: password, mono: true)
                }
                qrActionButton("Wi-Fi 연결 (설정 열기)", icon: "wifi.circle", color: .blue) {
                    Self.connectToWiFi(ssid: ssid, password: password)
                }
                qrActionButton("비밀번호 복사", icon: "doc.on.doc", color: .green) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(password, forType: .string)
                    app.appendLog(.ok, "비밀번호 복사됨")
                }
            }

        case .vCard(let info):
            qrCard {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Text(String(info.name.prefix(1)).uppercased())
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.name)
                            .font(.system(size: 15, weight: .semibold))
                        if !info.title.isEmpty || !info.org.isEmpty {
                            Text([info.title, info.org].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !info.phones.isEmpty || !info.emails.isEmpty {
                    Divider().padding(.vertical, 4)
                }
                ForEach(Array(info.phones.enumerated()), id: \.offset) { _, phone in
                    qrContactRow(icon: "phone.fill", iconColor: .green, label: "전화", value: Self.formatPhone(phone)) {
                        if let url = URL(string: "tel:\(phone)") { NSWorkspace.shared.open(url) }
                    }
                }
                ForEach(Array(info.emails.enumerated()), id: \.offset) { _, email in
                    qrContactRow(icon: "envelope.fill", iconColor: .blue, label: "이메일", value: email) {
                        if let url = URL(string: "mailto:\(email)") { NSWorkspace.shared.open(url) }
                    }
                }
                if !info.address.isEmpty {
                    qrContactRow(icon: "mappin.circle.fill", iconColor: .red, label: "주소", value: info.address) {}
                }
                if !info.url.isEmpty {
                    qrContactRow(icon: "globe", iconColor: .blue, label: "웹사이트", value: info.url) {
                        if let url = URL(string: info.url) { NSWorkspace.shared.open(url) }
                    }
                }
                if !info.birthday.isEmpty {
                    qrDetailRow(icon: "gift", label: "생일", value: info.birthday)
                }
                if !info.note.isEmpty {
                    qrDetailRow(icon: "note.text", label: "메모", value: info.note)
                }
                qrActionButton("연락처에 추가", icon: "person.badge.plus", color: .blue) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info.name, forType: .string)
                    app.appendLog(.ok, "연락처 복사됨: \(info.name)")
                }
            }

        case .email(let addr, let subject, let body):
            qrCard {
                HStack(spacing: 10) {
                    iconBox("envelope.fill", .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("이메일")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(addr)
                            .font(.system(size: 13, weight: .medium))
                            .textSelection(.enabled)
                    }
                }
                if !subject.isEmpty {
                    Divider().padding(.vertical, 2)
                    qrDetailRow(icon: "text.alignleft", label: "제목", value: subject)
                }
                if !body.isEmpty {
                    qrDetailRow(icon: "doc.text", label: "내용", value: body)
                }
                qrActionButton("메일 작성", icon: "envelope.open", color: .blue) {
                    var mailto = "mailto:\(addr)"
                    var params: [String] = []
                    if !subject.isEmpty { params.append("subject=\(subject)") }
                    if !body.isEmpty { params.append("body=\(body)") }
                    if !params.isEmpty { mailto += "?" + params.joined(separator: "&") }
                    if let url = URL(string: mailto) { NSWorkspace.shared.open(url) }
                }
            }

        case .phone(let number):
            qrCard {
                HStack(spacing: 10) {
                    iconBox("phone.fill", .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("전화번호")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(Self.formatPhone(number))
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .textSelection(.enabled)
                    }
                }
                qrActionButton("FaceTime", icon: "video.fill", color: .green) {
                    if let url = URL(string: "facetime:\(number)") { NSWorkspace.shared.open(url) }
                }
                qrActionButton("번호 복사", icon: "doc.on.doc", color: .secondary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(number, forType: .string)
                    app.appendLog(.ok, "번호 복사됨")
                }
            }

        case .sms(let number, let body):
            qrCard {
                HStack(spacing: 10) {
                    iconBox("message.fill", .green)
                    Text("문자 메시지")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Divider().padding(.vertical, 4)
                HStack(spacing: 8) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("받는 사람")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(Self.formatPhone(number))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .textSelection(.enabled)
                    }
                }
                if !body.isEmpty {
                    Divider().padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text("내용")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Text(body)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(8)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.green.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                Divider().padding(.vertical, 4)
                qrActionButton("메시지 보내기", icon: "paperplane.fill", color: .green) {
                    var smsURL = "sms:\(number)"
                    if !body.isEmpty {
                        smsURL += "?body=\(body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body)"
                    }
                    if let url = URL(string: smsURL) { NSWorkspace.shared.open(url) }
                }
                qrActionButton("번호 복사", icon: "doc.on.doc", color: .secondary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(number, forType: .string)
                    app.appendLog(.ok, "번호 복사됨")
                }
            }

        case .calendar(let event):
            qrCard {
                HStack(spacing: 10) {
                    VStack(spacing: 0) {
                        Text(Self.calendarMonth(event.dtstart))
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.red)
                            .textCase(.uppercase)
                        Text(Self.calendarDay(event.dtstart))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                    .frame(width: 40, height: 40)
                    .background(Color.panelList)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.summary.isEmpty ? "일정" : event.summary)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2)
                    }
                }
                Divider().padding(.vertical, 4)
                qrDetailRow(icon: "clock", label: "시작", value: Self.formatEventDate(event.dtstart))
                if !event.dtend.isEmpty {
                    qrDetailRow(icon: "clock.badge.checkmark", label: "종료", value: Self.formatEventDate(event.dtend))
                }
                if !event.location.isEmpty {
                    qrDetailRow(icon: "mappin.and.ellipse", label: "장소", value: event.location)
                }
                if !event.organizer.isEmpty {
                    qrDetailRow(icon: "person", label: "주최", value: event.organizer.replacingOccurrences(of: "mailto:", with: ""))
                }
                if !event.description_.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("설명")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(event.description_.replacingOccurrences(of: "\\n", with: "\n"))
                            .font(.system(size: 11))
                            .lineLimit(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                qrActionButton("캘린더에 추가", icon: "calendar.badge.plus", color: .red) {
                    Self.addToCalendar(event)
                }
            }

        case .bank(let info):
            qrCard {
                HStack(spacing: 10) {
                    iconBox("banknote", .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("은행 정보")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        if !info.bankName.isEmpty {
                            Text(info.bankName)
                                .font(.system(size: 14, weight: .semibold))
                        }
                    }
                }
                Divider().padding(.vertical, 4)
                if !info.accountHolder.isEmpty {
                    qrDetailRow(icon: "person", label: "예금주", value: info.accountHolder)
                }
                if !info.accountNumber.isEmpty {
                    qrDetailRow(icon: "number", label: "계좌번호", value: info.accountNumber, mono: true)
                }
                if !info.amount.isEmpty {
                    let formatted: String = {
                        let digits = info.amount.filter(\.isNumber)
                        guard let num = Int(digits) else { return info.amount }
                        let fmt = NumberFormatter()
                        fmt.numberStyle = .decimal
                        return fmt.string(from: NSNumber(value: num)) ?? info.amount
                    }()
                    qrDetailRow(icon: "wonsign.circle", label: "금액", value: formatted)
                }
                ForEach(Array(info.fields.enumerated()), id: \.offset) { _, field in
                    if !field.value.isEmpty {
                        qrDetailRow(icon: "doc.text", label: field.key.isEmpty ? "정보" : field.key, value: field.value)
                    }
                }
                if !info.accountNumber.isEmpty {
                    qrActionButton("계좌번호 복사", icon: "doc.on.doc", color: .orange) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(info.accountNumber, forType: .string)
                        app.appendLog(.ok, "계좌번호 복사됨")
                    }
                }
            }

        case .geo(let lat, let lon):
            qrCard {
                HStack(spacing: 10) {
                    iconBox("map.fill", .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("위치")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.4f", lat)), \(String(format: "%.4f", lon))")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                }
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))) {
                    Marker("", coordinate: coord)
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)

                qrActionButton("지도에서 열기", icon: "map", color: .red) {
                    if let url = URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                qrActionButton("좌표 복사", icon: "doc.on.doc", color: .secondary) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(lat), \(lon)", forType: .string)
                    app.appendLog(.ok, "좌표 복사됨")
                }
            }

        case .text(let content):
            qrCard {
                HStack(spacing: 10) {
                    iconBox("doc.text", .orange)
                    Text("텍스트")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text(content)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.panelList)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                qrActionButton("복사", icon: "doc.on.doc", color: .orange) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    app.appendLog(.ok, "텍스트 복사됨")
                }
            }
        }
    }

    // MARK: - Components

    @ViewBuilder
    private func iconBox(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 20))
            .foregroundStyle(color)
            .frame(width: 40, height: 40)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func qrCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if colorScheme == .light {
                ZStack {
                    Color.white
                    Rectangle().fill(.black).frame(width: 200, height: 40).offset(x: -30, y: -50)
                    Rectangle().fill(.white).frame(width: 60, height: 80).offset(x: -80, y: 10)
                    Rectangle().fill(.black).frame(width: 150, height: 30).offset(x: 50, y: -10)
                    Rectangle().fill(.black.opacity(0.9)).frame(width: 80, height: 100).offset(x: -40, y: 40)
                    Rectangle().fill(.white).frame(width: 40, height: 50).offset(x: 70, y: 50)
                    Rectangle().fill(.black).frame(width: 120, height: 20).offset(x: 20, y: 70)
                    Rectangle().fill(.black.opacity(0.8)).frame(width: 50, height: 60).offset(x: 100, y: -40)
                    Rectangle().fill(.white).frame(width: 90, height: 25).offset(x: -60, y: -20)
                }
                .blur(radius: 35)
                .opacity(0.18)
            } else {
                Color.panelCard
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.panelBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func qrDetailRow(icon: String, label: String, value: String, mono: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func qrContactRow(icon: String, iconColor: Color, label: String, value: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 20, height: 20)
                .background(iconColor.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }

    @ViewBuilder
    private func qrActionButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    static func formatPhone(_ raw: String) -> String {
        let digits = raw.filter { $0.isNumber || $0 == "+" }
        let d = digits.hasPrefix("+82") ? "0" + digits.dropFirst(3) : (digits.hasPrefix("+") ? String(digits.dropFirst()) : digits)
        let count = d.count
        if count == 11 && d.hasPrefix("01") {
            let i3 = d.index(d.startIndex, offsetBy: 3)
            let i7 = d.index(d.startIndex, offsetBy: 7)
            return "\(d[d.startIndex..<i3])-\(d[i3..<i7])-\(d[i7...])"
        }
        if count == 10 && d.hasPrefix("02") {
            let i2 = d.index(d.startIndex, offsetBy: 2)
            let i6 = d.index(d.startIndex, offsetBy: 6)
            return "\(d[d.startIndex..<i2])-\(d[i2..<i6])-\(d[i6...])"
        }
        if count == 10 {
            let i3 = d.index(d.startIndex, offsetBy: 3)
            let i6 = d.index(d.startIndex, offsetBy: 6)
            return "\(d[d.startIndex..<i3])-\(d[i3..<i6])-\(d[i6...])"
        }
        if count == 9 && d.hasPrefix("02") {
            let i2 = d.index(d.startIndex, offsetBy: 2)
            let i5 = d.index(d.startIndex, offsetBy: 5)
            return "\(d[d.startIndex..<i2])-\(d[i2..<i5])-\(d[i5...])"
        }
        if raw.contains("-") { return raw }
        return raw
    }

    private static func parseEventDate(_ str: String) -> Date? {
        let clean = str.trimmingCharacters(in: .whitespaces)
        let fmts = ["yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmmss", "yyyyMMdd"]
        for fmt in fmts {
            let df = DateFormatter()
            df.dateFormat = fmt
            if fmt.hasSuffix("'Z'") { df.timeZone = TimeZone(identifier: "UTC") }
            if let d = df.date(from: clean) { return d }
        }
        return nil
    }

    private static func formatEventDate(_ str: String) -> String {
        guard let date = parseEventDate(str) else { return str }
        let df = DateFormatter()
        df.dateFormat = "yyyy년 M월 d일 (E) a h:mm"
        df.locale = Locale(identifier: "ko_KR")
        return df.string(from: date)
    }

    private static func calendarMonth(_ str: String) -> String {
        guard let date = parseEventDate(str) else { return "" }
        let df = DateFormatter()
        df.dateFormat = "MMM"
        df.locale = Locale(identifier: "ko_KR")
        return df.string(from: date)
    }

    private static func calendarDay(_ str: String) -> String {
        guard let date = parseEventDate(str) else { return "" }
        let df = DateFormatter()
        df.dateFormat = "d"
        return df.string(from: date)
    }

    private static func addToCalendar(_ event: CalendarEventInfo) {
        let ics = """
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//ForceFTP//QR//KO
        BEGIN:VEVENT
        SUMMARY:\(event.summary)
        DTSTART:\(event.dtstart)
        DTEND:\(event.dtend.isEmpty ? event.dtstart : event.dtend)
        LOCATION:\(event.location)
        DESCRIPTION:\(event.description_)
        END:VEVENT
        END:VCALENDAR
        """
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("qr_event.ics")
        try? ics.write(to: tmpURL, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(tmpURL)
    }

    private static func connectToWiFi(ssid: String, password: String) {
        let script = """
        tell application "System Preferences"
            activate
            reveal pane id "com.apple.preference.network"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
    }
}

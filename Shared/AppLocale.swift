import Foundation
import SwiftUI

/// 앱이 날짜와 숫자를 적는 기준. 앱 타깃과 위젯 타깃이 함께 쓴다.
///
/// 아랍어 화면에서는 달력을 양력으로, 숫자를 0~9 로 고정한다.
/// 사우디 등 아랍어 기기는 지역 설정에 따라 이슬람력과 ١٢٣ 숫자를 쓰는데,
/// 어린이집 · 학교 일정표는 양력 날짜로 오고 사진 읽기도 양력 연 · 월 · 일로 계산한다.
/// 기기 달력을 그대로 따르면 달력 격자는 이슬람력 달, 일정은 양력 날짜로 어긋나고,
/// 한 화면에 ١٢ 와 12 가 섞인다.
/// 다른 언어는 기기 설정을 그대로 따른다 (태국 불기 등은 바꾸지 않는다).
enum AppLocale {
    static let isArabic = Bundle.main.preferredLocalizations.first?.hasPrefix("ar") == true

    /// 날짜 · 숫자를 적을 로케일. 아랍어가 아니면 기기 로케일 그대로.
    static let locale: Locale = {
        guard isArabic else { return .autoupdatingCurrent }
        var components = Locale.Components(locale: .current)
        components.calendar = .gregorian
        components.numberingSystem = "latn"
        return Locale(components: components)
    }()
}

extension Calendar {
    /// 앱이 날짜를 계산하는 달력. 아랍어에서는 양력이고, 주 시작 요일은 기기 설정을 따른다.
    static var app: Calendar {
        guard AppLocale.isArabic else { return .current }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = AppLocale.locale
        calendar.timeZone = .current
        calendar.firstWeekday = Calendar.current.firstWeekday
        calendar.minimumDaysInFirstWeek = Calendar.current.minimumDaysInFirstWeek
        return calendar
    }
}

extension String {
    /// 아랍 숫자(٠١٢ · ۰۱۲)를 0~9 로 바꾼다. 아랍어 안내문 사진과 문자에서 날짜를 읽을 때 쓴다.
    var withWesternDigits: String {
        String(String.UnicodeScalarView(unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x0660...0x0669: return Unicode.Scalar(scalar.value - 0x0660 + 0x30)!
            case 0x06F0...0x06F9: return Unicode.Scalar(scalar.value - 0x06F0 + 0x30)!
            default: return scalar
            }
        }))
    }
}

extension String {
    /// 아랍 글자가 들어 있는가. 사진 속 표의 칸을 오른쪽부터 읽을지 정한다.
    var hasArabicLetters: Bool {
        unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
    }
}

extension Date.FormatStyle {
    /// 앱 로케일과 달력으로 적는다 (아랍어: 양력 · 0~9, 그 밖: 기기 설정).
    var inApp: Date.FormatStyle {
        var style = self
        style.locale = AppLocale.locale
        style.calendar = .app
        return style
    }
}

extension View {
    /// 화면 속 날짜 · 숫자 · 날짜 고르기를 앱 기준(아랍어: 양력 · 0~9)으로 맞춘다. 시트도 이 값을 물려받는다.
    @ViewBuilder func appLocale() -> some View {
        if AppLocale.isArabic {
            environment(\.locale, AppLocale.locale).environment(\.calendar, .app)
        } else {
            self
        }
    }
}

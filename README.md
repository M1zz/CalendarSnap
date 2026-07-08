# CalendarSnap

달력을 사진으로 찍으면 **Vision OCR → 일정 파싱 → 홈 화면 위젯 + 로컬 알림**으로 이어지는 iOS 앱.

## 구조

```
CalendarSnap/            앱 타깃
  CalendarSnapApp.swift
  ContentView.swift      카메라/사진 선택, 추출 일정 편집 UI
  OCRService.swift       VNRecognizeTextRequest (ko-KR + en-US)
  EventParser.swift      "7월 12일 치과", "12일 14:00 미팅", 7/15, 오후 3시 등 파싱
  NotificationManager.swift  일정 30분 전 + 정각 로컬 알림
Shared/                  양쪽 타깃 공유
  ScannedEvent.swift
  EventStore.swift       App Group UserDefaults + WidgetCenter reload
ScheduleWidget/          위젯 익스텐션 (systemSmall / systemMedium)
```

## 실행 전 3가지 설정

1. **Signing**: 두 타깃 모두 본인 Team 선택 (Signing & Capabilities)
2. **App Group**: `group.com.devkoan.calendarsnap`을 본인 것으로 변경
   - `Shared/ScannedEvent.swift`의 `AppGroup.identifier`
   - 두 entitlements 파일
   - 두 타깃의 Capabilities에서 App Groups 활성화
3. **Bundle ID**: `com.devkoan.CalendarSnap` / `.ScheduleWidget`을 필요 시 변경
   (위젯 번들 ID는 반드시 앱 번들 ID의 하위여야 함)

## 흐름

1. 카메라 또는 앨범에서 달력 사진 입력
2. Vision이 텍스트 추출 → EventParser가 월 헤더("7월") 컨텍스트를 잡고 날짜/시간/제목 분리
3. 리스트에서 제목·일시 수정 가능
4. "위젯에 저장 + 알림 등록" → App Group 저장, 위젯 갱신, UNUserNotificationCenter 예약

## 참고

- 최소 iOS 17.0 / Xcode 15+
- 시간이 없는 일정은 오전 9시로 기본 설정
- 손글씨 달력은 인식률이 낮을 수 있음 — 인쇄체 기준으로 튜닝됨

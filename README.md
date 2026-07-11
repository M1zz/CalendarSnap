# CalendarSnap

어린이집 알림장·달력을 사진으로 찍으면 **Vision OCR → 한 달 일정 파싱 → 애플 캘린더 일괄 등록 + 준비물 알림 + 홈 화면 위젯**으로 이어지는 iOS 앱.

> 어린이집 아이의 한 달 일정을 한 번에 캘린더에 넣고, 전날 저녁·당일 아침에 준비물 알림을 받는 것이 목표입니다.

## 주요 기능

- 📸 **사진 한 장 → 한 달 일정 추출**: 카메라/앨범 이미지에서 날짜·시간·제목을 자동 파싱
- 📅 **애플 캘린더 일괄 등록**: 전용 "(아이이름) 어린이집" 달력에 한 번에 추가, 중복 자동 제외, 가족과 공유 가능
- 🔔 **준비물 알림**: 전날 저녁 8시(준비물 챙기기) · 당일 아침 7시 30분 · 1시간 전 · 정시 중 선택
- 🗓 **종일 일정 지원**: 소풍·현장학습처럼 시간이 없는 일정은 자동으로 종일 일정 처리
- 📌 **준비물 메모**: 일정마다 "도시락 지참" 같은 메모 입력 → 알림 본문에 함께 표시
- 🧩 **홈 화면 위젯**: 다가오는 일정을 small/medium 위젯으로 표시

## 구조

```
CalendarSnap/            앱 타깃
  CalendarSnapApp.swift
  ContentView.swift      카메라/사진 선택, 추출 일정 편집(종일·메모), 일괄 추가 UI
  OCRService.swift       VNRecognizeTextRequest (ko-KR + en-US)
  EventParser.swift      "7월 12일 치과", "12일 14:00 미팅", 7/15, 오후 3시, 종일 일정 파싱
  NotificationManager.swift  설정 기반 로컬 알림(전날/당일/1시간 전/정시), 64개 상한 관리
  CalendarService.swift  EventKit 전용 달력 생성 + 한 달 일정 일괄 등록 + 중복 방지
  SettingsView.swift     아이 이름 · 알림 시점 · 캘린더 미러링 설정
Shared/                  양쪽 타깃 공유
  ScannedEvent.swift     일정 모델 (isAllDay·notes 포함, 구버전 데이터 호환)
  ReminderSettings.swift 알림 옵션·아이 이름·미러링 설정 (App Group 저장)
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

1. 카메라 또는 앨범에서 어린이집 알림장/달력 사진 입력
2. Vision이 텍스트 추출 → EventParser가 월 헤더("7월") 컨텍스트를 잡고 날짜/시간/제목 분리 (시간 없으면 종일)
3. 리스트에서 제목·일시·종일 여부·준비물 메모 수정, 필요 없는 일정은 밀어서 삭제
4. 설정(⚙️)에서 아이 이름·알림 시점·캘린더 미러링 지정
5. **"일정 추가하고 알림 받기"** → 위젯 저장 + 로컬 알림 예약 + (옵션) 애플 캘린더 일괄 등록

## 권한

- **카메라**: 달력 사진 촬영
- **알림**: 준비물/일정 로컬 알림
- **캘린더(전체 접근)**: 애플 캘린더 일괄 등록 및 중복 확인 (미러링을 끄면 사용 안 함)

## 참고

- 최소 iOS 17.0 / Xcode 15+
- 알림은 앱이 직접(로컬 알림) 담당하고, 캘린더에는 이벤트만 추가해 같은 알림이 두 번 울리지 않도록 했습니다
- 로컬 알림은 iOS 상한(앱당 64개)을 고려해 가까운 일정부터 최대 60개까지 예약
- 손글씨 달력은 인식률이 낮을 수 있음 — 인쇄체 기준으로 튜닝됨


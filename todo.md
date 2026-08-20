# CalendarSnap TODO

## v1.0.4
- [x] 버전 1.0.4 / 빌드 3으로 상향 (앱·위젯 4개 빌드 설정)
- [x] origin/main(1.0.3) 머지 — LeeoKit 피드백·리뷰, OCR 방향 개선과 가족 공유 통합
- [x] feat/family-share 브랜치 머지 — 구 구현(FamilyShareService/View)은 제외하고 문서(개인정보 처리방침·README)만 반영
- [ ] 확인 필요: 파일 내보내기("아이일정 사용자에게 보내기") 제거 유지 여부 — 머지에서 로컬(제거) 쪽 채택
- [ ] 수동: 실기기 2대 초대·수락 테스트 (아래 가족 공유 항목 참고)

## v1.0.1
- [x] 버전 1.0.1로 상향 (앱·위젯)
- [x] 달력 탭 공유 메뉴 제거 → "이 날 일정 공유하기"(하루치 텍스트)만 유지

## 반 필터
- [x] 아이 1명일 때 반 필터 미작동 버그 수정 (selectedChild 폴백)
- [x] rawText에만 남은 반 표기 감지
- [x] 저장된 다른 반 일정 정리 제안 (앱 시작·설정 변경 시)

## 가족 공유 (CloudKit CKShare)
- [x] Capability 설정 (entitlements·Info.plist·AppDelegate/SceneDelegate)
- [x] 동기화 코어 (RecordMapper·SyncStateStore·FamilySyncManager, CKSyncEngine)
- [x] 스토어 훅 + UI 연결 (EventStore/ReminderSettings/ChildAvatarStore 훅, 설정 화면 가족 공유 섹션)
- [x] pbxproj 새 파일 등록 + 빌드·시뮬레이터 실행 검증 (미로그인 상태 UI 확인)
- [ ] 수동: Xcode에서 iCloud(CloudKit)·Push Notifications capability 추가 확인 (팀 QGAQ3AY3R3 — entitlements는 이미 반영됨, Xcode가 포털에 컨테이너 등록하는지 확인 필요)
- [ ] 수동: 출시 전 CloudKit Console에서 스키마 Development → Production 배포
- [ ] 실기기 2대(서로 다른 Apple ID)로 초대→수락→양방향 동기화 테스트

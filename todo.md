# CalendarSnap TODO

## 가족 공유 (CloudKit CKShare)
- [x] Capability 설정 (entitlements·Info.plist·AppDelegate/SceneDelegate)
- [x] 동기화 코어 (RecordMapper·SyncStateStore·FamilySyncManager, CKSyncEngine)
- [x] 스토어 훅 + UI 연결 (EventStore/ReminderSettings/ChildAvatarStore 훅, 설정 화면 가족 공유 섹션)
- [x] pbxproj 새 파일 등록 + 빌드·시뮬레이터 실행 검증 (미로그인 상태 UI 확인)
- [ ] 수동: Xcode에서 iCloud(CloudKit)·Push Notifications capability 추가 확인 (팀 QGAQ3AY3R3 — entitlements는 이미 반영됨, Xcode가 포털에 컨테이너 등록하는지 확인 필요)
- [ ] 수동: 출시 전 CloudKit Console에서 스키마 Development → Production 배포
- [ ] 실기기 2대(서로 다른 Apple ID)로 초대→수락→양방향 동기화 테스트

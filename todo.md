# CalendarSnap TODO

## 애플 캘린더 중복 등록
- [x] 중복 판정 강화 (EventDuplicate): 같은 날 같은 제목(공백·기호 무시) 또는 같은 시각에 비슷한 제목이면 중복
- [x] 캘린더에 이미 쌓인 중복 사본은 먼저 만든 것 하나만 남기고 정리 (반복 일정 제외)
- [x] 앱 내 저장·스캔 병합·파일 가져오기도 같은 규칙 적용
- [ ] 실기기: 같은 달력 사진 두 번 스캔해서 캘린더에 중복이 안 생기는지 확인

## 달력 탭
- [x] 기본 주간 접힘 + 오늘 일정 큼지막하게 (오늘/내일/어제 라벨, 큰 제목·시각, 빈 날 안내)

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
- [ ] 수동(필수, 공유 실패 1순위 원인): CloudKit Console에서 Event·Child 스키마 Development → Production 배포
- [x] 초대 링크를 눌러도 데이터가 안 들어오는 문제 수정
      - CKShare.publicPermission을 .none → .readWrite (링크만 받은 사람도 수락 가능)
      - 기존에 .none으로 만들어진 공유는 재사용 시 자동 승격
      - accept()의 조용한 early return 제거 → 실패/거절 사유를 항상 안내
      - 수락 직후 공유 존 노출 지연 대비 fetch 재시도(최대 4회)
      - AppDelegate에도 userDidAcceptCloudKitShareWith 안전망 추가
- [x] 아내 기기 공유 실패 원인 분석 후 코드 수정
      - 공유 시작 시 지문 무시하고 전체 강제 업로드 (개발→운영 빌드 전환 시 서버가 비어도 안 올라가던 문제)
      - 업로드 실패(스키마 미배포 등)를 조용히 넘기지 않고 안내
      - 공유 중지 시 역할 초기화, 아무도 수락 안 한 내 공유는 초대 수락 시 자동으로 접고 참여
      - 공유 생성 실패 시 소유자 역할 되돌림
      - 카카오톡 링크는 Safari로 열라고 안내, 참여자 상태 caption 폰트 제거
      - 원격 일정 병합에도 새 중복 규칙 적용
- [ ] 이번 수정 + 링크 권한 수정을 새 버전으로 배포 후 두 기기 모두 업데이트
- [ ] 실기기 2대(서로 다른 Apple ID)로 초대→수락→양방향 동기화 테스트
- [ ] 확인 필요: 두 기기가 같은 CloudKit 환경인지 (Xcode 설치=Development / TestFlight=Production은 서로 안 보임)

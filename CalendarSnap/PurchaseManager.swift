//
//  PurchaseManager.swift
//  CalendarSnap (아이일정)
//
//  아이일정 Plus · Pro 를 파는 자리. **상품 로드 · 구매 · 복원 · 거래 리스너는 전부 `LeeoStore` 안에 있다.**
//  여기는 그 값을 SwiftUI 로 옮겨 적고, 앱의 정책(칸 · 지금까지 쓰던 사람)에 통과시킬 뿐이다.
//

import Foundation
import Combine
import StoreKit
import SwiftUI
import WidgetKit
import LeeoKit

@MainActor
@Observable
final class PurchaseManager {

    static let shared = PurchaseManager()

    // MARK: - 상품 ID
    //
    // ⚠️ App Store Connect · Products.storekit 과 글자 하나까지 같아야 한다.
    //    주 · 월 · 연 구독 여섯은 한 구독 그룹에 넣는다(Pro 가 위 단계). 그래야 칸끼리 갈아탈 수 있다.

    private nonisolated static let base = "com.devkoan.CalendarSnap"
    nonisolated static let plusWeeklyID = base + ".plus.weekly"
    nonisolated static let plusMonthlyID = base + ".plus.monthly"
    nonisolated static let plusYearlyID = base + ".plus.yearly"
    nonisolated static let plusLifetimeID = base + ".plus"
    nonisolated static let proWeeklyID = base + ".pro.weekly"
    nonisolated static let proMonthlyID = base + ".pro.monthly"
    nonisolated static let proYearlyID = base + ".pro.yearly"
    nonisolated static let proLifetimeID = base + ".pro"
    /// Plus 평생을 산 사람이 Pro 평생으로 올리는 값.
    nonisolated static let upgradeID = base + ".pro.upgrade"
    /// 구독 중인 사람의 졸업가 Pro 평생 (→ LeeoGraduation).
    nonisolated static let graduateID = base + ".pro.graduate"

    /// 상품마다 여는 칸. 팁은 여기 없다 — 팁은 아무것도 열지 않는다.
    nonisolated static let tierByProduct: [String: PlanTier] = [
        plusWeeklyID: .plus, plusMonthlyID: .plus, plusYearlyID: .plus, plusLifetimeID: .plus,
        proWeeklyID: .pro, proMonthlyID: .pro, proYearlyID: .pro, proLifetimeID: .pro,
        upgradeID: .pro, graduateID: .pro,
    ]

    /// 페이월이 불러올 상품 (이 순서로).
    nonisolated static let productIDs = [
        plusYearlyID, plusLifetimeID, plusMonthlyID, plusWeeklyID,
        proYearlyID, proLifetimeID, proMonthlyID, proWeeklyID,
        upgradeID, graduateID,
    ]

    nonisolated static let lifetimeIDs: Set<String> = [plusLifetimeID, proLifetimeID, upgradeID, graduateID]
    nonisolated static let subscriptionIDs: Set<String> = [plusWeeklyID, plusMonthlyID, plusYearlyID,
                                               proWeeklyID, proMonthlyID, proYearlyID]

    /// **결제를 들이기 직전 마지막 빌드 번호.** 이 빌드 이하로 처음 받은 사람은 지금까지처럼 Pro 다.
    /// (1.0.7 빌드 6 까지는 모든 기능이 무료였다. 두 아이 · 함께 보기 · 위젯이 갑자기 꺼지지 않게.)
    nonisolated static let lastFreeBuild = 6

    nonisolated static func tier(owning productIDs: Set<String>) -> PlanTier {
        productIDs.compactMap { tierByProduct[$0] }.max() ?? .free
    }

    // MARK: - 상태

    @ObservationIgnored let store: LeeoStore

    /// 지금 쓰는 칸. 화면은 이 값(과 `allows`)만 본다.
    private(set) var tier: PlanTier = Plan.cachedTier ?? .free
    /// 애플에게 물어 답을 받았는가. false 면 화면은 '무료'라고 단정하지 않는다.
    private(set) var isKnown = Plan.cachedTier != nil
    /// 결제 전부터 쓰던 사람이라 Pro 인가.
    private(set) var isEarlyUser = false
    /// 팔기 시작했는가. 아니면 아무것도 막지 않는다 (→ Plan.isSelling).
    private(set) var isSelling = Plan.isSelling
    private(set) var products: [Product] = []
    private(set) var ownedProductIDs: Set<String> = []
    /// 지금 살아 있는 구독. 있으면 설정에 '평생으로 바꾸기' 가 선다.
    private(set) var subscription: LeeoGraduation.Subscription?
    private(set) var isWorking = false
    private(set) var failureMessage: String?

    /// 이번 실행에서 영수증을 실제로 읽었는가. 서기 전에는 캐시에 쓰지 않는다
    /// (상품을 불러오는 중 온 변경 알림에 빈 권한을 적으면 처음 켠 구매자가 '무료'로 못박힌다).
    @ObservationIgnored private var entitlementsChecked = false
    @ObservationIgnored private var observation: AnyCancellable?

    private init() {
        guard let config = CalendarSnapSpec.paywall else {
            preconditionFailure("계약에 페이월이 없다. CalendarSnapSpec.monetization 을 확인할 것")
        }
        store = LeeoStore(config: config, grandfather: { await PurchaseManager.installedBeforePaywall() })
        // objectWillChange 는 값이 바뀌기 직전에 온다. 다음 차례로 미뤄서 읽는다.
        observation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.pull() }
        }
    }

    /// 이 기능을 써도 되는가.
    func allows(_ feature: PlanFeature) -> Bool { !isSelling || tier >= feature.tier }

    func ownsLifetime(_ tier: PlanTier) -> Bool {
        ownedProductIDs.contains { Self.lifetimeIDs.contains($0) && Self.tierByProduct[$0] == tier }
    }

    func product(_ id: String) -> Product? { products.first { $0.id == id } }

    /// 구독 졸업을 제안할 때인가. 6개월째와 갱신 7일 전에 한 번씩. 띄운 쪽이 `markGraduationOffered()`.
    var graduationIsDue: Bool {
        guard let subscription, product(Self.graduateID) != nil, !ownsLifetime(.pro) else { return false }
        return LeeoGraduation.isDue(subscription, lastOffered: LeeoGraduation.lastOffered())
    }

    func markGraduationOffered() { LeeoGraduation.markOffered() }

    // MARK: - 맞추기 · 사기 · 되찾기

    /// 영수증을 다시 읽어 칸을 정한다. 앱이 켜질 때와 활성화될 때마다 부른다.
    func refresh() async {
        await store.refreshEntitlements()
        await store.loadProducts()
        entitlementsChecked = true
        subscription = await LeeoGraduation.currentSubscription(among: Self.subscriptionIDs)
        pull()
    }

    func loadProducts() async {
        await store.loadProducts()
        pull()
    }

    /// ⚠️ `action` 은 화면의 `@Environment(\.purchase)` 다. 아이패드에서 결제 시트가 엉뚱한 창에 뜨지 않게.
    func purchase(_ product: Product, using action: PurchaseAction) async {
        _ = await store.purchase(product) { try await action($0) }
        entitlementsChecked = true
        subscription = await LeeoGraduation.currentSubscription(among: Self.subscriptionIDs)
        pull()
    }

    func restore() async {
        await store.restore()
        entitlementsChecked = true
        pull()
        if tier == .free, failureMessage == nil {
            failureMessage = String(localized: "이 Apple 계정에서 구매한 기록을 찾지 못했어요.")
        }
    }

    private func pull() {
        let before = tier
        if entitlementsChecked {
            let owned = Self.tier(owning: store.purchasedProductIDs)
            Plan.setTier(store.isGrandfathered ? .pro : owned)
        }
        #if DEBUG
        // 스토어 스크린샷은 모든 기능이 보이는 화면이다.
        if ScreenshotDemo.isOn { Plan.setTier(.pro) }
        #endif
        tier = Plan.cachedTier ?? .free
        isKnown = entitlementsChecked || Plan.cachedTier != nil
        isEarlyUser = store.isGrandfathered
        products = store.products
        ownedProductIDs = store.purchasedProductIDs
        isWorking = store.purchasingProductID != nil || store.isRestoring
        failureMessage = store.lastError
        let wasSelling = isSelling
        if !isSelling, products.contains(where: { Self.tierByProduct[$0.id] != nil }) {
            Plan.markSelling()
            isSelling = true
        }
        // 위젯은 App Group 의 그 두 줄만 읽는다. 바뀐 판에만 다시 그린다.
        if before != tier || wasSelling != isSelling { WidgetCenter.shared.reloadAllTimelines() }
    }

    // MARK: - 지금까지 쓰던 사람

    /// App Store 에서 처음 받은 빌드가 결제 도입 전이면 Pro.
    ///
    /// `originalAppVersion` 은 iOS 에서 처음 받은 빌드 번호(CFBundleVersion)다.
    /// ⚠️ 출시 환경에서만 믿는다. 샌드박스 · TestFlight · Xcode 는 늘 "1.0"/"1" 을 돌려줘서,
    ///    그대로 믿으면 심사와 시험에서 모두가 Pro 로 열려 페이월을 볼 수 없다.
    nonisolated static func installedBeforePaywall() async -> Bool {
        guard case .verified(let app) = try? await AppTransaction.shared,
              app.environment == .production else { return false }
        return isFreeEraBuild(app.originalAppVersion)
    }

    nonisolated static func isFreeEraBuild(_ originalAppVersion: String) -> Bool {
        guard let build = Int(originalAppVersion.split(separator: ".").first ?? "") else { return false }
        return build <= lastFreeBuild
    }
}

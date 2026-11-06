//
//  PaywallView.swift
//  CalendarSnap (아이일정)
//
//  아이일정의 세 칸(무료 · Plus · Pro)을 파는 한 장.
//  **무료인 것을 먼저 말한다** → Plus → Pro (칸마다 연 구독 · 평생, 주 · 월은 펼쳐서) → 비교표 → 약관.
//  사는 사람도 안 사는 사람도 이 화면을 닫고 나서 알림장을 계속 찍는다.
//
//  첫 해 할인(App Store 첫 구독 할인)과 "연 구독 N년치" 한 줄은 `LeeoTermPicker` 가 알아서 보인다.
//  App Store 에 아직 없는 상품은 불러오지 못하므로 그 단추는 서지 않는다.
//

import SwiftUI
import StoreKit
import LeeoKit

struct PaywallView: View {
    /// 어디서 들어왔는가. 그 기능이 든 칸을 강조한다.
    var highlight: PlanFeature?
    /// 들어온 순간을 짚는 한 줄 (예: 두 달째 일정을 넣었을 때).
    var headline: String?

    @State private var purchases = PurchaseManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// 결제 시트를 **이 페이월이 떠 있는 창**에 띄운다.
    @Environment(\.purchase) private var purchaseAction

    @State private var terms: [PlanTier: LeeoPlanTerm] = [:]
    /// 펼쳐서 고른 주 · 월 구독. 고르면 연 / 평생보다 먼저다.
    @State private var shortPlans: [PlanTier: String] = [:]
    @State private var loadingProducts = true
    @State private var redeemingCode = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    freeCard
                    plansStatus
                    tierCard(.plus)
                    tierCard(.pro)
                    comparisonTable
                    if let message = purchases.failureMessage, !purchases.products.isEmpty {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.body)
                            .foregroundStyle(.orange)
                    }
                    legal
                }
                .padding(20)
            }
            .navigationTitle("요금제")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("나중에") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("복원") {
                        Task {
                            await purchases.restore()
                            if purchases.tier > .free { dismiss() }
                        }
                    }
                    .disabled(purchases.isWorking)
                }
            }
            .offerCodeRedemption(isPresented: $redeemingCode) { _ in
                Task {
                    await purchases.refresh()
                    if purchases.tier > .free { dismiss() }
                }
            }
            .task {
                LeeoAnalyticsCenter.track(.paywallShown(reason: highlight?.rawValue ?? (headline == nil ? "settings" : "secondMonth")))
                await loadPlans()
            }
        }
    }

    // MARK: 머리

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let headline {
                Label(headline, systemImage: "calendar.badge.checkmark")
                    .font(.headline)
                    .foregroundStyle(.tint)
            }
            Text("아이일정 Plus · Pro")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("아이가 늘어도, 가족이 함께 봐도. 연 구독이나 평생 중에 고르세요.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 무료 칸 (먼저 말한다. 단추는 없다)

    private var freeCard: some View {
        card(highlighted: false) {
            cardTitle(.free)
            row("camera.viewfinder", String(localized: "사진으로 한 달 일정 넣기"), String(localized: "알림장 사진 한 장이면 돼요. 횟수 제한 없어요."))
            row("calendar.badge.plus", String(localized: "애플 캘린더에 한 번에 등록"), String(localized: "이미 있는 일정은 빼고 넣어요."))
            row("moon.stars", String(localized: "전날 저녁 · 당일 아침 알림"), String(localized: "준비물을 잊지 않게 미리 알려 줘요."))
        }
    }

    // MARK: 유료 칸

    private func tierCard(_ tier: PlanTier) -> some View {
        card(highlighted: highlight?.tier == tier && purchases.tier < tier) {
            cardTitle(tier)
            if tier == .pro {
                row("square.stack.3d.up", String(localized: "Plus 전부"), String(localized: "아이 여러 명, 사진 프로필, 1시간 전 · 정각 알림까지."))
            }
            ForEach(PlanFeature.opened(by: tier)) { feature in
                row(feature.systemImage, feature.title, feature.note, highlighted: feature == highlight)
            }
            // 이미 이 칸 이상이면 살 것이 없다. 구독을 평생으로 바꾸는 길은 설정에 있다.
            if purchases.tier < tier, yearly(tier) != nil || lifetime(tier) != nil {
                LeeoTermPicker(term: termBinding(tier), yearly: yearly(tier), lifetime: lifetime(tier))
                    .padding(.top, 4)
                shortPlanPicker(tier)
                buyButton(tier)
            }
        }
    }

    private func yearly(_ tier: PlanTier) -> Product? {
        purchases.product(tier == .plus ? PurchaseManager.plusYearlyID : PurchaseManager.proYearlyID)
    }

    /// 칸의 평생. **Plus 평생을 이미 산 사람에게는 Pro 평생 자리에 올리기 상품을 세운다.**
    private func lifetime(_ tier: PlanTier) -> Product? {
        if tier == .plus { return purchases.product(PurchaseManager.plusLifetimeID) }
        return purchases.product(upgradesToPro ? PurchaseManager.upgradeID : PurchaseManager.proLifetimeID)
    }

    private var upgradesToPro: Bool { purchases.ownsLifetime(.plus) }

    /// 고른 길. 고른 쪽 상품이 없으면(App Store 에 아직 없음) 있는 쪽으로 옮긴다.
    private func term(_ tier: PlanTier) -> LeeoPlanTerm {
        switch terms[tier] ?? .yearly {
        case .yearly: yearly(tier) == nil && lifetime(tier) != nil ? .lifetime : .yearly
        case .lifetime: lifetime(tier) == nil && yearly(tier) != nil ? .yearly : .lifetime
        }
    }

    private func termBinding(_ tier: PlanTier) -> Binding<LeeoPlanTerm> {
        Binding(get: { shortPlans[tier] == nil ? term(tier) : .yearly },
                set: { terms[tier] = $0; shortPlans[tier] = nil })
    }

    private func selectedProduct(_ tier: PlanTier) -> Product? {
        if let id = shortPlans[tier], let product = purchases.product(id) { return product }
        return term(tier) == .yearly ? yearly(tier) : lifetime(tier)
    }

    /// 주 · 월 구독. 연 구독이 기본이라 펼쳐야 보인다. 상품이 없으면 줄이 서지 않는다.
    @ViewBuilder
    private func shortPlanPicker(_ tier: PlanTier) -> some View {
        let weekly = purchases.product(tier == .plus ? PurchaseManager.plusWeeklyID : PurchaseManager.proWeeklyID)
        let monthly = purchases.product(tier == .plus ? PurchaseManager.plusMonthlyID : PurchaseManager.proMonthlyID)
        if weekly != nil || monthly != nil {
            DisclosureGroup("주 · 월 구독") {
                VStack(spacing: 4) {
                    if let monthly { shortPlanRow(tier, monthly, title: String(localized: "매달 \(monthly.displayPrice)")) }
                    if let weekly { shortPlanRow(tier, weekly, title: String(localized: "매주 \(weekly.displayPrice)")) }
                }
                .padding(.top, 6)
            }
            .font(.body)
        }
    }

    private func shortPlanRow(_ tier: PlanTier, _ product: Product, title: String) -> some View {
        let selected = shortPlans[tier] == product.id
        return Button {
            shortPlans[tier] = selected ? nil : product.id
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func buyButton(_ tier: PlanTier) -> some View {
        let product = selectedProduct(tier)
        let title: String = if product?.subscription != nil {
            String(localized: "구독 시작")
        } else if tier == .pro && upgradesToPro {
            String(localized: "Pro 평생으로 올리기")
        } else {
            String(localized: "평생으로 사기")
        }
        return Button {
            guard let product else { return }
            Task {
                await purchases.purchase(product, using: purchaseAction)
                if purchases.tier >= tier { dismiss() }
            }
        } label: {
            Group {
                if purchases.isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text(title).font(.body.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(purchases.isWorking || product == nil)
    }

    // MARK: 요금제를 못 불러왔을 때

    @ViewBuilder
    private var plansStatus: some View {
        if purchases.products.isEmpty && loadingProducts {
            HStack(spacing: 10) {
                ProgressView()
                Text("값을 불러오는 중…")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        } else if purchases.products.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("요금제를 불러오지 못했어요. 인터넷 연결을 확인하고 다시 불러와 주세요.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await loadPlans() }
                } label: {
                    Label("다시 불러오기", systemImage: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// 첫 조회가 비어 오면 한 번 더 청한다. 샌드박스(심사 환경)는 첫 조회가 빈손인 일이 잦다.
    private func loadPlans() async {
        loadingProducts = true
        await purchases.loadProducts()
        if purchases.products.isEmpty {
            try? await Task.sleep(for: .seconds(1.5))
            await purchases.loadProducts()
        }
        loadingProducts = false
    }

    // MARK: 비교표

    private enum Cell { case yes, no, text(String) }

    private var compareRows: [(title: String, free: Cell, plus: Cell, pro: Cell)] {
        let unlimited = Cell.text(String(localized: "무제한"))
        let many = Cell.text(String(localized: "여러 명"))
        return [
            (String(localized: "사진으로 일정 추출"), unlimited, unlimited, unlimited),
            (String(localized: "애플 캘린더 일괄 등록"), .yes, .yes, .yes),
            (String(localized: "알림: 전날 저녁 · 당일 아침"), .yes, .yes, .yes),
            (String(localized: "그날 일정 텍스트 공유"), .yes, .yes, .yes),
            (String(localized: "아이 수"), .text(String(localized: "1명")), many, many),
            (String(localized: "아이 사진 프로필"), .no, .yes, .yes),
            (String(localized: "알림: 1시간 전 · 정각"), .no, .yes, .yes),
            (String(localized: "초대해서 함께 보기"), .no, .no, .yes),
            (String(localized: "홈 화면 위젯"), .no, .no, .yes),
        ]
    }

    private var comparisonTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("한눈에 비교")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(14)
            Divider()
            ForEach(Array(compareRows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    // 칸 이름을 값 위에 함께 적는다. 큰 글자 · 긴 번역에서도 세 열이 잘리지 않게.
                    HStack(spacing: 8) {
                        compareValue(.free, row.free)
                        compareValue(.plus, row.plus)
                        compareValue(.pro, row.pro)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                Divider()
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func compareValue(_ tier: PlanTier, _ cell: Cell) -> some View {
        VStack(spacing: 2) {
            Group {
                switch tier {
                case .free: Text("무료")
                case .plus: Text(verbatim: "Plus")
                case .pro:  Text(verbatim: "Pro")
                }
            }
            .font(.body)
            .foregroundStyle(.secondary)
            switch cell {
            case .yes:
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("있음"))
            case .no:
                Text(verbatim: "–")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("없음"))
            case .text(let value):
                Text(value)
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 약관 (구독을 파는 앱의 심사 필수 항목)

    private var legal: some View {
        VStack(alignment: .leading, spacing: 10) {
            if purchases.products.contains(where: { $0.subscription != nil }) {
                Text("구독은 기간이 끝나기 24시간 전까지 해지하지 않으면 같은 요금으로 자동 갱신되며, Apple 계정으로 결제됩니다. 처음 연 구독을 시작하면 첫 해는 할인된 값일 수 있고, 그 뒤에는 정가로 갱신됩니다. 해지와 관리는 App Store 계정 설정에서 합니다. 평생은 구독이 아니라 한 번 결제입니다.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                if let terms = CalendarSnapSpec.monetization.subscriptionTermsURL {
                    Button("이용약관") { openURL(terms) }
                }
                Button("개인정보 처리방침") { openURL(CalendarSnapSpec.legal.privacyURL) }
            }
            .font(.body)
            Button {
                redeemingCode = true
            } label: {
                Label("코드 사용", systemImage: "ticket")
            }
            .font(.body)
            .disabled(purchases.isWorking)
        }
    }

    // MARK: 부속

    private func card<Content: View>(highlighted: Bool, @ViewBuilder content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(Color(.secondarySystemBackground))
                shape.strokeBorder(highlighted ? Color.accentColor : Color.clear, lineWidth: 2)
            }
    }

    private func cardTitle(_ tier: PlanTier) -> some View {
        HStack(spacing: 8) {
            Text(tier.title)
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            if purchases.isKnown && purchases.tier == tier {
                Text("지금 쓰는 칸")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ icon: String, _ title: String, _ note: String, highlighted: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(highlighted ? Color.accentColor : .secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(note).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .padding(.vertical, highlighted ? 8 : 0)
        .padding(.horizontal, highlighted ? 10 : 0)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.08))
            }
        }
    }
}

// MARK: - 기능의 얼굴

extension PlanFeature {
    var title: String {
        switch self {
        case .moreChildren:   String(localized: "아이 여러 명")
        case .childPhoto:     String(localized: "아이 사진 프로필")
        case .extraReminders: String(localized: "1시간 전 · 정각 알림")
        case .familySharing:  String(localized: "초대해서 함께 보기")
        case .widget:         String(localized: "홈 화면 위젯")
        }
    }

    var note: String {
        switch self {
        case .moreChildren:   String(localized: "아이마다 달력과 반을 따로 둬요.")
        case .childPhoto:     String(localized: "동그라미에 아이 얼굴을 넣어 한눈에 알아봐요.")
        case .extraReminders: String(localized: "등원 직전에 한 번 더 울려 줘요.")
        case .familySharing:  String(localized: "배우자 · 조부모 · 돌봄 선생님과 같은 일정을 실시간으로 봐요. 초대받은 사람은 무료예요.")
        case .widget:         String(localized: "다가오는 일정을 앱을 열지 않고 봐요.")
        }
    }

    var systemImage: String {
        switch self {
        case .moreChildren:   "person.2.fill"
        case .childPhoto:     "person.crop.circle"
        case .extraReminders: "clock"
        case .familySharing:  "person.crop.circle.badge.plus"
        case .widget:         "rectangle.3.group"
        }
    }
}

/// 잠긴 줄 오른쪽의 작은 자물쇠. 눌러 보기 전에 잠긴 걸 알 수 있게.
struct PlanLockBadge: View {
    let feature: PlanFeature

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.body)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("잠김, \(feature.tier.title) 필요"))
    }
}

/// 페이월을 어떤 이유로 띄우는가. 시트 하나로 여러 자리에서 쓴다.
struct PaywallRequest: Identifiable {
    var highlight: PlanFeature?
    var headline: String?
    var id: String { (highlight?.rawValue ?? "") + (headline ?? "") }
}

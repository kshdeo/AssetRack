import SwiftUI

// MARK: - Onboarding container

/// First-launch onboarding flow. Four screens, swipe or tap-through. The
/// `isCompleted` binding is an `@AppStorage` flag that — once true — keeps the
/// onboarding hidden on every subsequent launch.
struct OnboardingView: View {
    @Binding var isCompleted: Bool
    @State private var currentPage = 0

    private let pages: [OnboardingPage.Content] = [
        .init(
            hero: .symbol("chart.pie.fill", gradient: [.blue, .purple]),
            title: "AssetRack",
            subtitle: "Your net worth, quietly tracked.",
            features: []
        ),
        .init(
            hero: .symbol("square.stack.3d.up.fill", gradient: [.teal, .indigo]),
            title: "Track everything that matters",
            subtitle: "From checking to crypto, property to pensions — every account in one place.",
            features: [
                ("banknote.fill",                  .teal,   "Cash & savings"),
                ("chart.line.uptrend.xyaxis",      .blue,   "Stocks & ETFs"),
                ("briefcase.fill",                 .purple, "Pension"),
                ("house.fill",                     .indigo, "Property"),
                ("creditcard.fill",                .red,    "Mortgages & loans"),
            ]
        ),
        .init(
            hero: .symbol("bolt.fill", gradient: [.purple, .blue]),
            title: "Live, multi-currency, forward-looking",
            subtitle: "Prices update automatically and your portfolio is converted to your base currency. See where your net worth is heading.",
            features: [
                ("chart.bar.fill",            .blue,   "Live market prices"),
                ("dollarsign.arrow.circlepath", .teal, "Multi-currency"),
                ("chart.line.uptrend.xyaxis", .purple, "Net worth projection"),
            ]
        ),
        .init(
            hero: .symbol("lock.shield.fill", gradient: [.indigo, .teal]),
            title: "Yours, privately",
            subtitle: "Everything stays on your device and syncs through your iCloud. No accounts, no analytics, no ads.",
            features: []
        ),
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $currentPage) {
                ForEach(pages.indices, id: \.self) { i in
                    OnboardingPage(content: pages[i])
                        .tag(i)
                }
            }
            // Hide the system page dots — we render a custom indicator above
            // the primary button so the layout stays predictable.
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 18) {
                pageIndicator
                Button(action: advance) {
                    Text(isLastPage ? "Start tracking" : "Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 40)
        }
        .overlay(alignment: .topTrailing) {
            if !isLastPage {
                Button("Skip") {
                    complete()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .padding(.trailing, 20)
            }
        }
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.25), value: currentPage)
    }

    private var isLastPage: Bool { currentPage == pages.count - 1 }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(pages.indices, id: \.self) { i in
                Capsule()
                    .fill(i == currentPage ? Color.primary : Color.secondary.opacity(0.25))
                    .frame(width: i == currentPage ? 22 : 8, height: 8)
                    .animation(.spring(duration: 0.3), value: currentPage)
            }
        }
    }

    private func advance() {
        if isLastPage {
            complete()
        } else {
            withAnimation { currentPage += 1 }
        }
    }

    private func complete() {
        withAnimation { isCompleted = true }
    }
}

// MARK: - Single page

struct OnboardingPage: View {

    struct Feature: Identifiable {
        let id = UUID()
        let symbol: String
        let colour: Color
        let label: String
    }

    enum Hero {
        case symbol(String, gradient: [Color])
    }

    struct Content {
        let hero: Hero
        let title: String
        let subtitle: String
        /// (symbol, colour, label) tuples.
        let features: [(String, Color, String)]

        var resolvedFeatures: [Feature] {
            features.map { Feature(symbol: $0.0, colour: $0.1, label: $0.2) }
        }
    }

    let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 32)

            heroView
                .padding(.bottom, 36)

            VStack(spacing: 14) {
                Text(content.title)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text(content.subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }

            if !content.resolvedFeatures.isEmpty {
                featureList
                    .padding(.top, 28)
            }

            Spacer(minLength: 32)
            Spacer().frame(height: 120)   // clear space for the action chrome
        }
    }

    @ViewBuilder
    private var heroView: some View {
        switch content.hero {
        case let .symbol(name, gradient):
            Image(systemName: name)
                .font(.system(size: 78, weight: .medium))
                .foregroundStyle(
                    LinearGradient(colors: gradient,
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
                .frame(width: 140, height: 140)
                .background(
                    Circle().fill(.background)
                        .shadow(color: gradient.first?.opacity(0.18) ?? .clear,
                                radius: 30, x: 0, y: 10)
                )
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(content.resolvedFeatures) { f in
                HStack(spacing: 14) {
                    Image(systemName: f.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(f.colour)
                        .frame(width: 36, height: 36)
                        .background(f.colour.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 9))
                    Text(f.label)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 44)
    }
}

// MARK: - Preview

#Preview("Onboarding") {
    OnboardingView(isCompleted: .constant(false))
}

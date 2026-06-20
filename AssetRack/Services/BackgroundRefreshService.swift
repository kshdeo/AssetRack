import BackgroundTasks
import SwiftData

enum BackgroundRefreshService {
    static let taskID = "com.blackforestapps.assetsRack.widgetRefresh"
    static let minimumInterval: TimeInterval = 3 * 60 * 60 // 3 hours

    static func registerHandler(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            handle(task as! BGAppRefreshTask, container: container)
        }
    }

    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask, container: ModelContainer) {
        scheduleNext()

        let work = Task { @MainActor in
            await run(container: container)
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    @MainActor
    private static func run(container: ModelContainer) async {
        let context = ModelContext(container)
        let currency = CurrencyService()
        let ticker = TickerService()

        await currency.fetchIfNeeded()
        await ticker.fetchIfNeeded(context: context, currency: currency)

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let base = currency.baseCurrency
        let assets = currency.sum(
            accounts.filter { !$0.isLiability }.map { Money($0.currentBalance, $0.currency) },
            in: base
        ).amount
        let liabilities = currency.sum(
            accounts.filter { $0.isLiability }.map { Money($0.currentBalance, $0.currency) },
            in: base
        ).amount
        let netWorth = assets - liabilities

        // Daily change: compare against most recent pre-today net worth snapshot
        let startOfToday = Calendar.current.startOfDay(for: Date())
        var descriptor = FetchDescriptor<NetWorthSnapshot>(
            sortBy: [SortDescriptor(\.recordedAt, order: .reverse)]
        )
        descriptor.predicate = #Predicate { $0.recordedAt < startOfToday }
        descriptor.fetchLimit = 1
        let previousNetWorth = (try? context.fetch(descriptor).first?.netWorth) ?? netWorth

        WidgetDataStore.update(
            netWorth: netWorth,
            dailyChange: netWorth - previousNetWorth,
            currency: base
        )
    }
}

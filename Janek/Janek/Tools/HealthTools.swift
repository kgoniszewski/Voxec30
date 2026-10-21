import HealthKit

/// Dane zdrowotne są czytane wyłącznie lokalnie – do modelu trafia tylko informacja, że odczyt się odbył.
@MainActor
final class HealthProvider {
    static let shared = HealthProvider()
    let store = HKHealthStore()
    private(set) var activeWorkout: HKWorkoutBuilder?
    private(set) var activeWorkoutName: String?

    private let readTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount), HKQuantityType(.heartRate), HKQuantityType(.restingHeartRate),
        HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceWalkingRunning), HKObjectType.workoutType(),
    ]
    private let shareTypes: Set<HKSampleType> = [HKObjectType.workoutType(), HKQuantityType(.activeEnergyBurned)]

    func requireAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw ToolError.unavailable("Zdrowie na tym urządzeniu") }
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    func sum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date = .now) async throws -> Double {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(type: HKQuantityType(identifier), predicate: predicate),
            options: .cumulativeSum
        )
        return try await descriptor.result(for: store)?.sumQuantity()?.doubleValue(for: unit) ?? 0
    }

    func latest(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> (Double, Date)? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(identifier))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        guard let sample = try await descriptor.result(for: store).first else { return nil }
        return (sample.quantity.doubleValue(for: unit), sample.endDate)
    }

    func startWorkout(_ activity: HKWorkoutActivityType, name: String) async throws {
        try await requireAccess()
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity
        configuration.locationType = .unknown
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: .now)
        activeWorkout = builder
        activeWorkoutName = name
    }

    func finishWorkout() async throws -> (name: String, duration: TimeInterval, calories: Double)? {
        guard let builder = activeWorkout, let name = activeWorkoutName else { return nil }
        let end = Date.now
        let start = builder.startDate ?? end
        let calories = (try? await sum(.activeEnergyBurned, unit: .kilocalorie(), from: start, to: end)) ?? 0
        try await builder.endCollection(at: end)
        _ = try await builder.finishWorkout()
        activeWorkout = nil
        activeWorkoutName = nil
        return (name, end.timeIntervalSince(start), calories)
    }
}

struct HealthSummaryTool: AssistantTool {
    let name = "health_read"
    let description = "Odczytuje dane z aplikacji Zdrowie: kroki, puls, spalone kalorie, dystans. Wynik czytany jest użytkownikowi lokalnie – dane zdrowotne nie opuszczają telefonu, więc po wywołaniu nic już nie dodawaj."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "metrics": ["type": "array", "items": ["type": "string", "enum": ["steps", "heart_rate", "resting_heart_rate", "calories", "distance"]],
                        "description": "Które dane odczytać"],
            "period": JSONSchema.enumeration(["today", "yesterday", "week"], "Okres, domyślnie today"),
        ], required: ["metrics"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let provider = HealthProvider.shared
        try await provider.requireAccess()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let (start, end, periodName): (Date, Date, String) = switch input.optionalString("period") {
        case "yesterday": (calendar.date(byAdding: .day, value: -1, to: today)!, today, "Wczoraj")
        case "week": (calendar.date(byAdding: .day, value: -6, to: today)!, .now, "W ostatnim tygodniu")
        default: (today, .now, "Dziś")
        }
        let metrics = input["metrics"]?.arrayValue?.compactMap(\.stringValue) ?? ["steps"]
        var sentences: [String] = []
        for metric in metrics {
            switch metric {
            case "steps":
                let steps = try await provider.sum(.stepCount, unit: .count(), from: start, to: end)
                sentences.append("\(periodName): \(Int(steps).formatted()) kroków")
            case "calories":
                let kcal = try await provider.sum(.activeEnergyBurned, unit: .kilocalorie(), from: start, to: end)
                sentences.append("spalone kalorie aktywne: \(Int(kcal)) kilokalorii")
            case "distance":
                let km = try await provider.sum(.distanceWalkingRunning, unit: .meterUnit(with: .kilo), from: start, to: end)
                sentences.append("dystans: \(String(format: "%.1f", km).replacingOccurrences(of: ".", with: ",")) kilometra")
            case "heart_rate":
                if let reading = try await provider.latest(.heartRate, unit: .count().unitDivided(by: .minute())) {
                    sentences.append("ostatni pomiar pulsu: \(Int(reading.0)) uderzeń na minutę, o \(DateParsing.spoken(reading.1, includeDate: false))")
                } else { sentences.append("brak pomiarów pulsu") }
            case "resting_heart_rate":
                if let reading = try await provider.latest(.restingHeartRate, unit: .count().unitDivided(by: .minute())) {
                    sentences.append("tętno spoczynkowe: \(Int(reading.0))")
                }
            default: break
            }
        }
        let text = sentences.joined(separator: ", ")
        let sentence = text.prefix(1).uppercased() + String(text.dropFirst()) + "."
        return .privateReadout(sentence)
    }
}

struct WorkoutTool: AssistantTool {
    let name = "workout"
    let description = "Rozpoczyna lub kończy trening zapisywany w aplikacji Zdrowie."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "action": JSONSchema.enumeration(["start", "stop", "status"], "Akcja"),
            "activity": JSONSchema.enumeration(["running", "walking", "cycling", "strength", "yoga", "swimming", "hiit", "other"], "Rodzaj treningu (dla start)"),
        ], required: ["action"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let provider = HealthProvider.shared
        switch try input.requiredString("action") {
        case "start":
            if provider.activeWorkout != nil { return .ok("Trening „\(provider.activeWorkoutName ?? "")” już trwa.") }
            let (type, name): (HKWorkoutActivityType, String) = switch input.optionalString("activity") {
            case "running": (.running, "bieg")
            case "walking": (.walking, "spacer")
            case "cycling": (.cycling, "jazda na rowerze")
            case "strength": (.traditionalStrengthTraining, "trening siłowy")
            case "yoga": (.yoga, "joga")
            case "swimming": (.swimming, "pływanie")
            case "hiit": (.highIntensityIntervalTraining, "trening interwałowy")
            default: (.other, "trening")
            }
            try await provider.startWorkout(type, name: name)
            return .ok("Rozpoczęto trening: \(name).")
        case "stop":
            guard let result = try await provider.finishWorkout() else { return .ok("Nie ma aktywnego treningu.") }
            let minutes = Int(result.duration / 60)
            return .privateReadout("Zakończyłem \(result.name). Trwał \(minutes) minut, spalone około \(Int(result.calories)) kilokalorii. Zapisałem go w Zdrowiu.",
                                   summaryForModel: "Trening zakończony i zapisany; podsumowanie przeczytano lokalnie.")
        default:
            guard let builder = provider.activeWorkout else { return .ok("Nie ma aktywnego treningu.") }
            let minutes = Int(Date.now.timeIntervalSince(builder.startDate ?? .now) / 60)
            return .ok("Trwa \(provider.activeWorkoutName ?? "trening") od \(minutes) minut.")
        }
    }
}

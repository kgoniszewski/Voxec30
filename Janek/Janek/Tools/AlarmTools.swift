import ActivityKit
import AlarmKit
import Foundation
import SwiftUI
import UserNotifications

/// Metadane alarmu przekazywane do AlarmKit.
struct JanekAlarmMetadata: AlarmMetadata {
    var kind: String
    var label: String
}

/// Dźwięki alarmów dołączone do aplikacji (Resources/Sounds).
enum AlarmSound: String, CaseIterable, Identifiable, Sendable {
    case classic = "janek_alarm.wav"
    case gentle = "janek_gentle.wav"
    case pills = "janek_pills.wav"
    case system = "default"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .classic: "Klasyczny budzik"
        case .gentle: "Łagodne dzwonki"
        case .pills: "Przypomnienie o lekach"
        case .system: "Dźwięk systemowy"
        }
    }
}

/// Zapis zaplanowanych alarmów (do listowania i odwoływania głosem).
struct ScheduledAlarm: Codable, Identifiable, Sendable {
    var id: UUID
    var kind: String
    var label: String
    var fireDate: Date?
    var dailyAt: String?
    var usesAlarmKit: Bool
}

@MainActor
final class AlarmScheduler {
    static let shared = AlarmScheduler()
    private let storageKey = "janek.scheduledAlarms"

    private(set) var alarms: [ScheduledAlarm] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
            return (try? JSONDecoder().decode([ScheduledAlarm].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: storageKey) }
    }

    var activeAlarms: [ScheduledAlarm] {
        let now = Date.now
        let active = alarms.filter { $0.dailyAt != nil || ($0.fireDate ?? .distantPast) > now }
        if active.count != alarms.count { alarms = active }
        return active
    }

    private func alarmKitAuthorized() async -> Bool {
        switch AlarmManager.shared.authorizationState {
        case .authorized: return true
        case .notDetermined: return (try? await AlarmManager.shared.requestAuthorization()) == .authorized
        default: return false
        }
    }

    /// Planuje alarm: przez AlarmKit (dzwoni mimo trybu cichego i skupienia), a w razie braku zgody
    /// – jako powiadomienie lokalne z własnym dźwiękiem.
    func schedule(kind: String, label: String, at date: Date?, dailyHour: Int?, dailyMinute: Int?, sound: AlarmSound) async throws -> ScheduledAlarm {
        let id = UUID()
        var record = ScheduledAlarm(id: id, kind: kind, label: label, fireDate: date, dailyAt: nil, usesAlarmKit: false)
        if let dailyHour, let dailyMinute { record.dailyAt = String(format: "%02d:%02d", dailyHour, dailyMinute) }

        if await alarmKitAuthorized() {
            let schedule: Alarm.Schedule
            if let dailyHour, let dailyMinute {
                schedule = .relative(.init(time: .init(hour: dailyHour, minute: dailyMinute),
                                           repeats: .weekly([.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday])))
            } else if let date {
                schedule = .fixed(date)
            } else {
                throw ToolError.missingArgument("czas alarmu")
            }
            let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
            let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: label), stopButton: stop)
            let attributes = AlarmAttributes<JanekAlarmMetadata>(
                presentation: AlarmPresentation(alert: alert),
                metadata: JanekAlarmMetadata(kind: kind, label: label),
                tintColor: .indigo
            )
            let alertSound: AlertConfiguration.AlertSound = sound == .system ? .default : .named(sound.rawValue)
            let configuration = AlarmManager.AlarmConfiguration<JanekAlarmMetadata>(
                schedule: schedule, attributes: attributes, sound: alertSound
            )
            _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
            record.usesAlarmKit = true
        } else {
            try await scheduleNotification(id: id, label: label, date: date, dailyHour: dailyHour, dailyMinute: dailyMinute, sound: sound)
        }
        alarms = activeAlarms + [record]
        return record
    }

    private func scheduleNotification(id: UUID, label: String, date: Date?, dailyHour: Int?, dailyMinute: Int?, sound: AlarmSound) async throws {
        let center = UNUserNotificationCenter.current()
        guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else {
            throw ToolError.permissionDenied("Alarmy i powiadomienia")
        }
        let content = UNMutableNotificationContent()
        content.title = "Janek"
        content.body = label
        content.interruptionLevel = .timeSensitive
        content.sound = sound == .system ? .default : UNNotificationSound(named: UNNotificationSoundName(sound.rawValue))
        let trigger: UNNotificationTrigger
        if let dailyHour, let dailyMinute {
            trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: dailyHour, minute: dailyMinute), repeats: true)
        } else if let date {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        } else {
            throw ToolError.missingArgument("czas alarmu")
        }
        try await center.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: trigger))
    }

    func cancel(_ alarm: ScheduledAlarm) {
        if alarm.usesAlarmKit {
            try? AlarmManager.shared.cancel(id: alarm.id)
        } else {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [alarm.id.uuidString])
        }
        alarms = alarms.filter { $0.id != alarm.id }
    }

    func describe(_ alarm: ScheduledAlarm) -> String {
        let when = alarm.dailyAt.map { "codziennie o \($0)" } ?? alarm.fireDate.map { DateParsing.iso($0) } ?? "?"
        return "\(alarm.kind) „\(alarm.label)” – \(when)"
    }
}

struct TimerStartTool: AssistantTool {
    let name = "timer_start"
    let description = "Ustawia minutnik na podany czas (np. „nastaw minutnik na 10 minut”). Dzwoni nawet w trybie cichym."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "seconds": JSONSchema.integer("Czas trwania w sekundach"),
            "label": JSONSchema.string("Etykieta, np. „makaron” (opcjonalnie)"),
        ], required: ["seconds"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        guard let seconds = input["seconds"]?.intValue, seconds > 0 else { throw ToolError.missingArgument("seconds") }
        let label = input.optionalString("label").map { "Minutnik: \($0)" } ?? "Minutnik"
        let alarm = try await AlarmScheduler.shared.schedule(kind: "minutnik", label: label, at: .now.addingTimeInterval(TimeInterval(seconds)),
                                                             dailyHour: nil, dailyMinute: nil, sound: AppSettings.shared.alarmSound)
        return .ok("Minutnik ustawiony, zadzwoni o \(alarm.fireDate.map { DateParsing.spoken($0, includeDate: false) } ?? "?").")
    }
}

struct AlarmSetTool: AssistantTool {
    let name = "alarm_set"
    let description = "Ustawia budzik na konkretną godzinę (jednorazowo albo codziennie)."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "time": JSONSchema.string("Kiedy zadzwonić, ISO 8601 czas lokalny (dla jednorazowego)"),
            "daily_time": JSONSchema.string("Godzina HH:mm dla budzika codziennego"),
            "label": JSONSchema.string("Etykieta (opcjonalnie)"),
        ])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let label = input.optionalString("label") ?? "Budzik"
        if let daily = input.optionalString("daily_time") {
            let parts = daily.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { throw ToolError.missingArgument("daily_time (HH:mm)") }
            _ = try await AlarmScheduler.shared.schedule(kind: "budzik", label: label, at: nil, dailyHour: parts[0], dailyMinute: parts[1], sound: AppSettings.shared.alarmSound)
            return .ok("Budzik codziennie o \(daily).")
        }
        let date = try input.requiredDate("time")
        guard date > .now else { return .error("Ten czas już minął – zapytaj użytkownika o właściwą datę.") }
        _ = try await AlarmScheduler.shared.schedule(kind: "budzik", label: label, at: date, dailyHour: nil, dailyMinute: nil, sound: AppSettings.shared.alarmSound)
        return .ok("Budzik ustawiony na \(DateParsing.iso(date)).")
    }
}

struct MedicationReminderTool: AssistantTool {
    let name = "medication_reminder"
    let description = "Ustawia przypomnienie o lekach jako alarm (codziennie o podanych godzinach albo jednorazowo)."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "medication": JSONSchema.string("Nazwa leku / opis dawki"),
            "daily_times": ["type": "array", "items": ["type": "string"], "description": "Godziny HH:mm, o których codziennie przypominać"],
            "once_at": JSONSchema.string("Jednorazowo: ISO 8601 czas lokalny"),
        ], required: ["medication"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let medication = try input.requiredString("medication")
        let label = "Leki: \(medication)"
        let times = input["daily_times"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if !times.isEmpty {
            for time in times {
                let parts = time.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { continue }
                _ = try await AlarmScheduler.shared.schedule(kind: "leki", label: label, at: nil, dailyHour: parts[0], dailyMinute: parts[1], sound: .pills)
            }
            return .ok("Przypomnienie o lekach (\(medication)) codziennie o \(times.joined(separator: ", ")).")
        }
        let date = try input.requiredDate("once_at")
        _ = try await AlarmScheduler.shared.schedule(kind: "leki", label: label, at: date, dailyHour: nil, dailyMinute: nil, sound: .pills)
        return .ok("Przypomnienie o lekach na \(DateParsing.iso(date)).")
    }
}

struct AlarmListTool: AssistantTool {
    let name = "alarm_list"
    let description = "Zwraca aktywne budziki, minutniki i przypomnienia o lekach ustawione przez Janka."
    var inputSchema: JSONValue { JSONSchema.object([:]) }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let alarms = AlarmScheduler.shared.activeAlarms
        return .ok(alarms.isEmpty ? "Brak aktywnych alarmów." : alarms.map(AlarmScheduler.shared.describe).joined(separator: "\n"))
    }
}

struct AlarmCancelTool: AssistantTool {
    let name = "alarm_cancel"
    let description = "Odwołuje budzik/minutnik/przypomnienie o lekach – wszystkie albo pasujące do etykiety lub rodzaju."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "match": JSONSchema.string("Fragment etykiety albo rodzaj: „minutnik”, „budzik”, „leki”; puste = wszystkie"),
        ])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let needle = TextNormalizer.normalize(input.optionalString("match") ?? "")
        let matches = AlarmScheduler.shared.activeAlarms.filter {
            needle.isEmpty || TextNormalizer.normalize($0.label + " " + $0.kind).contains(needle)
        }
        guard !matches.isEmpty else { return .ok("Nie ma pasujących alarmów.") }
        matches.forEach(AlarmScheduler.shared.cancel)
        return .ok("Odwołano: \(matches.map(AlarmScheduler.shared.describe).joined(separator: "; ")).")
    }
}

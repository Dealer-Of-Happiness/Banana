//
//  KnowledgeBaseService.swift
//  AI goodbye
//
//  Personal knowledge base integrations (Calendar, Health, etc.)
//

import Foundation
import EventKit
import HealthKit

actor KnowledgeBaseService {
    private let eventStore = EKEventStore()
    private let healthStore = HKHealthStore()

    // MARK: - Permission Status

    func permissionStatus(for source: KnowledgeBaseSource) async -> Bool {
        switch source {
        case .calendar:
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders:
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        case .health, .fitness:
            return HKHealthStore.isHealthDataAvailable()
        case .notes:
            return false // Notes doesn't have a public API
        case .email:
            return false // Email requires custom integration
        }
    }

    // MARK: - Request Permission

    func requestPermission(for source: KnowledgeBaseSource) async throws -> Bool {
        switch source {
        case .calendar:
            return try await eventStore.requestFullAccessToEvents()
        case .reminders:
            return try await eventStore.requestFullAccessToReminders()
        case .health, .fitness:
            try await requestHealthPermissions()
            return true
        case .notes, .email:
            throw KnowledgeBaseError.notSupported
        }
    }

    // MARK: - Calendar

    func getUpcomingEvents(days: Int = 7) async throws -> [CalendarEvent] {
        let calendars = eventStore.calendars(for: .event)
        let startDate = Date()
        let endDate = Calendar.current.date(byAdding: .day, value: days, to: startDate)!

        let predicate = eventStore.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: calendars
        )

        let events = eventStore.events(matching: predicate)

        return events.map { event in
            CalendarEvent(
                title: event.title ?? "Untitled",
                startDate: event.startDate,
                endDate: event.endDate,
                location: event.location,
                notes: event.notes
            )
        }
    }

    func searchEvents(query: String) async throws -> [CalendarEvent] {
        let events = try await getUpcomingEvents(days: 30)
        return events.filter { event in
            event.title.localizedCaseInsensitiveContains(query) ||
            (event.notes?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    // MARK: - Reminders

    func getReminders(completed: Bool = false) async throws -> [ReminderItem] {
        return try await withCheckedThrowingContinuation { continuation in
            let predicate = eventStore.predicateForReminders(in: nil)

            eventStore.fetchReminders(matching: predicate) { reminders in
                let items = (reminders ?? [])
                    .filter { $0.isCompleted == completed }
                    .map { reminder in
                        ReminderItem(
                            title: reminder.title ?? "Untitled",
                            notes: reminder.notes,
                            dueDate: reminder.dueDateComponents?.date,
                            isCompleted: reminder.isCompleted,
                            priority: reminder.priority
                        )
                    }
                continuation.resume(returning: items)
            }
        }
    }

    func createReminder(title: String, notes: String? = nil, dueDate: Date? = nil) async throws {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = eventStore.defaultCalendarForNewReminders()

        if let dueDate = dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: dueDate
            )
        }

        try eventStore.save(reminder, commit: true)
    }

    // MARK: - Health Data

    private func requestHealthPermissions() async throws {
        let typesToRead: Set<HKSampleType> = [
            HKQuantityType(.stepCount),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKWorkoutType.workoutType()
        ]

        try await healthStore.requestAuthorization(toShare: [], read: typesToRead)
    }

    func getSteps(for days: Int = 7) async throws -> Int {
        let stepType = HKQuantityType(.stepCount)
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: Date(),
            options: .strictStartDate
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let steps = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: Int(steps))
            }

            healthStore.execute(query)
        }
    }

    func getHeartRate() async throws -> Double {
        let heartRateType = HKQuantityType(.heartRate)

        return try await withCheckedThrowingContinuation { continuation in
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

            let query = HKSampleQuery(
                sampleType: heartRateType,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: 0)
                    return
                }

                let bpm = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                continuation.resume(returning: bpm)
            }

            healthStore.execute(query)
        }
    }

    func getWorkouts(for days: Int = 30) async throws -> [WorkoutSummary] {
        let workoutType = HKWorkoutType.workoutType()
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: Date(),
            options: .strictStartDate
        )

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let workouts = (samples as? [HKWorkout] ?? []).map { workout in
                    WorkoutSummary(
                        type: workout.workoutActivityType.name,
                        duration: workout.duration,
                        calories: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0,
                        date: workout.startDate
                    )
                }

                continuation.resume(returning: workouts)
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Query Interface

    func query(_ text: String) async throws -> String {
        // Parse natural language query and route to appropriate data source
        let lowercased = text.lowercased()

        if lowercased.contains("schedule") || lowercased.contains("calendar") || lowercased.contains("meeting") {
            let events = try await getUpcomingEvents()
            if events.isEmpty {
                return "You have no upcoming events in the next week."
            }
            return formatEvents(events)
        }

        if lowercased.contains("reminder") {
            let reminders = try await getReminders()
            if reminders.isEmpty {
                return "You have no pending reminders."
            }
            return formatReminders(reminders)
        }

        if lowercased.contains("step") || lowercased.contains("walk") {
            let steps = try await getSteps()
            return "You've walked \(steps.formatted()) steps in the past week."
        }

        if lowercased.contains("heart") || lowercased.contains("pulse") {
            let heartRate = try await getHeartRate()
            return "Your latest heart rate reading is \(Int(heartRate)) BPM."
        }

        if lowercased.contains("workout") || lowercased.contains("exercise") {
            let workouts = try await getWorkouts()
            if workouts.isEmpty {
                return "No workouts recorded in the past month."
            }
            return formatWorkouts(workouts)
        }

        return "I couldn't find relevant information for your query."
    }

    // MARK: - Formatting

    private func formatEvents(_ events: [CalendarEvent]) -> String {
        var result = "Here are your upcoming events:\n\n"
        for event in events.prefix(5) {
            result += "• \(event.title)\n"
            result += "  \(event.startDate.formatted(date: .abbreviated, time: .shortened))\n"
            if let location = event.location {
                result += "  Location: \(location)\n"
            }
            result += "\n"
        }
        return result
    }

    private func formatReminders(_ reminders: [ReminderItem]) -> String {
        var result = "Your reminders:\n\n"
        for reminder in reminders.prefix(10) {
            result += "• \(reminder.title)\n"
            if let dueDate = reminder.dueDate {
                result += "  Due: \(dueDate.formatted())\n"
            }
        }
        return result
    }

    private func formatWorkouts(_ workouts: [WorkoutSummary]) -> String {
        var result = "Your recent workouts:\n\n"
        for workout in workouts.prefix(5) {
            result += "• \(workout.type)\n"
            result += "  Duration: \(Int(workout.duration / 60)) minutes\n"
            result += "  Calories: \(Int(workout.calories))\n"
            result += "  Date: \(workout.date.formatted(date: .abbreviated, time: .omitted))\n\n"
        }
        return result
    }
}

// MARK: - Data Models

struct CalendarEvent {
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
}

struct ReminderItem {
    let title: String
    let notes: String?
    let dueDate: Date?
    let isCompleted: Bool
    let priority: Int
}

struct WorkoutSummary {
    let type: String
    let duration: TimeInterval
    let calories: Double
    let date: Date
}

// MARK: - HKWorkoutActivityType Extension

extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .running: return "Running"
        case .walking: return "Walking"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining: return "Strength Training"
        case .hiking: return "Hiking"
        default: return "Workout"
        }
    }
}

// MARK: - Errors

enum KnowledgeBaseError: LocalizedError {
    case notSupported
    case permissionDenied
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "This data source is not supported"
        case .permissionDenied:
            return "Permission denied"
        case .queryFailed(let reason):
            return "Query failed: \(reason)"
        }
    }
}

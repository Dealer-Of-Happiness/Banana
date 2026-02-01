//
//  KnowledgeBaseService.swift
//  AIGoodbye
//
//  Personal knowledge base integrations (Calendar, Reminders)
//

import Foundation
import EventKit

actor KnowledgeBaseService {
    private let eventStore = EKEventStore()

    // MARK: - Permission Status

    func permissionStatus(for source: KnowledgeBaseSource) async -> Bool {
        switch source {
        case .calendar:
            return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders:
            return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        }
    }

    // MARK: - Request Permission

    func requestPermission(for source: KnowledgeBaseSource) async throws -> Bool {
        switch source {
        case .calendar:
            return try await eventStore.requestFullAccessToEvents()
        case .reminders:
            return try await eventStore.requestFullAccessToReminders()
        }
    }

    // MARK: - Calendar

    func getUpcomingEvents(days: Int = 7) async throws -> [CalendarEvent] {
        let calendars = eventStore.calendars(for: .event)
        let startDate = Date()
        guard let endDate = Calendar.current.date(byAdding: .day, value: days, to: startDate) else {
            return []
        }

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

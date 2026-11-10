import EventKit
import Foundation

/// Reads the macOS calendar (all accounts configured in Calendar.app) to name meetings and list attendees.
public final class CalendarService: @unchecked Sendable {
    private let store = EKEventStore()
    public private(set) var authorized = false

    public init() {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    public func requestAccess() async -> Bool {
        if authorized { return true }
        authorized = (try? await store.requestFullAccessToEvents()) ?? false
        return authorized
    }

    /// Calendars visible through EventKit, as "account: calendar" (for diagnostics and the settings screen).
    public func visibleCalendars() -> [String] {
        guard authorized else { return [] }
        return store.calendars(for: .event).map { "\($0.source.title): \($0.title)" }.sorted()
    }

    /// Plain-text report of visible calendars and their events in a date range (diagnostics).
    public func report(from start: Date, to end: Date) -> String {
        guard authorized else { return "Calendar access not granted (status \(EKEventStore.authorizationStatus(for: .event).rawValue))." }
        let calendars = store.calendars(for: .event)
        var out = "Calendars (\(calendars.count)):\n"
        for c in calendars.sorted(by: { ($0.source.title, $0.title) < ($1.source.title, $1.title) }) {
            out += "- \(c.source.title) [\(c.source.sourceType.rawValue)]: \(c.title)\n"
        }
        let f = DateFormatter()
        f.dateFormat = "EEE dd.MM. HH:mm"
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
        out += "\nEvents \(f.string(from: start)) – \(f.string(from: end)) (\(events.count)):\n"
        for e in events {
            let time = e.isAllDay ? "all-day" : "\(f.string(from: e.startDate))–\(DateFormatter.localizedString(from: e.endDate, dateStyle: .none, timeStyle: .short))"
            let people = Self.info(e).attendees
            out += "- \(time) | \(e.title ?? "(no title)") | \(e.calendar.source.title): \(e.calendar.title) | attendees: \(people.isEmpty ? "none" : people.joined(separator: ", "))\n"
        }
        return out
    }

    public struct EventInfo: Sendable, Identifiable, Hashable {
        /// EventKit identifier plus start time (recurring events share one identifier).
        public var id: String
        public var eventID: String
        public var calendar: String
        public var title: String
        public var start: Date
        public var end: Date
        public var attendees: [String]
        public var notes: String?

        public init(
            id: String, eventID: String, calendar: String, title: String, start: Date, end: Date, attendees: [String] = [],
            notes: String? = nil
        ) {
            self.id = id
            self.eventID = eventID
            self.calendar = calendar
            self.title = title
            self.start = start
            self.end = end
            self.attendees = attendees
            self.notes = notes
        }
    }

    /// Timed events (not all-day, not marked free) overlapping the range, by start time.
    public func events(from start: Date, to end: Date) -> [EventInfo] {
        guard authorized else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.availability != .free && $0.endDate > start }
            .sorted { $0.startDate < $1.startDate }
            .map(Self.info)
    }

    /// Events to offer when starting a recording now: running ones and the rest of today.
    public func eventsAroundNow(_ date: Date = Date()) -> [EventInfo] {
        let endOfDay = Calendar.current.startOfDay(for: date).addingTimeInterval(86_400)
        return events(from: date.addingTimeInterval(-15 * 60), to: max(endOfDay, date.addingTimeInterval(3 * 3600)))
    }

    /// The event that best matches a meeting starting now: overlapping now (or starting within 10 minutes),
    /// not all-day, preferring events with attendees and the closest start time.
    public func currentEvent(at date: Date = Date()) -> EventInfo? {
        guard authorized else { return nil }
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-3 * 3600), end: date.addingTimeInterval(15 * 60), calendars: nil)
        let candidates = store.events(matching: predicate).filter { event in
            !event.isAllDay && event.endDate > date.addingTimeInterval(-5 * 60)
                && event.startDate < date.addingTimeInterval(10 * 60)
                && event.availability != .free
        }
        let best = candidates.min { a, b in
            let aScore = abs(a.startDate.timeIntervalSince(date)) - (a.hasAttendees ? 1800 : 0)
            let bScore = abs(b.startDate.timeIntervalSince(date)) - (b.hasAttendees ? 1800 : 0)
            return aScore < bScore
        }
        return best.map(Self.info)
    }

    private static func info(_ event: EKEvent) -> EventInfo {
        let attendees = (event.attendees ?? []).compactMap { p -> String? in
            if let name = p.name, !name.isEmpty { return name }
            return p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }
        let eventID = event.eventIdentifier ?? UUID().uuidString
        return EventInfo(
            id: "\(eventID)@\(Int(event.startDate.timeIntervalSince1970))", eventID: eventID,
            calendar: event.calendar.title, title: event.title ?? "Meeting", start: event.startDate,
            end: event.endDate, attendees: attendees, notes: event.notes)
    }
}

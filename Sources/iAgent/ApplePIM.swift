import Contacts
import EventKit
import Foundation

// Reminders, Calendar, Contacts and Notes sync through iCloud, so changes made here show up on the
// user's iPhone, iPad, Apple Watch and other Macs.

enum DateInput {
    /// Accepts ISO-8601-ish local times ("2026-10-08T09:30", "2026-10-08 09:30", "2026-10-08")
    /// or offsets from now ("+30m", "+2h", "+1d").
    static func parse(_ s: String) throws -> (date: Date, hasTime: Bool) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.lowercased() == "now" { return (Date(), true) }
        // Plain digits only: Double() also takes "nan", "inf" and "1e300", which make dates in 4713 BC or year 506713.
        if t.range(of: #"^\+[0-9]+(\.[0-9]+)?[mhd]$"#, options: .regularExpression) != nil,
           let unit = t.last, let n = Double(t.dropFirst().dropLast()), let mult = ["m": 60.0, "h": 3600, "d": 86400][unit] {
            guard n * mult <= 100 * 365 * 86400 else { throw AgentError("'\(s)' is more than 100 years away.") }
            return (Date().addingTimeInterval(n * mult), true)
        }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: t) { return (d, true) }
        for (format, hasTime) in [("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true), ("yyyy-MM-dd HH:mm:ss", true),
                                  ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false)] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = .current
            df.dateFormat = format
            if let d = df.date(from: t) { return (d, hasTime) }
        }
        throw AgentError("Unrecognized date '\(s)'. Use YYYY-MM-DD, YYYY-MM-DDTHH:MM (local time), or +30m/+2h/+1d.")
    }

    static func format(_ d: Date?, time: Bool = true) -> String {
        guard let d else { return "" }
        return formatter(time ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd").string(from: d)
    }

    /// A fixed-format formatter in local time. en_US_POSIX keeps the user's 12/24-hour setting from rewriting
    /// `HH` into `h a` (Apple Technical Q&A QA1480) and keeps Gregorian years on other calendars.
    static func formatter(_ format: String) -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = format
        return df
    }
}

enum PIM {
    static let store = EKEventStore()

    static func ensureAccess(_ type: EKEntityType) async throws {
        let what = type == .event ? "Calendars" : "Reminders"
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return
        case .denied, .restricted:
            throw AgentError("Access to \(what) is denied. Enable your terminal app in System Settings → Privacy & Security → \(what).")
        default:
            let granted = type == .event ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
            guard granted else { throw AgentError("Access to \(what) was not granted.") }
        }
    }

    static func calendars(_ type: EKEntityType, named name: String?) throws -> [EKCalendar]? {
        guard let name, !name.isEmpty else { return nil }
        let matches = store.calendars(for: type).filter { $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }
        guard !matches.isEmpty else {
            let all = store.calendars(for: type).map(\.title).joined(separator: ", ")
            throw AgentError("No \(type == .event ? "calendar" : "reminder list") named '\(name)'. Available: \(all)")
        }
        return matches
    }

    struct ReminderInfo: Sendable {
        let id, title, list, notes: String
        let due: Date?
        let completed: Bool
        let priority: Int
    }

    static func fetchReminders(in cals: [EKCalendar]?, includeCompleted: Bool) async -> [ReminderInfo] {
        let predicate = includeCompleted
            ? store.predicateForReminders(in: cals)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                let infos = (reminders ?? []).map { r in
                    ReminderInfo(id: r.calendarItemIdentifier, title: r.title ?? "", list: r.calendar?.title ?? "",
                                 notes: r.notes ?? "", due: r.dueDateComponents?.date, completed: r.isCompleted,
                                 priority: r.priority)
                }
                cont.resume(returning: infos)
            }
        }
    }
}

extension AppleTools {
    // MARK: reminders

    static let reminders = Tool(
        name: "reminders",
        description: """
        Apple Reminders (EventKit; syncs via iCloud to iPhone/iPad/Watch). Actions: lists; list (list?, \
        include_completed?, query?); add (title, list?, due?, notes?, priority 0-9?) — a due time also sets an alert, \
        which is a good way to notify the user on their iPhone/Apple Watch; complete (id from `list`, or exact title); \
        delete (id). Dates: YYYY-MM-DD, YYYY-MM-DDTHH:MM (local) or +30m/+2h/+1d.
        """,
        schema: actionSchema(["lists", "list", "add", "complete", "delete"], [
            "list": ["type": "string", "description": "Reminder list name (default list when omitted)"],
            "title": ["type": "string"], "notes": ["type": "string"], "due": ["type": "string"],
            "priority": ["type": "integer", "description": "0 none, 1 high, 5 medium, 9 low"],
            "id": ["type": "string"], "query": ["type": "string"],
            "include_completed": ["type": "boolean"],
        ]),
        approval: { args, _ in ["lists", "list"].contains(action(args)) ? .none : .ask },
        summary: summarize(["title", "id", "list"]),
        run: { args, _ in
            try await PIM.ensureAccess(.reminder)
            let store = PIM.store
            switch action(args) {
            case "lists":
                let def = store.defaultCalendarForNewReminders()?.title
                return store.calendars(for: .reminder).map {
                    "- \($0.title) (\($0.source.title))\($0.title == def ? " [default]" : "")"
                }.joined(separator: "\n")
            case "list":
                var items = await PIM.fetchReminders(in: try PIM.calendars(.reminder, named: args["list"] as? String),
                                                     includeCompleted: bool(args, "include_completed"))
                if let q = args["query"] as? String, !q.isEmpty {
                    items = items.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.notes.localizedCaseInsensitiveContains(q) }
                }
                items.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                if items.isEmpty { return "No reminders." }
                return items.prefix(200).map { r in
                    var line = "- [\(r.completed ? "x" : " ")] \(r.title)"
                    if let due = r.due { line += " (due \(DateInput.format(due)))" }
                    line += " [\(r.list)] id=\(r.id)"
                    if !r.notes.isEmpty { line += "\n    " + r.notes.replacingOccurrences(of: "\n", with: " ").prefix(150) }
                    return line
                }.joined(separator: "\n") + (items.count > 200 ? "\n... \(items.count - 200) more" : "")
            case "add":
                let r = EKReminder(eventStore: store)
                r.title = try str(args, "title")
                r.notes = args["notes"] as? String
                r.priority = min(max(int(args, "priority") ?? 0, 0), 9)
                guard let cal = try PIM.calendars(.reminder, named: args["list"] as? String)?.first ?? store.defaultCalendarForNewReminders() else {
                    throw AgentError("No default reminder list; pass `list`.")
                }
                r.calendar = cal
                if let dueText = args["due"] as? String {
                    let (due, hasTime) = try DateInput.parse(dueText)
                    let comps: Set<Calendar.Component> = hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                    r.dueDateComponents = Calendar.current.dateComponents(comps, from: due)
                    if hasTime { r.addAlarm(EKAlarm(absoluteDate: due)) }
                }
                try store.save(r, commit: true)
                return "Added reminder '\(r.title ?? "")' to \(cal.title)\(r.dueDateComponents?.date.map { ", due \(DateInput.format($0))" } ?? "") id=\(r.calendarItemIdentifier)"
            case "complete", "delete":
                let reminder: EKReminder
                if let id = args["id"] as? String, let r = store.calendarItem(withIdentifier: id) as? EKReminder {
                    reminder = r
                } else if let title = args["title"] as? String, action(args) == "complete" {
                    let open = await PIM.fetchReminders(in: nil, includeCompleted: false).filter { $0.title == title }
                    guard open.count == 1, let r = store.calendarItem(withIdentifier: open[0].id) as? EKReminder else {
                        throw AgentError(open.isEmpty ? "No open reminder titled '\(title)'" : "\(open.count) reminders titled '\(title)'; use id")
                    }
                    reminder = r
                } else {
                    throw AgentError("Reminder not found; pass a valid `id` (from action list)")
                }
                if action(args) == "delete" {
                    try store.remove(reminder, commit: true)
                    return "Deleted reminder '\(reminder.title ?? "")'"
                }
                reminder.isCompleted = true
                try store.save(reminder, commit: true)
                return "Completed '\(reminder.title ?? "")'"
            default:
                throw AgentError("Unknown action '\(action(args))'")
            }
        })

    // MARK: calendar

    static let calendar = Tool(
        name: "calendar",
        description: """
        Apple Calendar (EventKit; iCloud/Google/Exchange calendars configured on this Mac, synced to the user's devices). \
        Actions: calendars; events (start?, end? — default today through 7 days; calendar?; query?); add (title, start, \
        end? default +1h, calendar?, location?, notes?, all_day?, alert_minutes?); delete (id). Dates: YYYY-MM-DD, \
        YYYY-MM-DDTHH:MM (local) or +2h/+1d.
        """,
        schema: actionSchema(["calendars", "events", "add", "delete"], [
            "calendar": ["type": "string"], "title": ["type": "string"], "start": ["type": "string"], "end": ["type": "string"],
            "location": ["type": "string"], "notes": ["type": "string"], "all_day": ["type": "boolean"],
            "alert_minutes": ["type": "integer", "description": "Alert this many minutes before start"],
            "query": ["type": "string"], "id": ["type": "string"],
        ]),
        approval: { args, _ in ["calendars", "events"].contains(action(args)) ? .none : .ask },
        summary: summarize(["title", "start", "id"]),
        run: { args, _ in
            try await PIM.ensureAccess(.event)
            let store = PIM.store
            switch action(args) {
            case "calendars":
                return store.calendars(for: .event).map {
                    "- \($0.title) (\($0.source.title))\($0.allowsContentModifications ? "" : " [read-only]")"
                }.joined(separator: "\n")
            case "events":
                let start = try (args["start"] as? String).map { try DateInput.parse($0).date } ?? Calendar.current.startOfDay(for: Date())
                let end = try (args["end"] as? String).map { s -> Date in
                    let (d, hasTime) = try DateInput.parse(s)
                    return hasTime ? d : Calendar.current.date(byAdding: .day, value: 1, to: d)!   // inclusive end day
                } ?? start.addingTimeInterval(7 * 86400)
                let pred = store.predicateForEvents(withStart: start, end: end,
                                                    calendars: try PIM.calendars(.event, named: args["calendar"] as? String))
                var events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }
                if let q = args["query"] as? String, !q.isEmpty {
                    events = events.filter { ($0.title ?? "").localizedCaseInsensitiveContains(q) || ($0.location ?? "").localizedCaseInsensitiveContains(q) }
                }
                if events.isEmpty { return "No events between \(DateInput.format(start)) and \(DateInput.format(end))." }
                return events.prefix(200).map { e in
                    let when = e.isAllDay ? DateInput.format(e.startDate, time: false) + " (all day)"
                        : "\(DateInput.format(e.startDate))–\(DateInput.format(e.endDate).suffix(5))"
                    var line = "- \(when)  \(e.title ?? "(no title)")"
                    if let loc = e.location, !loc.isEmpty { line += " @ \(loc)" }
                    return line + " [\(e.calendar.title)] id=\(e.eventIdentifier ?? "")"
                }.joined(separator: "\n")
            case "add":
                let e = EKEvent(eventStore: store)
                e.title = try str(args, "title")
                let (start, hasTime) = try DateInput.parse(try str(args, "start"))
                e.startDate = start
                e.isAllDay = bool(args, "all_day") || !hasTime
                e.endDate = try (args["end"] as? String).map { try DateInput.parse($0).date }
                    ?? (e.isAllDay ? start : start.addingTimeInterval(3600))
                e.location = args["location"] as? String
                e.notes = args["notes"] as? String
                if let m = int(args, "alert_minutes") { e.addAlarm(EKAlarm(relativeOffset: -TimeInterval(m) * 60)) }
                guard let cal = try PIM.calendars(.event, named: args["calendar"] as? String)?.first ?? store.defaultCalendarForNewEvents else {
                    throw AgentError("No default calendar; pass `calendar`.")
                }
                e.calendar = cal
                try store.save(e, span: .thisEvent, commit: true)
                return "Added '\(e.title ?? "")' on \(DateInput.format(e.startDate, time: !e.isAllDay)) to \(cal.title) id=\(e.eventIdentifier ?? "")"
            case "delete":
                guard let id = args["id"] as? String, let e = store.event(withIdentifier: id) else {
                    throw AgentError("Event not found; pass a valid `id` (from action events)")
                }
                try store.remove(e, span: .thisEvent, commit: true)
                return "Deleted '\(e.title ?? "")'"
            default:
                throw AgentError("Unknown action '\(action(args))'")
            }
        })

    // MARK: contacts

    static let contacts = Tool(
        name: "contacts",
        description: "Search Apple Contacts (synced via iCloud) by name, email or phone number. Returns names, organizations, phone numbers and emails — use it to find who to message.",
        schema: schema(["query": ["type": "string", "description": "Name, email, or phone number"],
                        "limit": ["type": "integer", "description": "Max results (default 10)"]], required: ["query"]),
        approval: { _, _ in .ask },
        summary: { ($0["query"] as? String) ?? "" },
        run: { args, _ in
            let store = CNContactStore()
            switch CNContactStore.authorizationStatus(for: .contacts) {
            case .denied, .restricted:
                throw AgentError("Access to Contacts is denied. Enable your terminal app in System Settings → Privacy & Security → Contacts.")
            case .notDetermined:
                guard try await store.requestAccess(for: .contacts) else { throw AgentError("Access to Contacts was not granted.") }
            default: break
            }
            let q = try str(args, "query")
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                        CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            let predicate: NSPredicate
            if q.contains("@") {
                predicate = CNContact.predicateForContacts(matchingEmailAddress: q)
            } else if q.range(of: #"^[+\d][\d\s().-]{5,}$"#, options: .regularExpression) != nil {
                predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: q))
            } else {
                predicate = CNContact.predicateForContacts(matchingName: q)
            }
            let found = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            if found.isEmpty { return "No contacts match '\(q)'." }
            return found.prefix(max(int(args, "limit") ?? 10, 1)).map { c in
                var lines = ["- \([c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " "))\(c.organizationName.isEmpty ? "" : " (\(c.organizationName))")"]
                for p in c.phoneNumbers {
                    lines.append("    phone \(p.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) } ?? ""): \(p.value.stringValue)")
                }
                for e in c.emailAddresses { lines.append("    email: \(e.value as String)") }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n")
        })

    // MARK: notes (Notes.app has no public framework; JXA it is)

    static let notes = Tool(
        name: "notes",
        description: "Apple Notes (synced via iCloud to iPhone/iPad). Actions: folders; recent (limit?); search (query; matches title and body); read (id); create (title, body plain text, folder?); append (id, body).",
        schema: actionSchema(["folders", "recent", "search", "read", "create", "append"], [
            "query": ["type": "string"], "id": ["type": "string"], "title": ["type": "string"],
            "body": ["type": "string"], "folder": ["type": "string"], "limit": ["type": "integer"],
        ]),
        approval: { args, _ in action(args) == "folders" ? .none : .ask },
        summary: summarize(["title", "query", "id"]),
        run: { args, _ in
            let limit = String(int(args, "limit") ?? 20)
            switch action(args) {
            case "folders":
                return try await runOSAScript("""
                function run() {
                  const N = Application('Notes');
                  return N.folders().map(f => '- ' + f.name() + ' (' + f.notes.length + ' notes) [' + f.container().name() + ']').join('\\n');
                }
                """, javascript: true)
            case "recent", "search":
                return try await runOSAScript("""
                function run(argv) {
                  const N = Application('Notes'); const q = argv[0], limit = parseInt(argv[1]);
                  const spec = q ? N.notes.whose({_or: [{name: {_contains: q}}, {plaintext: {_contains: q}}]}) : N.notes;
                  const ids = spec.id(), names = spec.name(), dates = spec.modificationDate();
                  const rows = ids.map((id, i) => ({id, name: names[i], date: dates[i]})).sort((a, b) => b.date - a.date).slice(0, limit);
                  if (!rows.length) return 'No notes found.';
                  return rows.map(r => '- ' + r.name + ' (modified ' + r.date.toISOString().slice(0, 16).replace('T', ' ') + ') id=' + r.id).join('\\n');
                }
                """, javascript: true, args: [action(args) == "search" ? try str(args, "query") : "", limit])
            case "read":
                return try await runOSAScript("""
                function run(argv) {
                  const n = Application('Notes').notes.byId(argv[0]);
                  return '# ' + n.name() + '\\n(folder: ' + n.container().name() + ', modified ' + n.modificationDate().toISOString() + ')\\n\\n' + n.plaintext();
                }
                """, javascript: true, args: [try str(args, "id")])
            case "create", "append":
                let html = htmlParagraphs(try str(args, "body"))
                if action(args) == "append" {
                    return try await runOSAScript("""
                    function run(argv) {
                      const n = Application('Notes').notes.byId(argv[0]);
                      n.body = n.body() + argv[1];
                      return 'Appended to "' + n.name() + '"';
                    }
                    """, javascript: true, args: [try str(args, "id"), html])
                }
                let title = try str(args, "title")
                return try await runOSAScript("""
                function run(argv) {
                  const N = Application('Notes');
                  const folder = argv[2] ? N.folders.byName(argv[2]) : N.defaultAccount.defaultFolder;
                  const note = N.Note({body: '<div><h1>' + argv[0] + '</h1></div>' + argv[1]});
                  folder.notes.push(note);
                  return 'Created note "' + argv[3] + '" id=' + note.id();
                }
                """, javascript: true, args: [htmlEscape(title), html, args["folder"] as? String ?? "", title])
            default:
                throw AgentError("Unknown action '\(action(args))'")
            }
        })

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func htmlParagraphs(_ s: String) -> String {
        s.components(separatedBy: "\n").map { $0.isEmpty ? "<div><br></div>" : "<div>\(htmlEscape($0))</div>" }.joined()
    }

    // MARK: messages

    static let messages = Tool(
        name: "messages",
        description: "Send an iMessage (or SMS via the user's iPhone with Text Message Forwarding) from the Messages app. `to` is a phone number or Apple ID email (look it up with `contacts`). Optionally attach a file. The user always confirms each message.",
        schema: schema([
            "to": ["type": "string", "description": "Phone number (+15551234567) or email"],
            "text": ["type": "string"],
            "file": ["type": "string", "description": "Optional path of a file to attach"],
            "service": ["type": "string", "enum": ["imessage", "sms"], "description": "Default imessage"],
        ], required: ["to"]),
        // An attachment follows the read_file rules too: a secret file (or a harmless-looking symlink to one) is blocked.
        approval: { args, ctx in
            let send = Approval.sensitive("sends a message to another person on your behalf")
            return (args["file"] as? String).map { .strictest(send, PathPolicy.readApproval($0, ctx)) } ?? send
        },
        summary: { "to: \(($0["to"] as? String) ?? "?")" },
        preview: { args, ctx in
            var s = Style.yellow("    To: \(args["to"] as? String ?? "?") via \(args["service"] as? String ?? "imessage")")
            if let t = args["text"] as? String { s += "\n" + t.components(separatedBy: "\n").map { Style.yellow("    │ " + $0) }.joined(separator: "\n") }
            if let f = args["file"] as? String {
                // Show where a symlink really points, so `report.pdf` can't hide what is attached.
                let real = Sanitize.terminal(realPath(ctx.resolve(f)).path)
                s += "\n" + Style.yellow("    📎 \(f)" + (real == ctx.resolve(f).path ? "" : " → \(real)"))
            }
            return s
        },
        run: { args, ctx in
            let to = try str(args, "to").trimmingCharacters(in: .whitespaces)
            let isPhone = to.range(of: #"^\+?[0-9][0-9 ()./-]{4,}$"#, options: .regularExpression) != nil
            let isEmail = to.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
            guard isPhone || isEmail else { throw AgentError("`to` must be a phone number or email address") }
            let text = args["text"] as? String ?? ""
            let file = (args["file"] as? String).map { ctx.resolve($0).path } ?? ""
            guard !text.isEmpty || !file.isEmpty else { throw AgentError("Provide text and/or file") }
            if !file.isEmpty, !FileManager.default.fileExists(atPath: file) { throw AgentError("No such file: \(file)") }
            let service = (args["service"] as? String) == "sms" ? "SMS" : "iMessage"
            _ = try await runOSAScript("""
            on run argv
              set recipient to item 1 of argv
              set msg to item 2 of argv
              set attachmentPath to item 3 of argv
              tell application "Messages"
                set svc to 1st account whose service type = \(service)
                set p to participant recipient of svc
                if msg is not "" then send msg to p
                if attachmentPath is not "" then send (POSIX file attachmentPath) to p
              end tell
            end run
            """, args: [to, text, file])
            return "Sent via \(service) to \(to)."
        })
}

import Foundation

/// Derives the Apple Notes title for a meeting's transcript/summary notes.
///
/// Apple Notes has no separate "title" property — it derives a note's visible title from the
/// first line of the HTML body (see `NotesScript.createNote`'s doc comment), so this is the
/// string `NotesMeetingWriter` prepends as an `# <title>` heading before rendering to HTML.
public enum MeetingNoteTitle {

    /// `"<Mon D'th'> - <LLM title>"` when a non-empty LLM-produced title is available, else
    /// `"<Mon D'th'> - <type display name>"`. e.g. `"Jun 18th - Q3 Roadmap Sync"` or, with no
    /// LLM title, `"Jun 18th - 1:1"`.
    public static func title(date: Date, llmTitle: String?, typeDisplayName: String) -> String {
        let trimmed = llmTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = (trimmed?.isEmpty == false) ? trimmed! : typeDisplayName
        return "\(datePrefix(date)) - \(suffix)"
    }

    /// The transcript note's title: the same title, prefixed `"Transcript · "` so it sorts/reads
    /// distinctly from the summary note that shares the same base title.
    public static func transcriptTitle(date: Date, llmTitle: String?, typeDisplayName: String) -> String {
        "Transcript · \(title(date: date, llmTitle: llmTitle, typeDisplayName: typeDisplayName))"
    }

    // MARK: - Date formatting

    /// `en_US_POSIX` + Gregorian, fixed independent of the device's locale/calendar setting, so
    /// note titles are consistently formatted (e.g. not swapped to a different calendar system)
    /// regardless of what the user has configured. Time zone is intentionally left as the
    /// device's current zone — a meeting's date should read as the day it happened locally.
    /// `Calendar` is a value type and safe to share; the `DateFormatter` is created per call
    /// because `DateFormatter` is NOT thread-safe and this is public, unisolated API — the
    /// allocation cost is irrelevant at "a couple of titles per meeting" frequency.
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }()

    /// `"<Mon> <D><suffix>"`, e.g. `"Jun 18th"`.
    private static func datePrefix(_ date: Date) -> String {
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.calendar = Calendar(identifier: .gregorian)
        monthFormatter.dateFormat = "MMM"
        let month = monthFormatter.string(from: date)
        let day = calendar.component(.day, from: date)
        return "\(month) \(day)\(ordinalSuffix(for: day))"
    }

    /// English ordinal suffix for a day-of-month number: 1st, 2nd, 3rd, 4th…11th/12th/13th are
    /// "th" (the 11-13 exception to the usual 1/2/3 pattern), 21st, 22nd, 23rd, 31st, etc.
    static func ordinalSuffix(for day: Int) -> String {
        let mod100 = day % 100
        if (11...13).contains(mod100) { return "th" }
        switch day % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }
}

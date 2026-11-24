import Foundation
import Observation

/// How long a closed quick pad keeps its draft.
enum PadReuse: Int, CaseIterable, Identifiable {
    case alwaysNew = 0, fiveMinutes = 5, tenMinutes = 10, fifteenMinutes = 15, thirtyMinutes = 30, oneHour = 60

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .alwaysNew: "Every opening"
        case .fiveMinutes: "5 minutes"
        case .tenMinutes: "10 minutes"
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        }
    }
}

/// The Files settings: draft formats, automatic saving, how long drafts last, and how new files are named.
/// The workspace shares one instance between the quick pad and every file window.
@MainActor
@Observable
final class PadDraftSettings {
    /// The format of a new draft. Only an enabled format can be the default.
    var format: PadFormat {
        get { defaultFormat }
        set {
            guard enabledFormats.contains(newValue) else { return }
            defaultFormat = newValue
            defaults.set(newValue.rawValue, forKey: Keys.format)
        }
    }
    private var defaultFormat: PadFormat
    private(set) var enabledFormats: [PadFormat]
    var saveAutomatically: Bool {
        didSet { defaults.set(saveAutomatically, forKey: Keys.saveAutomatically) }
    }
    var reusePeriod: PadReuse {
        didSet { defaults.set(reusePeriod.rawValue, forKey: Keys.reusePeriod) }
    }
    /// Copies a new file's path after its first save. Copy Path always copies.
    var copiesPathAfterSaving: Bool {
        didSet { defaults.set(copiesPathAfterSaving, forKey: Keys.copyPathAfterSaving) }
    }
    /// Starts the filename number at 1 on each new day; otherwise it never resets.
    var resetsNumberDaily: Bool {
        didSet { defaults.set(resetsNumberDaily, forKey: Keys.resetNumberDaily) }
    }
    var nameParts: [PadNamePart] {
        didSet {
            if let data = try? JSONEncoder().encode(nameParts) { defaults.set(data, forKey: Keys.nameParts) }
        }
    }
    /// Whether PadPad has explained, once, that a draft would have cleared. Reset App explains it again.
    var explainedClearing: Bool {
        didSet { defaults.set(explainedClearing, forKey: Keys.explainedClearing) }
    }
    private var nextNumber: Int
    private let defaults: UserDefaults
    static let defaultReusePeriod = PadReuse.thirtyMinutes

    private enum Keys {
        static let format = "pad.format"
        static let enabledFormats = "pad.enabledFormats"
        static let saveAutomatically = "pad.saveAutomatically"
        static let reusePeriod = "pad.reusePeriod"
        static let nameParts = "pad.nameParts"
        static let nextNumber = "pad.nextNumber"
        static let numberDay = "pad.numberDay"
        static let resetNumberDaily = "pad.resetNumberDaily"
        static let copyPathAfterSaving = "pad.copyPathAfterSaving"
        static let explainedClearing = "pad.explainedClearing"
    }

    /// Only the quick pad's settings correct invalid stored formats; a file document reading them changes nothing.
    init(defaults: UserDefaults, correctsStoredFormats: Bool = true) {
        self.defaults = defaults
        let storedFormats = defaults.stringArray(forKey: Keys.enabledFormats)
        let selected = PadFormat.allCases.filter { storedFormats?.contains($0.rawValue) ?? true }
        let enabled = selected.isEmpty ? PadFormat.allCases : selected
        enabledFormats = enabled
        let storedDefault = defaults.string(forKey: Keys.format).flatMap(PadFormat.init(rawValue:)) ?? .md
        let initialFormat = enabled.contains(storedDefault) ? storedDefault : enabled[0]
        defaultFormat = initialFormat
        if correctsStoredFormats, defaults.object(forKey: Keys.enabledFormats) != nil {
            if storedFormats != enabled.map(\.rawValue) { defaults.set(enabled.map(\.rawValue), forKey: Keys.enabledFormats) }
            if initialFormat != storedDefault { defaults.set(initialFormat.rawValue, forKey: Keys.format) }
        }
        // `bool(forKey:)` also reads launch-argument overrides, which arrive as strings.
        saveAutomatically = defaults.bool(forKey: Keys.saveAutomatically)
        reusePeriod = (defaults.object(forKey: Keys.reusePeriod) as? Int).flatMap(PadReuse.init(rawValue:)) ?? Self.defaultReusePeriod
        explainedClearing = defaults.bool(forKey: Keys.explainedClearing)
        nameParts = defaults.data(forKey: Keys.nameParts)
            .flatMap { try? JSONDecoder().decode([PadNamePart].self, from: $0) } ?? PadFilename.defaultParts
        copiesPathAfterSaving = defaults.bool(forKey: Keys.copyPathAfterSaving)
        resetsNumberDaily = defaults.object(forKey: Keys.resetNumberDaily) == nil || defaults.bool(forKey: Keys.resetNumberDaily)
        nextNumber = max(1, defaults.integer(forKey: Keys.nextNumber))
    }

    func setFormatEnabled(_ candidate: PadFormat, enabled: Bool) {
        var selected = Set(enabledFormats)
        if enabled { selected.insert(candidate) } else { selected.remove(candidate) }
        guard !selected.isEmpty else { return }
        enabledFormats = PadFormat.allCases.filter { selected.contains($0) }
        defaults.set(enabledFormats.map(\.rawValue), forKey: Keys.enabledFormats)
        if !selected.contains(format), let first = enabledFormats.first { format = first }
    }

    /// Whether Save copies a new file's path. Read from defaults, so a launch-argument override still wins.
    var copiesPathOnSave: Bool { defaults.bool(forKey: Keys.copyPathAfterSaving) }

    /// An example of the next generated name, for Settings.
    func namePreview(now: Date) -> String {
        // Read the observed values so the preview follows the counter and its setting.
        _ = (nextNumber, resetsNumberDaily)
        return (try? PadFilename.name(parts: nameParts, format: format, now: now, number: startingNumber(on: now)))
            ?? "Invalid filename"
    }

    /// The name the next generated file in `folder` would get, skipping taken names, without using up its number.
    func nextName(in folder: URL, format: PadFormat, now: Date) -> String? {
        (try? PadFilename.available(in: folder, parts: nameParts, format: format, now: now,
                                    number: startingNumber(on: now)))?.url.lastPathComponent
    }

    /// Says when a closed draft clears, for Settings and the draft title.
    var clearingDescription: String {
        reusePeriod == .alwaysNew ? "each time you open PadPad" : "\(reusePeriod.title) after you close PadPad"
    }

    /// The number the next generated name starts from. The counter is shared by every window, so it is read
    /// from defaults; with daily reset on, a counter last used on another day starts again at 1.
    func startingNumber(on date: Date) -> Int {
        let stored = max(1, defaults.integer(forKey: Keys.nextNumber))
        // Read the stored value, not the property, so a launch-argument override still wins.
        let resets = defaults.object(forKey: Keys.resetNumberDaily) == nil || defaults.bool(forKey: Keys.resetNumberDaily)
        guard resets else { return stored }
        return defaults.string(forKey: Keys.numberDay) == Self.dayStamp(date) ? stored : 1
    }

    func advanceGeneratedNumber(after number: Int, on date: Date) {
        nextNumber = max(number + 1, startingNumber(on: date))
        defaults.set(nextNumber, forKey: Keys.nextNumber)
        defaults.set(Self.dayStamp(date), forKey: Keys.numberDay)
    }

    /// Restores every Files setting except the save folder, which the quick pad forgets itself.
    func reset() {
        // The default applies to future drafts; the current draft keeps its format and text.
        enabledFormats = PadFormat.allCases
        defaults.set(enabledFormats.map(\.rawValue), forKey: Keys.enabledFormats)
        format = .md
        saveAutomatically = false
        reusePeriod = Self.defaultReusePeriod
        explainedClearing = false
        nameParts = PadFilename.defaultParts
        copiesPathAfterSaving = false
        resetsNumberDaily = true
    }

    private static func dayStamp(_ date: Date) -> String {
        let day = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}

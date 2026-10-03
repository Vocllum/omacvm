// The Mac's menu bar clock as a Qt date format, for Omarchy's bar clock.
// Follows System Settings > Control Center > Clock Options (day of the week,
// date, AM/PM, seconds) and the Mac's language, region and 24-hour setting.
//   swift mac-clock.swift [LOCALE]     e.g. "ddd d MMM HH:mm"
import Foundation

let prefs = UserDefaults(suiteName: "com.apple.menuextra.clock")
func pref(_ key: String, _ fallback: Int) -> Int { prefs?.object(forKey: key) as? Int ?? fallback }

let locale = CommandLine.arguments.count > 1 ? Locale(identifier: CommandLine.arguments[1]) : Locale.autoupdatingCurrent
// ShowDate: 0 when space allows, 1 always, 2 never. Omarchy's bar has the space.
// Date and time apart, as in the menu bar (a combined pattern adds "at").
var day = ""
if pref("ShowDayOfWeek", 1) == 1 { day += "EEE" }
if pref("ShowDate", 0) != 2 { day += "MMMd" }
func pattern(_ t: String) -> String { t.isEmpty ? "" : DateFormatter.dateFormat(fromTemplate: t, options: 0, locale: locale) ?? "" }
var time = pattern(pref("ShowSeconds", 0) == 1 ? "jmmss" : "jmm")
if pref("ShowAMPM", 1) == 0 { time = time.replacingOccurrences(of: "\\s*a\\s*", with: " ", options: .regularExpression) }
let icu = pattern(day) + " " + time

// ICU pattern -> Qt format. The menu bar leaves out the commas.
let qt: [Character: [Int: String]] = [
    "E": [1: "ddd", 2: "ddd", 3: "ddd", 4: "dddd"], "c": [3: "ddd", 4: "dddd"],
    "d": [1: "d", 2: "dd"], "M": [1: "M", 2: "MM", 3: "MMM", 4: "MMMM"], "L": [1: "M", 2: "MM", 3: "MMM", 4: "MMMM"],
    "y": [1: "yyyy", 2: "yy", 4: "yyyy"], "H": [1: "H", 2: "HH"], "h": [1: "h", 2: "hh"],
    "k": [1: "H", 2: "HH"], "K": [1: "h", 2: "hh"], "m": [1: "m", 2: "mm"], "s": [1: "s", 2: "ss"], "a": [1: "AP"],
]
var out = "", i = icu.startIndex, quoted = false
while i < icu.endIndex {
    let c = icu[i]
    if c == "'" { out.append(c); quoted.toggle(); i = icu.index(after: i); continue }
    if quoted || !(c.isASCII && c.isLetter) {
        if quoted || c != "," { out.append(c) }
        i = icu.index(after: i); continue
    }
    var j = i, n = 0
    while j < icu.endIndex && icu[j] == c { n += 1; j = icu.index(after: j) }
    out += qt[c]?[n] ?? qt[c]?[n > 2 ? 3 : n] ?? ""
    i = j
}
print(out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces))

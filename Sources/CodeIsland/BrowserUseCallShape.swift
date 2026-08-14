import Foundation

/// What in a Browser Use call could send the browser somewhere new — the only thing
/// Codex's `Allow Browser use to access <origin>?` prompt gates.
enum BrowserUseNavigation: Equatable {
    /// Nothing in the code moves the browser: `evaluate`, `domSnapshot`, `innerText`,
    /// `screenshot`, locator reads. Codex never asks about an origin it isn't visiting,
    /// so however long these run, they are not waiting on a confirmation.
    case none
    /// `goto` / `navigate` / `getForUrl` / `tabs.new(url)`. `url` is the destination when
    /// the code spells one out, `nil` when it comes from a variable.
    case direct(url: String?)
    /// A click or key press that may follow a link to another origin.
    case indirect
}

/// A static read of the JavaScript a Browser Use call is about to run.
///
/// The attention card used to key off duration alone, which made every slow page load
/// look like a blocked confirmation. Two things in the source say more than the clock:
/// whether the call can navigate at all, and how much of its runtime it asked for
/// up front.
struct BrowserUseCallShape: Equatable {
    let navigation: BrowserUseNavigation
    /// The waits the script schedules for itself (`waitForTimeout(28000)` and friends).
    /// A call is only evidence of a stall for the time it runs *beyond* these.
    let declaredWait: TimeInterval

    static let none = BrowserUseCallShape(navigation: .none, declaredWait: 0)

    /// A polling script can legitimately sleep for minutes; a confirmation the user
    /// never hears about is worse than a card that comes a little late, so the budget
    /// this buys stops here.
    static let maxDeclaredWait: TimeInterval = 60

    static func read(_ code: String) -> BrowserUseCallShape {
        BrowserUseCallShape(
            navigation: navigation(in: code),
            declaredWait: min(declaredWait(in: code), maxDeclaredWait)
        )
    }

    // MARK: - Navigation

    /// `tab.goto(…)`, `browser.navigate(…)`, `agent.browsers.getForUrl(…)`, and
    /// `tabs.new(…)` *with* an argument. A bare `tabs.new()` opens a blank tab and is
    /// left out: the `goto` that follows is what asks for an origin. `reload`,
    /// `goBack` and `goForward` are left out too — they revisit an origin the browser
    /// is already on, which by definition has an answer on record.
    private static let directNavigation = try? NSRegularExpression(
        pattern: #"\.(?:goto|navigate|getForUrl)\s*\(|\btabs\.new\s*\(\s*[^)\s]"#,
        options: [.caseInsensitive]
    )

    private static let interaction = try? NSRegularExpression(
        pattern: #"\.(?:click|dblclick|press|tap|submit|selectOption)\s*\("#,
        options: [.caseInsensitive]
    )

    private static let urlLiteral = try? NSRegularExpression(
        pattern: #"https?://[^\s"'\\)>\]`]+"#
    )

    /// How far past a navigation call to look for its destination. Wide enough for
    /// `tabs.new({ url: "…" })` and options objects, narrow enough that an unrelated URL
    /// further down the script isn't mistaken for where this call is going.
    private static let destinationWindow = 300

    private static func navigation(in code: String) -> BrowserUseNavigation {
        let full = NSRange(code.startIndex..<code.endIndex, in: code)
        guard let directNavigation else { return .none }

        let sites = directNavigation.matches(in: code, range: full)
        if !sites.isEmpty {
            for site in sites {
                let start = site.range.upperBound
                let window = NSRange(
                    location: start,
                    length: min(destinationWindow, full.length - start)
                )
                if let match = urlLiteral?.firstMatch(in: code, range: window),
                   let range = Range(match.range, in: code) {
                    return .direct(url: String(code[range]))
                }
            }
            return .direct(url: nil)
        }

        if interaction?.firstMatch(in: code, range: full) != nil { return .indirect }
        return .none
    }

    // MARK: - Declared wait

    private static let explicitWait = try? NSRegularExpression(
        pattern: #"\b(?:waitForTimeout|sleep|delay)\s*\(\s*\{?\s*(?:timeout(?:Ms)?\s*:\s*)?(\d{3,7})"#,
        options: [.caseInsensitive]
    )

    /// `setTimeout(resolve, 28000)` — the delay is the second argument, so skip past the
    /// callback first.
    private static let scheduledWait = try? NSRegularExpression(
        pattern: #"\bsetTimeout\s*\([^;]{0,160}?,\s*(\d{3,7})\s*\)"#,
        options: [.caseInsensitive]
    )

    private static func declaredWait(in code: String) -> TimeInterval {
        let full = NSRange(code.startIndex..<code.endIndex, in: code)
        var total: Double = 0
        for regex in [explicitWait, scheduledWait] {
            guard let regex else { continue }
            for match in regex.matches(in: code, range: full) {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: code),
                      let milliseconds = Double(code[range]) else { continue }
                total += milliseconds / 1000
            }
        }
        return total
    }
}

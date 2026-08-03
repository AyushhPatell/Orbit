//
//  OrbitMacControlCenter+Browser.swift
//  ORBITMac
//
//  Browser control — open URL or search in a specific browser.
//  Handles 35+ phrase variants; fuzzy browser name matching for typos/misspellings.
//

import AppKit
import Foundation

extension OrbitMacControlCenter {

    // MARK: - Browser registry

    private struct BrowserEntry {
        let aliases: [String]
        let bundle: String
        let displayName: String
    }

    private static let browserRegistry: [BrowserEntry] = [
        BrowserEntry(aliases: ["chrome", "google chrome", "google"], bundle: "com.google.Chrome", displayName: "Chrome"),
        BrowserEntry(aliases: ["safari"], bundle: "com.apple.Safari", displayName: "Safari"),
        BrowserEntry(aliases: ["arc"], bundle: "company.thebrowser.Browser", displayName: "Arc"),
        BrowserEntry(aliases: ["firefox", "mozilla", "mozilla firefox", "fire fox"], bundle: "org.mozilla.firefox", displayName: "Firefox"),
        BrowserEntry(aliases: ["brave", "brave browser"], bundle: "com.brave.Browser", displayName: "Brave"),
        BrowserEntry(aliases: ["edge", "microsoft edge"], bundle: "com.microsoft.edgemac", displayName: "Edge"),
        BrowserEntry(aliases: ["opera"], bundle: "com.operasoftware.Opera", displayName: "Opera"),
        BrowserEntry(aliases: ["vivaldi"], bundle: "com.vivaldi.Vivaldi", displayName: "Vivaldi"),
    ]

    /// Resolves any browser name (including typos) to a (bundle ID, display name) pair.
    /// Tries exact → substring → fuzzy (edit distance ≤ 2) in order.
    static func resolveBrowser(_ name: String) -> (bundle: String, displayName: String)? {
        let q = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        // 1. Exact alias match
        for entry in browserRegistry {
            if entry.aliases.contains(q) { return (entry.bundle, entry.displayName) }
        }
        // 2. Substring match — handles "google chrome", "chromez", "safar", etc.
        for entry in browserRegistry {
            for alias in entry.aliases {
                if q.contains(alias) || alias.contains(q) { return (entry.bundle, entry.displayName) }
            }
        }
        // 3. Levenshtein ≤ 2 — handles "firfox", "crhome", etc.
        for entry in browserRegistry {
            if entry.aliases.contains(where: { levenshteinDistance($0, q) <= 2 }) {
                return (entry.bundle, entry.displayName)
            }
        }
        return nil
    }

    // MARK: - Site registry

    static let siteAliases: [String: String] = [
        "youtube":          "https://youtube.com",
        "gmail":            "https://mail.google.com",
        "google":           "https://google.com",
        "google docs":      "https://docs.google.com",
        "google drive":     "https://drive.google.com",
        "google maps":      "https://maps.google.com",
        "github":           "https://github.com",
        // Phonetic aliases — speech recognizer mishears with Indian accent
        "geetha":           "https://github.com",
        "geethu":           "https://github.com",
        "geeta":            "https://github.com",
        "geetha hub":       "https://github.com",
        "git hub":          "https://github.com",
        "githup":           "https://github.com",
        "get hub":          "https://github.com",
        "gethub":           "https://github.com",
        "you tube":         "https://youtube.com",
        "youtube music":    "https://music.youtube.com",
        "linked in":        "https://linkedin.com",
        "what sapp":        "https://web.whatsapp.com",
        "what sup":         "https://web.whatsapp.com",
        "chat gpt":         "https://chatgpt.com",
        "open ai":          "https://openai.com",
        "tick tock":        "https://tiktok.com",
        "tik tok":          "https://tiktok.com",
        "twitter":          "https://twitter.com",
        "x":                "https://x.com",
        "instagram":        "https://instagram.com",
        "facebook":         "https://facebook.com",
        "netflix":          "https://netflix.com",
        "reddit":           "https://reddit.com",
        "linkedin":         "https://linkedin.com",
        "whatsapp":         "https://web.whatsapp.com",
        "notion":           "https://notion.so",
        "slack":            "https://app.slack.com",
        "teams":            "https://teams.microsoft.com",
        "spotify":          "https://open.spotify.com",
        "amazon":           "https://amazon.com",
        "stackoverflow":    "https://stackoverflow.com",
        "stack overflow":   "https://stackoverflow.com",
        "chatgpt":          "https://chatgpt.com",
        "openai":           "https://openai.com",
        "claude":           "https://claude.ai",
        "figma":            "https://figma.com",
        "vercel":           "https://vercel.com",
        "heroku":           "https://heroku.com",
        "twitch":           "https://twitch.tv",
        "discord":          "https://discord.com",
        "dropbox":          "https://dropbox.com",
        "trello":           "https://trello.com",
        "jira":             "https://atlassian.net",
        "medium":           "https://medium.com",
        "wikipedia":        "https://wikipedia.org",
        "maps":             "https://maps.google.com",
        "drive":            "https://drive.google.com",
        "outlook":          "https://outlook.office.com",
        "hotmail":          "https://outlook.com",
        "yahoo":            "https://yahoo.com",
        "bing":             "https://bing.com",
        "duckduckgo":       "https://duckduckgo.com",
        "producthunt":      "https://producthunt.com",
        "hacker news":      "https://news.ycombinator.com",
        "ycombinator":      "https://news.ycombinator.com",
        "pinterest":        "https://pinterest.com",
        "tiktok":           "https://tiktok.com",
        "canva":            "https://canva.com",
        "linear":           "https://linear.app",
        "supabase":         "https://supabase.com",
        "anthropic":        "https://anthropic.com",
        "totalsportek":     "https://totalsportek24.is/",
        "fifa":             "https://totalsportek24.is/",
        "fifa match":       "https://totalsportek24.is/",
        "football":         "https://totalsportek24.is/",
        "football match":   "https://totalsportek24.is/",
        "watch football":   "https://totalsportek24.is/",
        "watch fifa":       "https://totalsportek24.is/",
        "apple music":      "https://music.apple.com",
        "myhub":            "https://myhub-d0f5a.web.app/",
        "my hub":           "https://myhub-d0f5a.web.app/",
        "mu hub":           "https://myhub-d0f5a.web.app/",    // phonetic mishear
        "kachuful":         "https://kachuful-70077.web.app/",
        // Phonetic mishears — "kaju" (cashew in Hindi) is what the recognizer hears
        "kaju full":        "https://kachuful-70077.web.app/",
        "kaju fool":        "https://kachuful-70077.web.app/",
        "kaju phul":        "https://kachuful-70077.web.app/",
        "kachu full":       "https://kachuful-70077.web.app/",
        "kachu fool":       "https://kachuful-70077.web.app/",
        "cachu full":       "https://kachuful-70077.web.app/",
        "cashew full":      "https://kachuful-70077.web.app/",
        "kachful":          "https://kachuful-70077.web.app/",
        // Phonetic mishears — Apple STT hears "kachuful" as "a game catch full"
        "a game catch full":    "https://kachuful-70077.web.app/",
        "game catch full":      "https://kachuful-70077.web.app/",
        "our game catch full":  "https://kachuful-70077.web.app/",
        "a game catch":         "https://kachuful-70077.web.app/",
        "catch full":           "https://kachuful-70077.web.app/",
        "our website":      "https://kachuful-70077.web.app/",
        "our site":         "https://kachuful-70077.web.app/",
        "our game":         "https://kachuful-70077.web.app/",
        "our card game":    "https://kachuful-70077.web.app/",
        "play kachuful":    "https://kachuful-70077.web.app/",
        "kachuful game":    "https://kachuful-70077.web.app/",

        // ── Dalhousie / work tools
        // "dal" is heard as "dell", "del", "dial", "bell", "dull" — all variants covered below
        "brightspace":              "https://dal.brightspace.com/d2l/home",
        "bright space":             "https://dal.brightspace.com/d2l/home",
        "dal brightspace":          "https://dal.brightspace.com/d2l/home",
        "dal bright space":         "https://dal.brightspace.com/d2l/home",
        "dell brightspace":         "https://dal.brightspace.com/d2l/home",
        "dell bright space":        "https://dal.brightspace.com/d2l/home",
        "del brightspace":          "https://dal.brightspace.com/d2l/home",
        "del bright space":         "https://dal.brightspace.com/d2l/home",
        "dial brightspace":         "https://dal.brightspace.com/d2l/home",
        "dial bright space":        "https://dal.brightspace.com/d2l/home",
        "bell brightspace":         "https://dal.brightspace.com/d2l/home",
        "bell bright space":        "https://dal.brightspace.com/d2l/home",
        "dull brightspace":         "https://dal.brightspace.com/d2l/home",
        "dull bright space":        "https://dal.brightspace.com/d2l/home",
        "dalhousie brightspace":    "https://dal.brightspace.com/d2l/home",
        "dalhousie bright space":   "https://dal.brightspace.com/d2l/home",
        "brite space":              "https://dal.brightspace.com/d2l/home",
        "dal brite space":          "https://dal.brightspace.com/d2l/home",
        "dell brite space":         "https://dal.brightspace.com/d2l/home",
        "dell price space":         "https://dal.brightspace.com/d2l/home",

        "dal online":       "https://self-service.dal.ca/BannerExtensibility/customPage/page/dal.genweb_landingPage",
        "dalonline":        "https://self-service.dal.ca/BannerExtensibility/customPage/page/dal.genweb_landingPage",
        "dal on line":      "https://self-service.dal.ca/BannerExtensibility/customPage/page/dal.genweb_landingPage",
        // "dal" mishears — all variations the recognizer could produce
        "del online":       "https://self-service.dal.ca/BannerExtensibility/customPage/page/dal.genweb_landingPage",
        "dell online":      "https://self-service.dal.ca/BannerExtensibility/customPage/page/dal.genweb_landingPage",
        "dial online":      "https://self-service.dal.ca/BannerExtensibility/customPage/page/dal.genweb_landingPage",
        "bell online":      "https://self-service.dal.ca/BannerExtensibility/customPage/page/dal.genweb_landingPage",
        "dull online":      "https://self-service.dal.ca/BannerExtensibility/customPage/page/dal.genweb_landingPage",
        "dhal online":      "https://self-service.dal.ca/BannerExtensibility/customPage/page/dal.genweb_landingPage",
        "daal online":      "https://self-service.dal.ca/BannerExtensibility/customPage/page/dal.genweb_landingPage",
        "dell on line":     "https://self-service.dal.ca/BannerExtensibility/customPage/page/dal.genweb_landingPage",
        "del on line":      "https://self-service.dal.ca/BannerExtensibility/customPage/page/dal.genweb_landingPage",

        "its tool":         "https://nandstools.dal.ca/login",
        "itstool":          "https://nandstools.dal.ca/login",
        "its tools":        "https://nandstools.dal.ca/login",
        "it tool":          "https://nandstools.dal.ca/login",
        "it's tool":        "https://nandstools.dal.ca/login",
        "its tool login":   "https://nandstools.dal.ca/login",
        "nands tools":      "https://nandstools.dal.ca/login",
        "nand tools":       "https://nandstools.dal.ca/login",

        "application navigator":    "https://self-service.dal.ca/applicationNavigator/seamless",
        "app navigator":            "https://self-service.dal.ca/applicationNavigator/seamless",
        "application nav":          "https://self-service.dal.ca/applicationNavigator/seamless",
        "app nav":                  "https://self-service.dal.ca/applicationNavigator/seamless",

        "dal jira":         "https://dalhousie.atlassian.net/jira/for-you",
        "dalhousie jira":   "https://dalhousie.atlassian.net/jira/for-you",
        "its jira":         "https://dalhousie.atlassian.net/jira/for-you",
        "dell jira":        "https://dalhousie.atlassian.net/jira/for-you",
        "del jira":         "https://dalhousie.atlassian.net/jira/for-you",
        "bell jira":        "https://dalhousie.atlassian.net/jira/for-you",
        // Phonetic — "jira" sounds like "jeera" (cumin) with Indian accent
        "dal jeera":        "https://dalhousie.atlassian.net/jira/for-you",
        "dalhousie jeera":  "https://dalhousie.atlassian.net/jira/for-you",
        "its jeera":        "https://dalhousie.atlassian.net/jira/for-you",
        "dell jeera":       "https://dalhousie.atlassian.net/jira/for-you",
        "del jeera":        "https://dalhousie.atlassian.net/jira/for-you",
        "bell jeera":       "https://dalhousie.atlassian.net/jira/for-you",
        "dal jera":         "https://dalhousie.atlassian.net/jira/for-you",
        "del jera":         "https://dalhousie.atlassian.net/jira/for-you",

        // 8x8 — speech recognizer outputs "8 by 8" or "eight by eight" for "8x8"
        "8x8":                  "https://sso.8x8.com/v2/login",
        "8 by 8":               "https://sso.8x8.com/v2/login",
        "8 x 8":                "https://sso.8x8.com/v2/login",
        "eight by eight":       "https://sso.8x8.com/v2/login",
        "eight x eight":        "https://sso.8x8.com/v2/login",
        "8x8 login":            "https://sso.8x8.com/v2/login",
        "8 by 8 login":         "https://sso.8x8.com/v2/login",
        "8 by 8 log in":        "https://sso.8x8.com/v2/login",  // "login" as two words
        "eight by eight login": "https://sso.8x8.com/v2/login",
        "eight by eight log in":"https://sso.8x8.com/v2/login",

        // Azure — "azure" is consistently misheard; cover every reported variant
        "microsoft azure":      "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        "azure":                "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        "ms azure":             "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        // Reported: "assure", "microsoft agr" — plus other likely mishears
        "assure":               "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        "microsoft assure":     "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        "microsoft agr":        "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        "microsoft ag":         "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        "azer":                 "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        "asure":                "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        "as sure":              "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        "as your":              "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        "asher":                "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        "microsoft asure":      "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        "microsoft azer":       "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
        "microsoft as sure":    "https://portal.azure.com/#view/Microsoft_AAD_UsersAndTenants/UserManagementMenuBlade/~/AllUsers",
    ]

    /// Apps that have a desktop version — "open outlook" should launch the app, not the website.
    private static let desktopAppAliases: [String: String] = [
        "outlook": "com.microsoft.Outlook",
        "teams":   "com.microsoft.teams2",
        "slack":   "com.tinyspeck.slackmacgap",
        "discord": "com.hnc.Discord",
        "zoom":    "us.zoom.xos",
        "notion":  "notion.id",
        "claude":  "com.anthropic.claudefordesktop",
    ]

    /// Returns a URL for a site name or raw URL string (e.g. "github.com", "https://example.com").
    static func siteURL(for name: String) -> URL? {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        // Prefer desktop app if installed — "open outlook" → launch app, not browser
        if let bundleID = desktopAppAliases[lower],
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            return nil
        }
        // 1. Exact alias match
        if let known = siteAliases[lower] { return URL(string: known) }
        // 2. Strip TLD and retry alias — catches "geetha.com" → "geetha" → github.com
        //    Also catches "github.com" → "github" → github.com (canonical match)
        let tlds = [".com", ".org", ".net", ".io", ".co", ".tv", ".ai", ".so", ".app", ".ca"]
        for tld in tlds where lower.hasSuffix(tld) {
            let stripped = String(lower.dropLast(tld.count))
            if let known = siteAliases[stripped] { return URL(string: known) }
        }
        // 3. Raw URL — has a dot, no spaces (e.g. "vercel.com", "my.custom.domain")
        if lower.contains("."), !lower.contains(" ") {
            let withScheme = lower.hasPrefix("http") ? lower : "https://\(lower)"
            if let url = URL(string: withScheme) { return url }
        }
        return nil
    }

    // MARK: - Intent detection

    /// Navigation verbs — ambiguous with "open [App]" so need careful handling
    private static let navVerbs: [String] = [
        "go to", "navigate to", "take me to", "head to", "get me to",
        "jump to", "bring up", "pull up", "browse to", "check out",
        "open", "launch", "load", "show me", "visit",
    ]

    /// These nav verbs are unambiguous web commands — safe to use without checking siteAliases
    private static let unambiguousNavVerbs: [String] = [
        "go to", "navigate to", "take me to", "head to", "get me to",
        "jump to", "bring up", "pull up", "browse to", "check out",
        "load", "show me", "visit",
    ]

    private static let searchVerbs: [String] = [
        "search for", "search", "look up", "find", "look for",
    ]

    private static let fillerPrefixes: [String] = [
        "can you please ", "could you please ", "can you ", "could you ",
        "please ", "hey orbit ", "hey ", "um ", "uh ", "yo ", "ok ", "okay ",
        "alright ", "right ", "so ", "well ",
    ]

    /// Intermediate result — avoids depending on the private Command enum.
    enum BrowserIntentResult {
        case navigate(url: URL, bundle: String?)
        case search(query: String, bundle: String?)
    }

    /// Returns a BrowserIntentResult if the input is a browser navigation or search intent.
    /// MUST be called BEFORE extractOpenAppTarget in parseCommand.
    static func parseBrowserIntent(from normalized: String) -> BrowserIntentResult? {
        // Strip filler prefix and recurse once
        for filler in fillerPrefixes.sorted(by: { $0.count > $1.count }) {
            if normalized.hasPrefix(filler) {
                let stripped = String(normalized.dropFirst(filler.count))
                if let cmd = parseBrowserIntent(from: stripped) { return cmd }
                break
            }
        }

        // ── Group 0: bare known alias with no verb — exact alias match
        //    "eight by eight login", "brightspace", "dal online", "azure" etc. said without verb
        //    This catches commands where the user names the site directly without "open"/"go to"
        if let url = siteURL(for: normalized) {
            return .navigate(url: url, bundle: nil)
        }

        // ── Group 1: "open/launch [browser] and [connector] [site]"
        //    "open Chrome and go to YouTube", "launch Safari and search Python"
        let g1connectors = ["go to", "navigate to", "visit", "open", "load", "browse to", "search for", "search"]
        for startVerb in ["open", "launch"] {
            for connector in g1connectors.sorted(by: { $0.count > $1.count }) {
                let esc = NSRegularExpression.escapedPattern(for: connector)
                let pat = "^\(startVerb)\\s+([a-z][a-z0-9 ]*?)\\s+and\\s+\(esc)\\s+([a-z0-9. ]+)$"
                if let g = regexGroups(normalized, pattern: pat), g.count >= 2 {
                    let bName = g[0].trimmingCharacters(in: .whitespaces)
                    let target = g[1].trimmingCharacters(in: .whitespaces)
                    if let (bundle, display) = resolveBrowser(bName) {
                        return smartBrowserCommand(target: target, bundle: bundle, browserDisplay: display)
                    }
                }
            }
        }

        // ── Group 2: "open/switch [browser] to [site]"
        //    "open Safari to YouTube", "switch Chrome to Netflix"
        for startVerb in ["open", "switch"] {
            let pat = "^\(startVerb)\\s+([a-z][a-z0-9 ]*?)\\s+to\\s+([a-z0-9. ]+)$"
            if let g = regexGroups(normalized, pattern: pat), g.count >= 2 {
                let bName = g[0].trimmingCharacters(in: .whitespaces)
                let target = g[1].trimmingCharacters(in: .whitespaces)
                if let (bundle, display) = resolveBrowser(bName), siteURL(for: target) != nil {
                    return smartBrowserCommand(target: target, bundle: bundle, browserDisplay: display)
                }
            }
        }

        // ── Group 3: "[verb] [site] in/on/using/with [browser]"
        //    "open YouTube in Chrome", "go to Netflix in Arc", "search Python in Firefox"
        //    "visit github.com using Brave", "find Swift tutorials on Edge"
        let g3preps = ["in", "on", "using", "with", "through", "via"]
        let g3verbs = (navVerbs + searchVerbs).sorted(by: { $0.count > $1.count })
        for verb in g3verbs {
            for prep in g3preps {
                let esc = NSRegularExpression.escapedPattern(for: verb)
                let pat = "^\(esc)\\s+([a-z0-9. ]+?)\\s+\(prep)\\s+([a-z][a-z0-9 ]*)$"
                if let g = regexGroups(normalized, pattern: pat), g.count >= 2 {
                    let target = g[0].trimmingCharacters(in: .whitespaces)
                    let bName = g[1].trimmingCharacters(in: .whitespaces)
                    if let (bundle, display) = resolveBrowser(bName) {
                        return smartBrowserCommand(target: target, bundle: bundle, browserDisplay: display)
                    }
                }
            }
        }

        // ── Group 4: "[unambiguous nav verb] [site]" (default browser)
        //    "go to YouTube", "take me to netflix", "visit github.com", "pull up reddit"
        for verb in unambiguousNavVerbs.sorted(by: { $0.count > $1.count }) {
            let esc = NSRegularExpression.escapedPattern(for: verb)
            let pat = "^\(esc)\\s+([a-z0-9.][a-z0-9. ]*)$"
            if let g = regexGroups(normalized, pattern: pat), g.count >= 1 {
                let siteName = g[0].trimmingCharacters(in: .whitespaces)
                if let url = siteURL(for: siteName) {
                    return .navigate(url: url, bundle: nil)
                }
            }
        }

        // ── Group 5: "open/launch [known site]" — only when NOT a browser name
        //    "open YouTube", "open netflix", "open github.com"
        //    "open Chrome" → falls through to openApp (correct — opens Chrome app)
        let g5pat = "^(?:open|launch)\\s+([a-z0-9.][a-z0-9. ]*)$"
        if let g = regexGroups(normalized, pattern: g5pat), g.count >= 1 {
            let siteName = g[0].trimmingCharacters(in: .whitespaces)
            if resolveBrowser(siteName) == nil, let url = siteURL(for: siteName) {
                return .navigate(url: url, bundle: nil)
            }
        }

        // ── Group 6: "[search verb] [query]" — default browser search
        //    "search for Python tutorials", "look up Swift closures", "find machine learning"
        for verb in searchVerbs.sorted(by: { $0.count > $1.count }) {
            let esc = NSRegularExpression.escapedPattern(for: verb)
            let pat = "^\(esc)\\s+([a-z0-9][a-z0-9 .+\\-':]+)$"
            if let g = regexGroups(normalized, pattern: pat), g.count >= 1 {
                let query = g[0].trimmingCharacters(in: .whitespaces)
                if query.count >= 3 || query.contains(".") {
                    return smartBrowserCommand(target: query, bundle: nil, browserDisplay: nil)
                }
            }
        }

        return nil
    }

    /// Navigate to `target` if it's a URL/site; otherwise search for it.
    private static func smartBrowserCommand(target: String, bundle: String?, browserDisplay: String?) -> BrowserIntentResult {
        if let url = siteURL(for: target) {
            return .navigate(url: url, bundle: bundle)
        }
        return .search(query: target, bundle: bundle)
    }

    // MARK: - Execution

    static func openURLInBrowser(_ url: URL, browserBundle: String?) throws -> String {
        let siteName: String
        if let alias = siteAliases.first(where: { URL(string: $0.value)?.host == url.host }) {
            siteName = alias.key.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
        } else {
            siteName = url.host?.replacingOccurrences(of: "www.", with: "") ?? url.absoluteString
        }

        if let bundle = browserBundle {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, _ in }
                let display = browserRegistry.first(where: { $0.bundle == bundle })?.displayName
                    ?? appURL.deletingPathExtension().lastPathComponent
                return "Opening \(siteName) in \(display)."
            }
            // Specified browser not installed — graceful fallback
            NSWorkspace.shared.open(url)
            let display = browserRegistry.first(where: { $0.bundle == bundle })?.displayName ?? bundle
            return "Couldn\u{2019}t find \(display) \u{2014} opened \(siteName) in your default browser instead."
        }

        NSWorkspace.shared.open(url)
        return "Opening \(siteName)."
    }

    static func searchInBrowser(query: String, browserBundle: String?) throws -> String {
        // If query is a known site or URL-like, navigate directly instead of searching
        if let url = siteURL(for: query) {
            return try openURLInBrowser(url, browserBundle: browserBundle)
        }
        guard let searchURL = WebActionService.searchURL(for: query) else {
            throw ControlError.actionFailed("Couldn\u{2019}t build search URL.")
        }

        if let bundle = browserBundle {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.open([searchURL], withApplicationAt: appURL, configuration: cfg) { _, _ in }
                let display = browserRegistry.first(where: { $0.bundle == bundle })?.displayName ?? bundle
                return "Searching for \u{2018}\(query)\u{2019} in \(display)."
            }
            NSWorkspace.shared.open(searchURL)
            let display = browserRegistry.first(where: { $0.bundle == bundle })?.displayName ?? bundle
            return "Couldn\u{2019}t find \(display) \u{2014} searching in your default browser instead."
        }

        NSWorkspace.shared.open(searchURL)
        return "Searching for \u{2018}\(query)\u{2019}."
    }

    // MARK: - Helpers

    private static func regexGroups(_ s: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        var groups: [String] = []
        for i in 1..<m.numberOfRanges {
            groups.append(Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "")
        }
        return groups
    }

    // levenshteinDistance is defined in OrbitMacControlCenter+Files.swift — shared across extension.
}

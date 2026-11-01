import AppKit

/// Asks GitHub whether there is a newer Mixtape and offers it. It only tells: installing is
/// still download, open, drag onto Applications – the app isn't signed, so it can't replace itself.
@MainActor
enum Updates {
    nonisolated static let latest = URL(string: "https://api.github.com/repos/aeiou11235/mixtape/releases/latest")!
    nonisolated static let download = URL(string: "https://github.com/aeiou11235/mixtape/releases/latest/download/Mixtape.dmg")!

    private struct Release: Decodable {
        let tag_name: String
        let body: String?
    }

    /// On launch, at most once a day, and quietly: it says nothing unless there is something new.
    /// This Mac's own build (Mixtape Master) is left alone; it can still ask from the menu.
    static func checkLater() {
        let d = UserDefaults.standard
        if let last = d.object(forKey: "updateCheck") as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "Mixtape Master" { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await check(manual: false)
        }
    }

    /// `manual`: from the menu, so it also says when there is nothing new or GitHub can't be reached.
    static func check(manual: Bool) async {
        UserDefaults.standard.set(Date(), forKey: "updateCheck")
        var req = URLRequest(url: latest, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data) else {
            if manual { tell(L("Keine Verbindung"), L("Mixtape konnte gerade nicht nachsehen, ob es eine neue Version gibt.")) }
            return
        }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard isNewer(version, than: Credits.version) else {
            if manual { tell(L("Mixtape ist auf dem neuesten Stand"), String(format: L("Du hast Version %@."), Credits.version)) }
            return
        }
        if !manual && UserDefaults.standard.string(forKey: "updateSkipped") == version { return }

        let a = NSAlert()
        a.messageText = String(format: L("Mixtape %@ ist da"), version)
        let notes = summary(release.body)
        a.informativeText = (notes.isEmpty ? "" : notes + "\n\n")
            + String(format: L("Du hast %@. Lade die neue Version, öffne sie und zieh Mixtape wieder auf „Programme“ – deine Kassetten bleiben, wo sie sind."), Credits.version)
        a.addButton(withTitle: L("Laden"))
        a.addButton(withTitle: L("Später"))
        if !manual { a.addButton(withTitle: L("Diese Version überspringen")) }
        NSApp.activate()
        switch a.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(download)
        case .alertThirdButtonReturn: UserDefaults.standard.set(version, forKey: "updateSkipped")
        default: break
        }
    }

    /// "0.4.10" is newer than "0.4.9".
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// The first paragraph of the release notes, without Markdown, links or pictures.
    nonisolated static func summary(_ body: String?) -> String {
        guard let body else { return "" }
        let first = body.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("<") } ?? ""
        var s = first.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        return s.count > 320 ? String(s.prefix(320)) + " …" : s
    }

    private static func tell(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate()
        a.runModal()
    }
}

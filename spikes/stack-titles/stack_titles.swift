// Stack-titles spike (backlog Story 10.18): group a jj repo's linear runs into stacks
// (Story 4.13's run rule) and title each stack with Apple's on-device model. Reads the
// repo only (`jj --ignore-working-copy`); nothing leaves the Mac. See README.md.
//
// Usage: stack-titles <repo> <out.md>

import Foundation
import FoundationModels

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: stack-titles <repo> <out.md>\n".utf8))
    exit(2)
}
let repo = args[1]
let outPath = args[2]
let repoName = URL(fileURLWithPath: repo).standardizedFileURL.lastPathComponent
let maxSubjects = 40

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func jj(_ a: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["jj", "--ignore-working-copy", "--no-pager", "--color=never", "-R", repo] + a
    let pipe = Pipe()
    p.standardOutput = pipe
    do { try p.run() } catch { log("jj failed: \(error)"); exit(1) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { log("jj exited \(p.terminationStatus)"); exit(1) }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Graph

struct Commit {
    let id: String
    let change: String
    let parents: [String]
    let hasRef: Bool
    let isWorkingCopy: Bool
    let immutable: Bool
    let isRoot: Bool
    let author: String
    let date: String
    let subject: String
    let order: Int  // position in `jj log`, 0 = top of the graph
}

let template = #"""
commit_id ++ "\t" ++ change_id.short(8) ++ "\t" ++ parents.map(|p| p.commit_id()).join(",") ++ "\t" ++ if(bookmarks, "B", "-") ++ if(tags, "T", "-") ++ if(current_working_copy, "W", "-") ++ if(working_copies, "w", "-") ++ if(immutable, "I", "-") ++ if(root, "R", "-") ++ "\t" ++ author.name() ++ "\t" ++ author.timestamp().format("%Y-%m-%d") ++ "\t" ++ description.first_line().escape_json() ++ "\n"
"""#

var commits: [String: Commit] = [:]
var logOrder: [String] = []
for line in jj(["log", "--no-graph", "-r", "all()", "-T", template]).split(separator: "\n") {
    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard f.count == 7 else { log("unparsed line: \(line)"); continue }
    let flags = f[3]
    let subject = (try? JSONSerialization.jsonObject(with: Data(f[6].utf8), options: .fragmentsAllowed)) as? String ?? f[6]
    let c = Commit(
        id: f[0], change: f[1], parents: f[2].isEmpty ? [] : f[2].split(separator: ",").map(String.init),
        hasRef: flags.contains("B") || flags.contains("T"),
        isWorkingCopy: flags.contains("W") || flags.contains("w"),
        immutable: flags.contains("I"), isRoot: flags.contains("R"),
        author: f[4], date: f[5], subject: subject, order: logOrder.count)
    commits[c.id] = c
    logOrder.append(c.id)
}
let defaultIds = jj(["log", "--no-graph", "-T", #"commit_id ++ "\n""#]).split(separator: "\n").map(String.init)
let workingCopy = jj(["log", "--no-graph", "-r", "@", "-T", "commit_id"]).trimmingCharacters(in: .whitespacesAndNewlines)

// Ancestors of @ (for the default state: runs of mutable ancestors of @ start expanded).
var ancestorsOfWC = Set<String>()
do {
    var todo = [workingCopy]
    while let x = todo.popLast() {
        guard ancestorsOfWC.insert(x).inserted, let c = commits[x] else { continue }
        todo.append(contentsOf: c.parents)
    }
}

struct Run {
    let members: [Commit]  // oldest first
    var newest: Commit { members.last! }
    var startsExpanded: Bool { members.allSatisfy { !$0.immutable && ancestorsOfWC.contains($0.id) } }
}

/// Layout edges of a revset: Direct to a parent in the set, Indirect to the nearest
/// ancestors in the set through elided commits (without jj's transitive pruning).
func edges(of set: Set<String>) -> [String: [(target: String, direct: Bool)]] {
    var out: [String: [(target: String, direct: Bool)]] = [:]
    for id in set {
        guard let c = commits[id] else { continue }
        var targets: [(target: String, direct: Bool)] = []
        for p in c.parents {
            if set.contains(p) { targets.append((p, true)); continue }
            var todo = [p], seen = Set<String>()
            while let x = todo.popLast() {
                guard seen.insert(x).inserted else { continue }
                if set.contains(x) { targets.append((x, false)); continue }
                todo.append(contentsOf: commits[x]?.parents ?? [])
            }
        }
        var uniq: [String: Bool] = [:]
        for t in targets { uniq[t.target] = (uniq[t.target] ?? false) || t.direct }
        out[id] = uniq.map { (target: $0.key, direct: $0.value) }
    }
    return out
}

/// Story 4.13 item 1 (the design's `groupStacks`, GV:228-246).
func stacks(of ids: [String]) -> [Run] {
    let set = Set(ids)
    let e = edges(of: set)
    var children: [String: [String]] = [:]
    for (child, ts) in e { for t in ts { children[t.target, default: []].append(child) } }
    func candidate(_ id: String) -> Bool {
        guard let c = commits[id], !c.isRoot, !c.isWorkingCopy, !c.hasRef, c.parents.count == 1 else { return false }
        guard let es = e[id], es.count == 1, es[0].direct else { return false }
        return children[id]?.count == 1
    }
    func next(_ id: String) -> String? {
        guard let k = children[id]?.first, candidate(k), commits[k]!.immutable == commits[id]!.immutable else { return nil }
        return k
    }
    var runs: [Run] = []
    for id in ids where candidate(id) {
        let p = commits[id]!.parents[0]
        if candidate(p), next(p) == id { continue }  // not the oldest member
        var m = [id]
        var x = id
        while let n = next(x) { m.append(n); x = n }
        if m.count >= 2 { runs.append(Run(members: m.map { commits[$0]! })) }
    }
    return runs.sorted { $0.newest.order < $1.newest.order }
}

let allRuns = stacks(of: logOrder)
let defaultRuns = stacks(of: defaultIds)
log("commits: \(logOrder.count), default revset: \(defaultIds.count), stacks all(): \(allRuns.count), stacks default: \(defaultRuns.count)")

// MARK: - Labels

let ticket = try! Regex(#"^\s*\[?([A-Z][A-Z0-9]+-\d+)\]?"#)
let conventional = try! Regex(#"^([a-z]+)(?:\(([^)]+)\))?!?:\s"#)
let area = try! Regex(#"^([A-Za-z0-9_./-]{1,24}):\s"#)

func token(_ subject: String) -> String? {
    if let m = subject.prefixMatch(of: ticket), let k = m.output[1].substring { return String(k) }
    if let m = subject.prefixMatch(of: conventional) {
        if let s = m.output[2].substring { return String(s) }
        if let t = m.output[1].substring { return String(t) }
    }
    if let m = subject.prefixMatch(of: area), let a = m.output[1].substring { return String(a) }
    return nil
}

/// The non-AI variant: the three most frequent ticket keys / scopes, newest first on ties.
func prefixLabel(_ run: Run) -> String? {
    var count: [String: Int] = [:]
    var firstSeen: [String: Int] = [:]
    for (i, c) in run.members.reversed().enumerated() {
        guard let t = token(c.subject) else { continue }
        count[t, default: 0] += 1
        if firstSeen[t] == nil { firstSeen[t] = i }
    }
    guard !count.isEmpty else { return nil }
    let ranked = count.keys.sorted { (count[$0]!, -firstSeen[$0]!) > (count[$1]!, -firstSeen[$1]!) }
    let shown = ranked.prefix(3).map { count[$0]! > 1 ? "\($0) ×\(count[$0]!)" : $0 }
    return shown.joined(separator: " · ") + (ranked.count > 3 ? " +\(ranked.count - 3)" : "")
}

@Generable
struct StackLabel {
    @Guide(description: "Label for the stack card: at most 6 words, concrete, no ticket keys, no quotes, no trailing period.")
    var title: String
    @Guide(description: "One or two sentences on what the stack contains.")
    var summary: String
}

let instructions = """
You label stacks in a version-control commit graph. A stack is a linear run of \
consecutive commits that the graph shows as one card. You get the commit subjects, \
newest first. Name what the commits do together: prefer concrete features, screens \
or components over generic words like updates, changes or fixes. Write in the \
language of the subjects. Never add details the subjects do not state.
"""

let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)

struct AIResult {
    let title: String?
    let summary: String?
    let seconds: Double
    let tokens: Int?
    let error: String?
}

var cache: [String: AIResult] = [:]

@MainActor
func title(_ run: Run) async -> AIResult? {
    let subjects = run.members.reversed().map(\.subject)
    guard subjects.contains(where: { !$0.isEmpty }) else { return nil }
    let shown = subjects.prefix(maxSubjects)
    var prompt = "Commit subjects of one stack, newest first (\(subjects.count) commits"
    if shown.count < subjects.count { prompt += ", the newest \(shown.count) shown" }
    prompt += "):\n" + shown.map { "- " + ($0.isEmpty ? "(no description)" : $0) }.joined(separator: "\n")
    if let hit = cache[prompt] { return hit }
    let tokens = try? await model.tokenCount(for: prompt)
    let session = LanguageModelSession(model: model, instructions: instructions)
    let t0 = Date()
    let result: AIResult
    do {
        let r = try await session.respond(
            to: prompt, generating: StackLabel.self,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 160))
        result = AIResult(title: r.content.title, summary: r.content.summary,
                          seconds: Date().timeIntervalSince(t0), tokens: tokens, error: nil)
    } catch {
        result = AIResult(title: nil, summary: nil, seconds: Date().timeIntervalSince(t0),
                          tokens: tokens, error: String(describing: error))
    }
    cache[prompt] = result
    return result
}

// MARK: - Run the model

guard model.isAvailable else { log("model unavailable: \(model.availability)"); exit(1) }
let coldStart: Double = await {
    let t0 = Date()
    _ = try? await LanguageModelSession(model: model).respond(to: "Say OK.")
    return Date().timeIntervalSince(t0)
}()
log(String(format: "cold start %.2f s", coldStart))

var results: [String: AIResult?] = [:]  // key: oldest member id + count
func key(_ r: Run) -> String { "\(r.members[0].id)/\(r.members.count)" }
let todo = defaultRuns + allRuns
let wall0 = Date()
for (i, r) in todo.enumerated() where results[key(r)] == nil {
    results[key(r)] = await title(r)
    if i % 10 == 0 { log("\(i + 1)/\(todo.count)") }
}
let wall = Date().timeIntervalSince(wall0)

// MARK: - Markdown

func md(_ s: String) -> String {
    var out = ""
    for ch in s {
        if "\\`*_[]<>|#~".contains(ch) { out.append("\\") }
        out.append(ch)
    }
    return out
}

func quantile(_ xs: [Double], _ q: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    return s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
}

func de(_ x: Double, _ digits: Int = 2) -> String {
    String(format: "%.\(digits)f", x).replacingOccurrences(of: ".", with: ",")
}

func stats(_ runs: [Run], revsetSize: Int) -> [String] {
    let rs = runs.compactMap { results[key($0)] ?? nil }
    let ok = rs.filter { $0.error == nil }
    let secs = ok.map(\.seconds)
    let toks = rs.compactMap(\.tokens).map(Double.init)
    let sizes = runs.map { Double($0.members.count) }
    return [
        "\(revsetSize)",
        "\(runs.count)",
        "\(runs.reduce(0) { $0 + $1.members.count })",
        runs.isEmpty ? "–" : "\(Int(sizes.min()!)) / \(Int(quantile(sizes, 0.5))) / \(Int(sizes.max()!))",
        "\(runs.filter(\.startsExpanded).count)",
        secs.isEmpty ? "–" : "\(de(quantile(secs, 0.5))) / \(de(quantile(secs, 0.9))) / \(de(secs.max()!)) s",
        toks.isEmpty ? "–" : "\(Int(quantile(toks, 0.5))) / \(Int(toks.max()!))",
        "\(rs.count - ok.count)",
    ]
}

func section(_ runs: [Run]) -> String {
    var s = ""
    for (i, r) in runs.enumerated() {
        let newest = r.newest, oldest = r.members[0]
        let authors = Array(NSOrderedSet(array: r.members.reversed().map { $0.author.split(separator: " ").first.map(String.init) ?? $0.author })) as! [String]
        let dates = oldest.date == newest.date ? newest.date : "\(oldest.date) – \(newest.date)"
        s += "\n### \(i + 1) · \(r.members.count) Commits · `\(newest.change)‥\(oldest.change)` · \(dates) · \(md(authors.joined(separator: ", ")))\n\n"
        s += "- **Karte heute:** \(newest.subject.isEmpty ? "*(no description set)*" : md(newest.subject))\n"
        s += "- **Präfix-Label:** \(prefixLabel(r).map(md) ?? "–")\n"
        let res = results[key(r)] ?? nil
        if let res {
            if let err = res.error {
                s += "- **KI:** Fehler: `\(err)`\n"
            } else {
                s += "- **KI-Titel:** \(md(res.title ?? ""))\n"
                s += "- **KI-Zusammenfassung:** \(md(res.summary ?? ""))\n"
            }
            var meta = ["\(de(res.seconds)) s"]
            if let t = res.tokens { meta.append("\(t) Tokens Eingabe") }
            if r.members.count > maxSubjects { meta.append("nur die jüngsten \(maxSubjects) Subjects im Prompt") }
            meta.append(newest.immutable ? "immutable" : "mutable")
            if r.startsExpanded { meta.append("startet aufgeklappt") }
            s += "- *\(meta.joined(separator: " · "))*\n"
        } else {
            s += "- **KI:** – (keine Beschreibungen)\n"
        }
        s += "\n  Mitglieder, neueste zuerst:\n\n"
        for c in r.members.reversed() {
            s += "  1. `\(c.change)` \(c.date) · \(md(c.author)) · \(c.subject.isEmpty ? "*(no description set)*" : md(c.subject))\n"
        }
    }
    return s
}

let now = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
let aStats = stats(defaultRuns, revsetSize: defaultIds.count)
let bStats = stats(allRuns, revsetSize: logOrder.count)
let rows = [
    "Commits im Revset", "Stapel (≥ 2 Mitglieder)", "Commits in Stapeln", "Stapelgröße min / Median / max",
    "davon starten aufgeklappt (mutable Vorfahren von @)", "KI-Dauer pro Stapel Median / p90 / max",
    "Eingabe-Tokens Median / max", "KI-Fehler",
]
var doc = """
# Stapel-Titel-Test · \(repoName)

*Erstellt \(now) auf diesem Mac (macOS \(ProcessInfo.processInfo.operatingSystemVersionString)) mit Apples On-Device-Modell \
(Foundation Models, Kontext \(model.contextSize) Tokens, greedy sampling, Guardrails `permissiveContentTransformations`). \
Nichts hat den Mac verlassen; das Repo wurde nur gelesen (`jj --ignore-working-copy`).*

## So liest man die Datei

Die Stapel folgen der Run-Regel aus Story 4.13 bzw. `groupStacks` im Design: Ein Commit ist Kandidat, wenn er nicht root \
und nicht @ ist, kein Bookmark und keinen Tag trägt, genau einen Elternteil hat, der im Revset liegt, und genau ein Kind. \
Ein Lauf solcher Kandidaten bricht an der immutable-Grenze; ab zwei Mitgliedern ist er ein Stapel.

Pro Stapel:
- **Karte heute:** was die Stapelkarte laut Design zeigt, das Subject des jüngsten Mitglieds.
- **Präfix-Label:** die Variante ohne KI; die häufigsten Ticket-Keys bzw. Conventional-Commit-Scopes.
- **KI-Titel:** der Vorschlag fürs Kartenlabel (höchstens etwa 6 Wörter).
- **KI-Zusammenfassung:** ein bis zwei Sätze, etwa für den Kopf des Popovers.
- Dauer des Modellaufrufs, Eingabe-Tokens, immutable/mutable, und ob der Stapel laut 4.13 aufgeklappt startet.

Darunter die Mitglieder, neueste zuerst. Die Standard-Ansicht rechnet elidierte Kanten ohne jjs transitive Vereinfachung; \
dort kann es daher etwas weniger Stapel geben als in Zanshin.

## Überblick

| | Standard-Ansicht (`jj log`) | Ganze Historie (`all()`) |
|---|---|---|

"""
for (i, name) in rows.enumerated() { doc += "| \(name) | \(aStats[i]) | \(bStats[i]) |\n" }
doc += "\nKaltstart des Modells: \(de(coldStart)) s. Alle Modellaufrufe zusammen: \(de(wall, 1)) s (gleiche Stapel in beiden Ansichten nur einmal gerechnet).\n"
doc += "\n## Standard-Ansicht (`jj log`)\n" + (defaultRuns.isEmpty ? "\nKeine Stapel.\n" : section(defaultRuns))
doc += "\n## Ganze Historie (`all()`), oben im Graph zuerst\n" + section(allRuns)

do {
    try doc.write(toFile: outPath, atomically: true, encoding: .utf8)
} catch {
    log("write failed: \(error)")
    exit(1)
}
log("wrote \(outPath)")

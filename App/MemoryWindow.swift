import AppKit
import KeybroKit
import SwiftUI

@MainActor
@Observable
final class MemoryViewModel {
    let store: MemoryStore
    var episodes: [Episode] = []
    var people: [PersonSummary] = []
    var graph = MemoryGraph(people: [], edges: [])
    var personEpisodes: [Episode] = []
    var personProfile: PersonProfile?
    var personFacts: [Fact] = []
    var personLoops: [OpenLoop] = []
    var asOf: Date?
    var loops: [OpenLoop] = []
    var digests: [(day: String, text: String)] = []
    var query = ""
    var error: String?

    init(store: MemoryStore) { self.store = store }

    func reload() {
        do {
            let q = query.trimmingCharacters(in: .whitespaces)
            episodes = q.isEmpty ? try store.recentEpisodes(limit: 300) : try store.search(q, limit: 100)
            people = try store.people()
            graph = try store.graph()
            loops = try store.allLoops()
            digests = try store.digests()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadPerson(_ id: Int64?) {
        guard let id else { personEpisodes = []; personProfile = nil; personFacts = []; personLoops = []; return }
        personEpisodes = ((try? store.episodes(forPerson: id, limit: 200)) ?? []).filter { e in asOf.map { e.createdAt <= $0 } ?? true }
        personProfile = asOf == nil ? try? store.profile(entityID: id) : nil
        // Now: every fact with replaced ones struck through. As of a date: only what was true then.
        personFacts = (asOf.map { try? store.facts(entityID: id, asOf: $0) } ?? (try? store.factHistory(entityID: id))) ?? []
        personLoops = (try? store.loops(entityID: id)) ?? []
    }

    func setLoop(_ loop: OpenLoop, _ status: OpenLoop.Status) {
        try? store.setLoop(loop.id!, status: status)
        reload()
    }

    func delete(_ episode: Episode) {
        guard let id = episode.id else { return }
        try? store.deleteEpisode(id: id)
        reload()
    }
}

struct MemoryWindowView: View {
    enum Section: String, CaseIterable, Identifiable {
        case timeline = "Timeline", people = "People", promises = "Promises", digests = "Digests", graph = "Graph"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .timeline: "clock"
            case .people: "person.2"
            case .promises: "checklist"
            case .digests: "newspaper"
            case .graph: "point.3.connected.trianglepath.dotted"
            }
        }
    }

    @Bindable var model: MemoryViewModel
    var services: MemoryServices?
    @State private var section: Section = .timeline
    @State private var selectedPerson: Int64?

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Group {
                switch section {
                case .timeline: timeline
                case .people: people
                case .promises: promises
                case .digests: digests
                case .graph: GraphView(graph: model.graph) { id in
                    selectedPerson = id
                    section = .people
                }
                }
            }
            .navigationTitle(section.rawValue)
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { model.reload() }
        .task {
            // New messages arrive in the background; keep the window current.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                model.reload()
                model.loadPerson(selectedPerson)
            }
        }
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            TextField("Search memory", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .onSubmit { model.reload() }
                .onChange(of: model.query) { model.reload() }
            if model.episodes.isEmpty {
                ContentUnavailableView(model.query.isEmpty ? "Nothing remembered yet" : "No matches",
                                       systemImage: "text.bubble",
                                       description: Text(model.query.isEmpty ? "Messages you send, fixes and generated replies show up here." : "Try other words."))
            } else {
                List {
                    ForEach(groupedByDay(model.episodes), id: \.0) { day, items in
                        SwiftUI.Section(day) {
                            ForEach(items, id: \.id) { episode in
                                EpisodeRow(episode: episode).contextMenu {
                                    Button("Delete", role: .destructive) { model.delete(episode) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var people: some View {
        HSplitView {
            List(model.people, selection: $selectedPerson) { person in
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.name).font(.headline)
                    Text("\(person.episodeCount) messages · \(person.surfaces.joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(person.id)
            }
            .frame(minWidth: 220, maxWidth: 300)
            Group {
                if selectedPerson == nil {
                    ContentUnavailableView("Pick someone", systemImage: "person.crop.circle")
                } else {
                    personDetail
                }
            }
            .frame(minWidth: 360)
        }
        .onChange(of: selectedPerson) { _, id in model.loadPerson(id) }
        .onAppear { model.loadPerson(selectedPerson) }
    }

    private var personDetail: some View {
        List {
            SwiftUI.Section {
                HStack {
                    Toggle("Look back to", isOn: Binding(
                        get: { model.asOf != nil },
                        set: { model.asOf = $0 ? Date().addingTimeInterval(-30 * 86_400) : nil; model.loadPerson(selectedPerson) }))
                    if let asOf = model.asOf {
                        DatePicker("", selection: Binding(get: { asOf }, set: { model.asOf = $0; model.loadPerson(selectedPerson) }),
                                   in: ...Date(), displayedComponents: .date)
                            .labelsHidden()
                    }
                }
                if let profile = model.personProfile {
                    Text(profile.summary)
                    if !profile.patterns.isEmpty {
                        Text(profile.patterns.split(separator: "\n").map { "• \($0)" }.joined(separator: "\n"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            if !model.personFacts.isEmpty {
                SwiftUI.Section(model.asOf == nil ? "Facts" : "True back then") {
                    ForEach(model.personFacts, id: \.id) { fact in
                        HStack {
                            Text("\(fact.predicate.replacingOccurrences(of: "_", with: " ")): \(fact.object)")
                                .strikethrough(model.asOf == nil && !fact.isCurrent)
                                .foregroundStyle(model.asOf == nil && !fact.isCurrent ? .secondary : .primary)
                            Spacer()
                            Text(fact.validTo.map { "until \($0.formatted(date: .abbreviated, time: .omitted))" }
                                 ?? "since \(fact.validFrom.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !model.personLoops.isEmpty {
                SwiftUI.Section("Promises") {
                    ForEach(model.personLoops) { LoopRow(loop: $0) { l, s in model.setLoop(l, s); model.loadPerson(selectedPerson) } }
                }
            }
            SwiftUI.Section("Messages") {
                ForEach(model.personEpisodes, id: \.id) { EpisodeRow(episode: $0) }
            }
        }
    }

    private var promises: some View {
        Group {
            if model.loops.isEmpty {
                ContentUnavailableView("No promises yet", systemImage: "checklist",
                                       description: Text("When you write things like \"I'll send it Friday\", the nightly update adds them here."))
            } else {
                List {
                    SwiftUI.Section("Open") {
                        ForEach(model.loops.filter { $0.status == .open }) { LoopRow(loop: $0) { l, s in model.setLoop(l, s) } }
                    }
                    SwiftUI.Section("Done") {
                        ForEach(model.loops.filter { $0.status != .open }) { LoopRow(loop: $0) { l, s in model.setLoop(l, s) } }
                    }
                }
            }
        }
        .toolbar {
            if let services {
                Button(services.running ? "Updating…" : "Update now") { Task { await services.runNow(); model.reload() } }
                    .disabled(services.running)
            }
        }
    }

    private var digests: some View {
        Group {
            if model.digests.isEmpty {
                ContentUnavailableView("No digests yet", systemImage: "newspaper",
                                       description: Text("A short summary of your day appears here after 9 PM."))
            } else {
                List(model.digests, id: \.day) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.day).font(.headline)
                        Text(item.text).textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func groupedByDay(_ episodes: [Episode]) -> [(String, [Episode])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.doesRelativeDateFormatting = true
        var order: [String] = []
        var groups: [String: [Episode]] = [:]
        for e in episodes {
            let key = formatter.string(from: e.createdAt)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(e)
        }
        return order.map { ($0, groups[$0]!) }
    }
}

struct EpisodeRow: View {
    var episode: Episode

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(episode.createdAt, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(label).font(.caption.weight(.semibold)).foregroundStyle(color)
                    Text(place).font(.caption).foregroundStyle(.secondary)
                }
                Text(episode.text).textSelection(.enabled).lineLimit(6)
            }
        }
        .padding(.vertical, 2)
    }

    private var place: String {
        [episode.appName ?? episode.surface, episode.contactRaw].compactMap { $0 }.joined(separator: " · ")
    }

    private var label: String {
        switch episode.kind {
        case .sent: "Sent"
        case .draft: "Draft"
        case .fix: "Fixed"
        case .generate: "Generated"
        case .note: "Note"
        }
    }

    private var color: Color {
        switch episode.kind {
        case .sent: .green
        case .draft: .secondary
        case .fix: .blue
        case .generate: .orange
        case .note: .purple
        }
    }
}

struct LoopRow: View {
    var loop: OpenLoop
    var set: (OpenLoop, OpenLoop.Status) -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: loop.status == .open ? "circle" : loop.status == .done ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(loop.status == .done ? .green : overdue ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(loop.text).strikethrough(loop.status != .open)
                Text([loop.person.map { "to \($0)" }, loop.dueAt.map { (overdue ? "was due " : "due ") + $0.formatted(date: .abbreviated, time: .omitted) }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(overdue ? .orange : .secondary)
            }
            Spacer()
            if loop.status == .open {
                Button("Done") { set(loop, .done) }
                Button("Drop") { set(loop, .dropped) }
            } else {
                Button("Reopen") { set(loop, .open) }
            }
        }
    }

    private var overdue: Bool { loop.status == .open && (loop.dueAt ?? .distantFuture) < Date() }
}

/// You in the middle, people around you. Bigger dot, more messages. Lines: they mention each other.
struct GraphView: View {
    var graph: MemoryGraph
    var onSelect: (Int64) -> Void

    var body: some View {
        GeometryReader { geo in
            let layout = positions(in: geo.size)
            ZStack {
                Canvas { context, _ in
                    let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    for (_, p) in layout {
                        var path = Path(); path.move(to: center); path.addLine(to: p)
                        context.stroke(path, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
                    }
                    for edge in graph.edges {
                        guard let a = layout[edge.from], let b = layout[edge.to] else { continue }
                        var path = Path(); path.move(to: a); path.addLine(to: b)
                        context.stroke(path, with: .color(.accentColor.opacity(0.6)), lineWidth: min(1 + CGFloat(edge.weight), 5))
                    }
                }
                Circle().fill(.primary).frame(width: 22, height: 22)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                Text("You").font(.caption.bold())
                    .position(x: geo.size.width / 2, y: geo.size.height / 2 + 22)
                ForEach(graph.people) { person in
                    if let p = layout[person.id] {
                        let size = 10 + min(CGFloat(person.episodeCount), 30)
                        Button { onSelect(person.id) } label: {
                            VStack(spacing: 4) {
                                Circle().fill(Color.accentColor).frame(width: size, height: size)
                                Text(person.name).font(.caption).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .position(p)
                    }
                }
                if graph.people.isEmpty {
                    ContentUnavailableView("No people yet", systemImage: "person.3",
                                           description: Text("People show up once keybro knows who you're talking to."))
                }
            }
        }
        .padding(24)
    }

    private func positions(in size: CGSize) -> [Int64: CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let people = graph.people.sorted { $0.episodeCount > $1.episodeCount }
        let radius = min(size.width, size.height) / 2 - 40
        var result: [Int64: CGPoint] = [:]
        for (i, person) in people.enumerated() {
            // Busier people sit closer to you.
            let r = radius * (0.55 + 0.45 * CGFloat(i) / CGFloat(max(people.count - 1, 1)))
            let angle = 2 * .pi * CGFloat(i) / CGFloat(max(people.count, 1)) - .pi / 2
            result[person.id] = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
        return result
    }
}

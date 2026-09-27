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
    var query = ""
    var error: String?

    init(store: MemoryStore) { self.store = store }

    func reload() {
        do {
            let q = query.trimmingCharacters(in: .whitespaces)
            episodes = q.isEmpty ? try store.recentEpisodes(limit: 300) : try store.search(q, limit: 100)
            people = try store.people()
            graph = try store.graph()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadPerson(_ id: Int64?) {
        personEpisodes = (id.flatMap { try? store.episodes(forPerson: $0, limit: 200) }) ?? []
    }

    func delete(_ episode: Episode) {
        guard let id = episode.id else { return }
        try? store.deleteEpisode(id: id)
        reload()
    }
}

struct MemoryWindowView: View {
    enum Section: String, CaseIterable, Identifiable {
        case timeline = "Timeline", people = "People", graph = "Graph"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .timeline: "clock"
            case .people: "person.2"
            case .graph: "point.3.connected.trianglepath.dotted"
            }
        }
    }

    @Bindable var model: MemoryViewModel
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
                    List(model.personEpisodes, id: \.id) { EpisodeRow(episode: $0) }
                }
            }
            .frame(minWidth: 360)
        }
        .onChange(of: selectedPerson) { _, id in model.loadPerson(id) }
        .onAppear { model.loadPerson(selectedPerson) }
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
        }
    }

    private var color: Color {
        switch episode.kind {
        case .sent: .green
        case .draft: .secondary
        case .fix: .blue
        case .generate: .orange
        }
    }
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

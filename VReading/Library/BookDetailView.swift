import SwiftUI
import Charts

/// 书籍详情
struct BookDetailView: View {
    enum Action { case read, dialysis, share, delete }
    let book: Book
    var onAction: (Action) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var store = LibraryStore.shared

    private var current: Book { store.books.first { $0.id == book.id } ?? book }

    private var fileSize: String {
        let size = (try? book.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var body: some View {
        let b = current
        let notes = AppDatabase.shared.notes(bookId: b.id).count
        let marks = AppDatabase.shared.bookmarks(bookId: b.id).count
        let words = VocabStore.shared.words.filter { $0.bookName == b.name }.count
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    HStack(alignment: .top, spacing: 16) {
                        BookCoverView(book: b).frame(width: 110)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(b.name).font(.title3.bold()).lineLimit(3)
                            if !b.author.isEmpty { Text(b.author).font(.subheadline).foregroundStyle(Color.accentGreen) }
                            Text("\(b.format.rawValue.uppercased()) · \(fileSize)").font(.caption).foregroundStyle(.secondary)
                            if b.addTime > 0 {
                                Text(String(localized: "Imported \(Date(timeIntervalSince1970: Double(b.addTime) / 1000).shortString)")).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                if b.isPinned { tag(String(localized: "Pin"), .orange) }
                                if b.isFinished { tag(String(localized: "Finished"), .accentGreen) }
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    VStack(spacing: 8) {
                        HStack {
                            Text(b.isFinished ? "Finished" : (b.lastRead == 0 ? "Unread" : "Read \(ReadingFormat.percent(b.progress))")).font(.subheadline.bold())
                            Spacer()
                            if b.lastRead > 0 { Text("Last read \(ReadingFormat.relative(b.lastRead))").font(.caption).foregroundStyle(.secondary) }
                        }
                        ProgressView(value: b.isFinished ? 1 : b.progress).tint(.accentGreen)
                    }

                    HStack {
                        stat(ReadingFormat.duration(b.readSeconds), String(localized: "Reading Time"))
                        Divider().frame(height: 30)
                        stat("\(notes)", String(localized: "Notes"))
                        Divider().frame(height: 30)
                        stat("\(marks)", String(localized: "Bookmarks"))
                        Divider().frame(height: 30)
                        stat("\(words)", String(localized: "Words"))
                    }
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                    Button { onAction(.read) } label: {
                        Text(b.lastRead > 0 ? "Continue Reading" : "Start Reading").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                            .foregroundStyle(.white).background(Color.accentGreen, in: RoundedRectangle(cornerRadius: 22))
                    }

                    VStack(spacing: 0) {
                        row(b.isPinned ? String(localized: "Unpin") : String(localized: "Pin"), "pin") { store.setPinned([b], !b.isPinned) }
                        Divider()
                        row(b.isFinished ? String(localized: "Mark as Unfinished") : String(localized: "Mark as Finished"), "checkmark.circle") { store.setFinished([b], !b.isFinished) }
                        if b.format != .pdf {
                            Divider()
                            row(String(localized: "Vocabulary Profile"), "chart.bar.doc.horizontal") { onAction(.dialysis) }
                        }
                        Divider()
                        row(String(localized: "Share Book"), "square.and.arrow.up") { onAction(.share) }
                        Divider()
                        row(String(localized: "Delete Book"), "trash", destructive: true) { onAction(.delete) }
                    }
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(20)
            }
            .navigationTitle("Book Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
        }
    }

    private func tag(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2).background(c, in: Capsule())
    }

    private func stat(_ v: String, _ t: String) -> some View {
        VStack(spacing: 4) {
            Text(v).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.6)
            Text(t).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ t: String, _ icon: String, destructive: Bool = false, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            HStack {
                Label(t, systemImage: icon).foregroundStyle(destructive ? Color.red : .primary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 阅读统计
struct ReadingStatsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var range = 7
    private var store: LibraryStore { LibraryStore.shared }

    var body: some View {
        let db = AppDatabase.shared
        let daily = db.dailyReading(days: range)
        let today = db.dailyReading(days: 1).first?.seconds ?? 0
        let rangeTotal = daily.reduce(0) { $0 + $1.seconds }
        let finished = store.books.filter(\.isFinished).count
        let ranking = store.books.filter { $0.readSeconds > 0 }.sorted { $0.readSeconds > $1.readSeconds }.prefix(10)
        NavigationStack {
            List {
                Section {
                    HStack {
                        stat(ReadingFormat.duration(today), String(localized: "Today"))
                        stat(ReadingFormat.duration(db.totalReadingSeconds), String(localized: "Total Time"))
                    }
                    HStack {
                        stat(String(localized: "\(db.readingDays) days"), String(localized: "Reading Days"))
                        stat(String(localized: "\(finished) books"), String(localized: "Finished"))
                    }
                }
                Section {
                    Picker("", selection: $range) {
                        Text("Last 7 Days").tag(7)
                        Text("Last 30 Days").tag(30)
                    }
                    .pickerStyle(.segmented)
                    Text("Total \(ReadingFormat.duration(rangeTotal)), daily average \(ReadingFormat.duration(rangeTotal / range))")
                        .font(.footnote).foregroundStyle(.secondary)
                    Chart(daily, id: \.day) { d in
                        BarMark(x: .value("Date", d.day, unit: .day), y: .value("Minutes", d.seconds / 60))
                            .foregroundStyle(Calendar.current.isDateInToday(d.day) ? Color.accentGreen : Color.accentGreen.opacity(0.45))
                            .cornerRadius(3)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: range == 7 ? 1 : 5)) { _ in
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                        }
                    }
                    .chartYAxisLabel("Minutes")
                    .frame(height: 180)
                } header: { Text("Reading Time") }
                if !ranking.isEmpty {
                    Section("Most Read") {
                        ForEach(Array(ranking.enumerated()), id: \.element.id) { i, b in
                            HStack(spacing: 12) {
                                Text("\(i + 1)").font(.headline).foregroundStyle(i < 3 ? Color.accentGreen : .secondary).frame(width: 22)
                                BookCoverView(book: b).frame(width: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(b.name).font(.subheadline).lineLimit(1)
                                    Text(b.isFinished ? "Finished" : "Read \(ReadingFormat.percent(b.progress))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(ReadingFormat.duration(b.readSeconds)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Reading Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "xmark") } } }
        }
    }

    private func stat(_ v: String, _ t: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(v).font(.title3.bold()).foregroundStyle(Color.accentGreen).lineLimit(1).minimumScaleFactor(0.6)
            Text(t).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

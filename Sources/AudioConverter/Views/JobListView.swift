import SwiftUI

struct JobListView: View {
    @EnvironmentObject var model: ConverterModel
    @State private var selection = Set<ConversionJob.ID>()

    private var showChapters: Bool {
        model.isM4BCombineMode
    }

    private var isCombine: Bool {
        model.isCombineMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(showChapters ? "Chapters (queue order)" : (isCombine ? "Parts (queue order)" : "Queue"))
                    .font(.headline)
                Spacer()
                Text("\(model.jobs.count) file\(model.jobs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if model.jobs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: showChapters ? "books.vertical" : (isCombine ? "square.stack.3d.up" : "music.note.list"))
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(showChapters ? "Add chapter audio files" : (isCombine ? "Add files to combine" : "No files yet"))
                        .foregroundStyle(.secondary)
                    if showChapters {
                        Text("Each file becomes one chapter in the M4B")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if isCombine {
                        Text("Each file is joined in order into one output")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(Array(model.jobs.enumerated()), id: \.element.id) { index, job in
                        JobRowView(
                            job: job,
                            partIndex: isCombine ? index + 1 : nil,
                            editableTitle: showChapters
                        )
                            .tag(job.id)
                            .contextMenu {
                                if isCombine {
                                    Button("Move Up") {
                                        model.moveJob(id: job.id, direction: -1)
                                    }
                                    .disabled(index == 0 || model.isConverting)
                                    Button("Move Down") {
                                        model.moveJob(id: job.id, direction: 1)
                                    }
                                    .disabled(index >= model.jobs.count - 1 || model.isConverting)
                                    Divider()
                                }
                                if case .succeeded = job.status, let out = job.outputURL {
                                    Button("Show Output in Finder") {
                                        model.revealInFinder(out)
                                    }
                                }
                                Button("Show Source in Finder") {
                                    model.revealInFinder(job.sourceURL)
                                }
                                Divider()
                                Button("Remove", role: .destructive) {
                                    model.removeJobs(ids: [job.id])
                                }
                                .disabled(job.status == .converting)
                            }
                    }
                    .onMove { source, dest in
                        model.moveJob(from: source, to: dest)
                    }
                    .onDelete { indexSet in
                        let ids = indexSet.map { model.jobs[$0].id }
                        model.removeJobs(ids: Set(ids))
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
    }
}

struct JobRowView: View {
    @ObservedObject var job: ConversionJob
    /// 1-based part/chapter number when combining.
    var partIndex: Int?
    /// When true (M4B combine), chapter title is editable.
    var editableTitle: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let partIndex {
                    Text("\(partIndex)")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                } else {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                        .frame(width: 16)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if editableTitle {
                        TextField("Chapter title", text: $job.chapterTitle)
                            .textFieldStyle(.plain)
                            .font(.body.weight(.medium))
                        Text(job.fileName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .help(job.sourceURL.path)
                    } else {
                        Text(job.fileName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .help(job.sourceURL.path)
                    }
                }
                Spacer()
                if let probe = job.probe {
                    Text(probe.durationDisplay)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                if job.probe != nil {
                    Text(job.queueDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if case .probing = job.status {
                    Text("Reading file…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if case .failed(let msg) = job.status {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Text(statusLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.15))
                    .foregroundStyle(statusColor)
                    .clipShape(Capsule())
            }

            if job.status == .converting {
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
            } else if case .succeeded = job.status {
                ProgressView(value: 1.0)
                    .progressViewStyle(.linear)
                    .tint(.green)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch job.status {
        case .pending, .ready: return "doc"
        case .probing: return "magnifyingglass"
        case .converting: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .pending, .ready: return .secondary
        case .probing: return .blue
        case .converting: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    private var statusLabel: String {
        switch job.status {
        case .converting:
            return "\(Int(job.progress * 100))%"
        default:
            return job.status.label
        }
    }
}

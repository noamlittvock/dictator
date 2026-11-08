import SwiftUI

struct RecentCommandsView: View {
    @State private var activity = CommandActivity.shared

    var body: some View {
        VStack(spacing: 0) {
            if !activity.records.isEmpty {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    HStack(spacing: DSSpace.xs) {
                        Text("Recent commands").font(.dsSection)
                        Spacer()
                        Button("Clear") { activity.clear() }
                            .buttonStyle(.dsQuiet)
                            .controlSize(.small)
                    }
                    ForEach(Array(activity.records.prefix(5))) { record in
                        HStack(spacing: DSSpace.xs) {
                            Text(record.commandName).font(.dsBodyMedium).lineLimit(1)
                            Text(record.trigger.activityLabel).foregroundStyle(Color.dsTextSecondary)
                            Spacer(minLength: 0)
                            Text(record.outcome.activityLabel)
                                .foregroundStyle(record.outcome == .failed ? Color.dsWarning : Color.dsTextSecondary)
                                .lineLimit(1)
                            Text(record.time, style: .time)
                                .foregroundStyle(Color.dsTextTertiary)
                        }
                        .font(.dsSecondary)
                        .help(record.failureTitle ?? record.outcome.activityLabel)
                    }
                }
                .dsPageFrame(.wide)
                .padding(.vertical, DSSpace.xs)
            }
        }
        .task { await activity.load() }
    }
}

extension VoiceCommandTrigger {
    var activityLabel: String {
        switch self {
        case .voice: "Voice"
        case .keyboard: "Keyboard"
        case .otherApp: "Other app"
        case .runAgain: "Run Again"
        }
    }
}

extension CommandActivityRecord.Outcome {
    var activityLabel: String {
        switch self {
        case .done: "Done"
        case .stopped: "Stopped"
        case .failed: "Failed"
        }
    }
}

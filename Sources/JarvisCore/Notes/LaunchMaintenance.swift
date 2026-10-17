import Foundation

/// The housekeeping run at launch and on each hourly tick: the 7-day transcript purge, then any
/// due roll-ups.
public struct LaunchMaintenance {
    private let transcripts: TranscriptStore
    private let rollups: RollupScheduler

    public init(transcripts: TranscriptStore, rollups: RollupScheduler) {
        self.transcripts = transcripts
        self.rollups = rollups
    }

    /// A failure in either step leaves that step for the next run and does not stop the other:
    /// the purge only deletes, and a roll-up that failed is still missing, so it is retried.
    public func run(now: Date) async {
        _ = try? transcripts.purge(olderThan: 7, now: now)
        try? await rollups.runIfDue(now: now)
    }
}

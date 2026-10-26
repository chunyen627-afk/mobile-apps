import Foundation

public extension MachineSnapshot {
    /// The source's judgment replaces the engine's light while the sample is fresh. When the
    /// source sends judgments but its latest sample is older than `maxAge`, the light is gray
    /// ("電腦端沒有回應") so a stale green is never shown. Without a judgment nothing changes,
    /// so older sources and the demo keep the engine's own rules.
    func applyingPublisherAssessment(maxAge: TimeInterval = 120) -> MachineSnapshot {
        guard let sample, let assessment = sample.assessment else { return self }
        let fresh = sampleAge.map { $0 <= maxAge } ?? false
        return MachineSnapshot(
            machineId: machineId, displayName: displayName, dataOrigin: dataOrigin,
            light: fresh ? assessment.light : .gray,
            reason: fresh ? .publisherAssessment(title: assessment.title, detail: assessment.reason) : .publisherSilent,
            problem: problem, sample: sample, sampleAge: sampleAge,
            isHistorical: fresh ? isHistorical : true,
            freshness: freshness, applicableStopReason: applicableStopReason)
    }
}

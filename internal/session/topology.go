package session

// DecideTopology determines the call topology based on participant count.
//
// Rules (Spec §3.3):
//   - 2 participants → P2P (ICE direct, falls back to TURN)
//   - >2 participants → SFU (LiveKit room)
func DecideTopology(participantCount int) Topology {
	if participantCount <= 2 {
		return TopologyP2P
	}
	return TopologySFU
}

// ShouldEscalateToSFU returns true if adding a participant requires
// switching from P2P/TURN to SFU.
func ShouldEscalateToSFU(currentTopology Topology, newParticipantCount int) bool {
	if currentTopology == TopologySFU {
		return false
	}
	return newParticipantCount > 2
}

// ShouldFallbackToTURN returns true when P2P ICE fails and TURN
// relay should be used.
func ShouldFallbackToTURN(currentTopology Topology, iceFailed bool) bool {
	return currentTopology == TopologyP2P && iceFailed
}

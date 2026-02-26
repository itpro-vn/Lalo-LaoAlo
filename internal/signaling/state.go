package signaling

import (
	"fmt"
	"sync"
)

// CallState represents the state of a call session.
type CallState string

const (
	StateIdle         CallState = "IDLE"
	StateRinging      CallState = "RINGING"
	StateConnecting   CallState = "CONNECTING"
	StateActive       CallState = "ACTIVE"
	StateReconnecting CallState = "RECONNECTING"
	StateEnded        CallState = "ENDED"
	StateCleanup      CallState = "CLEANUP"
)

// Valid state transitions: from → []to.
var validTransitions = map[CallState][]CallState{
	StateIdle:         {StateRinging},
	StateRinging:      {StateConnecting, StateEnded},
	StateConnecting:   {StateActive, StateEnded},
	StateActive:       {StateReconnecting, StateEnded},
	StateReconnecting: {StateActive, StateEnded},
	StateEnded:        {StateCleanup},
	StateCleanup:      {StateIdle},
}

// StateMachine manages call state transitions with thread safety.
type StateMachine struct {
	mu    sync.RWMutex
	state CallState
}

// NewStateMachine creates a state machine in IDLE state.
func NewStateMachine() *StateMachine {
	return &StateMachine{state: StateIdle}
}

// NewStateMachineFrom creates a state machine from an existing state (e.g. loaded from Redis).
func NewStateMachineFrom(s CallState) *StateMachine {
	return &StateMachine{state: s}
}

// State returns the current state.
func (sm *StateMachine) State() CallState {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return sm.state
}

// Transition attempts to move to the next state. Returns error if transition is invalid.
func (sm *StateMachine) Transition(to CallState) error {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	allowed, ok := validTransitions[sm.state]
	if !ok {
		return fmt.Errorf("no transitions from state %s", sm.state)
	}

	for _, s := range allowed {
		if s == to {
			sm.state = to
			return nil
		}
	}

	return fmt.Errorf("invalid transition: %s → %s", sm.state, to)
}

// CanTransition checks if a transition is valid without performing it.
func (sm *StateMachine) CanTransition(to CallState) bool {
	sm.mu.RLock()
	defer sm.mu.RUnlock()

	allowed, ok := validTransitions[sm.state]
	if !ok {
		return false
	}
	for _, s := range allowed {
		if s == to {
			return true
		}
	}
	return false
}

// IsTerminal returns true if the state is ENDED or CLEANUP.
func (sm *StateMachine) IsTerminal() bool {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return sm.state == StateEnded || sm.state == StateCleanup
}

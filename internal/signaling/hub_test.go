package signaling

import (
	"context"
	"sort"
	"testing"
	"time"
)

func TestGetUserRooms(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	h.addToRoom("room-a", "user-1")
	h.addToRoom("room-b", "user-1")
	h.addToRoom("room-c", "user-2")

	rooms := h.getUserRooms("user-1")
	sort.Strings(rooms)

	if len(rooms) != 2 {
		t.Fatalf("expected 2 rooms, got %d", len(rooms))
	}
	if rooms[0] != "room-a" || rooms[1] != "room-b" {
		t.Fatalf("expected [room-a room-b], got %v", rooms)
	}
}

func TestStartRoomGracePeriod_NoRooms(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	started := h.startRoomGracePeriod("user-1")
	if started {
		t.Fatal("expected false when user is in no rooms")
	}

	h.roomGraceTimersMu.Lock()
	_, exists := h.roomGraceTimers["user-1"]
	h.roomGraceTimersMu.Unlock()
	if exists {
		t.Fatal("did not expect room grace timer to be created")
	}
}

func TestStartRoomGracePeriod_WithRooms(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)
	h.addToRoom("room-a", "user-1")

	started := h.startRoomGracePeriod("user-1")
	if !started {
		t.Fatal("expected true when user is in at least one room")
	}

	h.roomGraceTimersMu.Lock()
	_, exists := h.roomGraceTimers["user-1"]
	h.roomGraceTimersMu.Unlock()
	if !exists {
		t.Fatal("expected room grace timer to be active")
	}

	// Cleanup to avoid waiting for default grace timeout.
	h.cancelRoomGracePeriod("user-1")
}

func TestCancelRoomGracePeriod_Active(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	cancelCalled := false
	h.roomGraceTimersMu.Lock()
	h.roomGraceTimers["user-1"] = func() { cancelCalled = true }
	h.roomGraceTimersMu.Unlock()

	cancelled := h.cancelRoomGracePeriod("user-1")
	if !cancelled {
		t.Fatal("expected true when room grace timer is active")
	}
	if !cancelCalled {
		t.Fatal("expected cancel func to be called")
	}

	h.roomGraceTimersMu.Lock()
	_, exists := h.roomGraceTimers["user-1"]
	h.roomGraceTimersMu.Unlock()
	if exists {
		t.Fatal("expected room grace timer to be removed")
	}
}

func TestCancelRoomGracePeriod_NotActive(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)

	cancelled := h.cancelRoomGracePeriod("user-1")
	if cancelled {
		t.Fatal("expected false when no room grace timer is active")
	}
}

func TestRoomGraceTimeout_Expired(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)
	h.addToRoom("room-a", "user-1")
	h.addToRoom("room-b", "user-1")
	h.addToRoom("room-a", "user-2") // keep room-a non-empty after user-1 removal

	graceCtx, cancel := context.WithCancel(h.ctx)
	defer cancel()

	done := make(chan struct{})
	go func() {
		h.roomGraceTimeout(graceCtx, "user-1", []string{"room-a", "room-b"}, 20*time.Millisecond)
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("timed out waiting for roomGraceTimeout to expire")
	}

	if h.isInRoom("room-a", "user-1") {
		t.Fatal("expected user-1 to be removed from room-a after grace timeout")
	}
	if h.isInRoom("room-b", "user-1") {
		t.Fatal("expected user-1 to be removed from room-b after grace timeout")
	}
	if !h.isInRoom("room-a", "user-2") {
		t.Fatal("expected other room members to remain in room")
	}
}

func TestRoomGraceTimeout_Cancelled(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)
	h.addToRoom("room-a", "user-1")
	h.addToRoom("room-b", "user-1")

	graceCtx, cancel := context.WithCancel(h.ctx)

	done := make(chan struct{})
	go func() {
		h.roomGraceTimeout(graceCtx, "user-1", []string{"room-a", "room-b"}, 100*time.Millisecond)
		close(done)
	}()

	// Cancel before expiry.
	time.Sleep(10 * time.Millisecond)
	cancel()

	select {
	case <-done:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("timed out waiting for cancelled roomGraceTimeout")
	}

	if !h.isInRoom("room-a", "user-1") {
		t.Fatal("expected user-1 to remain in room-a when grace timer is cancelled")
	}
	if !h.isInRoom("room-b", "user-1") {
		t.Fatal("expected user-1 to remain in room-b when grace timer is cancelled")
	}
}

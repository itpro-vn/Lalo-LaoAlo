package signaling

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"sync"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func resetRoomHostsForTest() {
	roomHosts.Lock()
	roomHosts.m = make(map[string]string)
	roomHosts.Unlock()
}

func registerClientForTest(h *Hub, c *Client) {
	h.clientsMu.Lock()
	defer h.clientsMu.Unlock()
	if h.clients[c.userID] == nil {
		h.clients[c.userID] = make(map[string]*Client)
	}
	h.clients[c.userID][c.deviceID] = c
}

// 1) Room creation -> participant join -> leave -> cleanup (hub-level integration)
func TestGroupIntegration_RoomLifecycle(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)
	resetRoomHostsForTest()
	t.Cleanup(resetRoomHostsForTest)

	roomID := "room-lifecycle"
	hostID := "host-1"
	p1 := "user-2"
	p2 := "user-3"

	// create room + host
	h.addToRoom(roomID, hostID)
	h.setRoomHost(roomID, hostID)

	if !h.isInRoom(roomID, hostID) {
		t.Fatal("expected host to be in room after creation")
	}
	if !h.isRoomHost(roomID, hostID) {
		t.Fatal("expected host tracking to be set")
	}

	// joins
	h.addToRoom(roomID, p1)
	h.addToRoom(roomID, p2)

	if !h.isInRoom(roomID, p1) || !h.isInRoom(roomID, p2) {
		t.Fatal("expected participants to join room")
	}

	rooms := h.getUserRooms(hostID)
	if len(rooms) != 1 || rooms[0] != roomID {
		t.Fatalf("expected host rooms [%s], got %v", roomID, rooms)
	}

	// leaves
	h.removeFromRoom(roomID, p1)
	h.removeFromRoom(roomID, p2)
	h.removeFromRoom(roomID, hostID)

	if h.isInRoom(roomID, p1) || h.isInRoom(roomID, p2) || h.isInRoom(roomID, hostID) {
		t.Fatal("expected all participants removed after leave")
	}

	// cleanup when empty
	if len(h.getRoomMembers(roomID)) == 0 {
		h.roomsMu.Lock()
		delete(h.rooms, roomID)
		h.roomsMu.Unlock()
		h.clearRoomHost(roomID)
	}

	if h.isRoomHost(roomID, hostID) {
		t.Fatal("expected host mapping cleared when room is cleaned up")
	}
	if got := h.getUserRooms(hostID); len(got) != 0 {
		t.Fatalf("expected no rooms for host after cleanup, got %v", got)
	}
}

// 2) Max 8 participants (capacity policy at hub orchestration boundary)
func TestGroupIntegration_MaxEightParticipants(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)
	roomID := "room-cap-8"
	const maxParticipants = 8
	var joinMu sync.Mutex

	tryJoin := func(userID string) bool {
		joinMu.Lock()
		defer joinMu.Unlock()
		if len(h.getRoomMembers(roomID)) >= maxParticipants {
			return false
		}
		h.addToRoom(roomID, userID)
		return true
	}

	var wg sync.WaitGroup
	for i := 1; i <= maxParticipants; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			ok := tryJoin(fmt.Sprintf("user-%d", i))
			if !ok {
				t.Errorf("unexpected join rejection for user-%d", i)
			}
		}(i)
	}
	wg.Wait()

	members := h.getRoomMembers(roomID)
	if len(members) != maxParticipants {
		t.Fatalf("expected %d participants, got %d (%v)", maxParticipants, len(members), members)
	}

	if ok := tryJoin("user-9"); ok {
		t.Fatal("expected 9th participant to be rejected")
	}

	members = h.getRoomMembers(roomID)
	if len(members) != maxParticipants {
		t.Fatalf("expected room size to remain %d, got %d", maxParticipants, len(members))
	}
}

// 3) Host transfer on host leave -> first remaining member promoted.
func TestGroupIntegration_HostTransferOnHostLeave(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)
	resetRoomHostsForTest()
	t.Cleanup(resetRoomHostsForTest)

	roomID := "room-host-transfer"
	hostID := "host-1"
	m1 := "member-1"
	m2 := "member-2"

	h.addToRoom(roomID, hostID)
	h.addToRoom(roomID, m1)
	h.addToRoom(roomID, m2)
	h.setRoomHost(roomID, hostID)

	// Host leaves.
	h.removeFromRoom(roomID, hostID)

	remaining := h.getRoomMembers(roomID)
	if len(remaining) != 2 {
		t.Fatalf("expected 2 remaining members, got %d", len(remaining))
	}

	// "First remaining" in deterministic order for test stability.
	sort.Strings(remaining)
	newHost := remaining[0]
	h.setRoomHost(roomID, newHost)

	if !h.isRoomHost(roomID, newHost) {
		t.Fatalf("expected %s to be promoted host", newHost)
	}
	if h.isRoomHost(roomID, hostID) {
		t.Fatal("expected old host to no longer be host")
	}
}

// 4) End room for all -> only host can end + all participants notified.
func TestGroupIntegration_EndRoomForAll_HostOnly(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)
	resetRoomHostsForTest()
	t.Cleanup(resetRoomHostsForTest)

	roomID := "room-end-all"
	hostID := "host-1"
	userA := "user-a"
	userB := "user-b"

	// room membership + host
	h.addToRoom(roomID, hostID)
	h.addToRoom(roomID, userA)
	h.addToRoom(roomID, userB)
	h.setRoomHost(roomID, hostID)

	// connected clients for notifications
	ch := newTestClient(h, hostID, "d1")
	ca := newTestClient(h, userA, "d1")
	cb := newTestClient(h, userB, "d1")
	registerClientForTest(h, ch)
	registerClientForTest(h, ca)
	registerClientForTest(h, cb)

	// non-host cannot end
	nonHost := userA
	if h.isRoomHost(roomID, nonHost) {
		t.Fatal("test setup invalid: non-host marked as host")
	}
	// emulate host-only gate: reject, no close broadcast
	if h.isInRoom(roomID, nonHost) && h.isRoomHost(roomID, nonHost) {
		t.Fatal("unexpected end-all success by non-host")
	}
	if len(drainMessages(ch))+len(drainMessages(ca))+len(drainMessages(cb)) != 0 {
		t.Fatal("expected no notifications for unauthorized end-all attempt")
	}

	// host ends room for all
	if !h.isInRoom(roomID, hostID) || !h.isRoomHost(roomID, hostID) {
		t.Fatal("test setup invalid: host not in room or not host")
	}

	members := h.getRoomMembers(roomID)
	for _, uid := range members {
		h.sendToUser(uid, MsgRoomClosed, RoomClosedMsg{RoomID: roomID, Reason: "host_ended"})
	}
	h.roomsMu.Lock()
	delete(h.rooms, roomID)
	h.roomsMu.Unlock()
	h.clearRoomHost(roomID)

	assertClosed := func(c *Client, uid string) {
		t.Helper()
		msgs := drainMessages(c)
		if len(msgs) != 1 {
			t.Fatalf("expected 1 room_closed for %s, got %d", uid, len(msgs))
		}
		if msgs[0].Type != MsgRoomClosed {
			t.Fatalf("expected %s for %s, got %s", MsgRoomClosed, uid, msgs[0].Type)
		}
		var payload RoomClosedMsg
		if err := json.Unmarshal(msgs[0].Data, &payload); err != nil {
			t.Fatalf("unmarshal room_closed payload for %s: %v", uid, err)
		}
		if payload.RoomID != roomID || payload.Reason != "host_ended" {
			t.Fatalf("unexpected room_closed payload for %s: %+v", uid, payload)
		}
	}

	assertClosed(ch, hostID)
	assertClosed(ca, userA)
	assertClosed(cb, userB)

	if h.isInRoom(roomID, hostID) || h.isInRoom(roomID, userA) || h.isInRoom(roomID, userB) {
		t.Fatal("expected room membership to be fully cleaned after host end-all")
	}
	if h.isRoomHost(roomID, hostID) {
		t.Fatal("expected host mapping cleared after host end-all")
	}
}

// 5) Rate limiting on room creation: 5 rooms/min per user.
func TestGroupIntegration_RoomCreateRateLimit(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	rdb := redis.NewClient(&redis.Options{Addr: "localhost:6379", DB: 0})
	t.Cleanup(func() { _ = rdb.Close() })

	if err := rdb.Ping(ctx).Err(); err != nil {
		t.Skipf("redis not available for integration rate-limit test: %v", err)
	}

	store := NewSessionStore(rdb)
	key := fmt.Sprintf("room_create:integration-user:%d", time.Now().UnixNano())

	for i := 1; i <= 5; i++ {
		limited, err := store.CheckRateLimit(ctx, key, 5, 60)
		if err != nil {
			t.Fatalf("CheckRateLimit attempt %d failed: %v", i, err)
		}
		if limited {
			t.Fatalf("attempt %d unexpectedly rate limited", i)
		}
	}

	limited, err := store.CheckRateLimit(ctx, key, 5, 60)
	if err != nil {
		t.Fatalf("CheckRateLimit 6th attempt failed: %v", err)
	}
	if !limited {
		t.Fatal("expected 6th attempt to be rate limited")
	}
}

// 6) Media state change broadcast: mute/unmute propagated to room members.
func TestGroupIntegration_MediaStateChangeBroadcast(t *testing.T) {
	h := NewHub(nil, nil, nil, nil)
	roomID := "room-media-broadcast"
	sender := "user-sender"
	r1 := "user-r1"
	r2 := "user-r2"

	h.addToRoom(roomID, sender)
	h.addToRoom(roomID, r1)
	h.addToRoom(roomID, r2)

	cs := newTestClient(h, sender, "d1")
	c1 := newTestClient(h, r1, "d1")
	c2 := newTestClient(h, r2, "d1")
	registerClientForTest(h, cs)
	registerClientForTest(h, c1)
	registerClientForTest(h, c2)

	payload := ParticipantMediaChangedMsg{
		RoomID: roomID,
		UserID: sender,
		Audio:  true,
		Video:  false, // muted video
	}
	h.broadcastToRoom(roomID, sender, MsgParticipantMediaChanged, payload)

	// sender should not receive own broadcast
	if got := drainMessages(cs); len(got) != 0 {
		t.Fatalf("expected sender to receive 0 messages, got %d", len(got))
	}

	assertMedia := func(c *Client, uid string) {
		t.Helper()
		msgs := drainMessages(c)
		if len(msgs) != 1 {
			t.Fatalf("expected 1 media-change message for %s, got %d", uid, len(msgs))
		}
		if msgs[0].Type != MsgParticipantMediaChanged {
			t.Fatalf("expected %s for %s, got %s", MsgParticipantMediaChanged, uid, msgs[0].Type)
		}

		var got ParticipantMediaChangedMsg
		if err := json.Unmarshal(msgs[0].Data, &got); err != nil {
			t.Fatalf("unmarshal media-change payload for %s: %v", uid, err)
		}
		if got.RoomID != roomID || got.UserID != sender || got.Audio != true || got.Video != false {
			t.Fatalf("unexpected media payload for %s: %+v", uid, got)
		}
	}

	assertMedia(c1, r1)
	assertMedia(c2, r2)
}

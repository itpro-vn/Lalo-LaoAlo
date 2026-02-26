package signaling

import (
	"encoding/json"
	"log"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	// Time allowed to write a message to the peer.
	writeWait = 10 * time.Second

	// Time allowed to read the next pong message from the peer.
	pongWait = 40 * time.Second // 30s ping + 10s grace

	// Send pings to peer with this period.
	pingPeriod = 30 * time.Second

	// Maximum message size allowed from peer.
	maxMessageSize = 8192

	// Send channel buffer size.
	sendBufSize = 64
)

// Client represents a WebSocket connection from a single user device.
type Client struct {
	hub      *Hub
	conn     *websocket.Conn
	send     chan []byte
	userID   string
	deviceID string
	closed   bool
	mu       sync.Mutex
}

// NewClient creates a new WebSocket client.
func NewClient(hub *Hub, conn *websocket.Conn, userID, deviceID string) *Client {
	return &Client{
		hub:      hub,
		conn:     conn,
		send:     make(chan []byte, sendBufSize),
		userID:   userID,
		deviceID: deviceID,
	}
}

// ReadPump reads messages from the WebSocket connection.
// It runs in its own goroutine per client.
func (c *Client) ReadPump() {
	defer func() {
		c.hub.unregister <- c
		c.Close()
	}()

	c.conn.SetReadLimit(maxMessageSize)
	c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		c.conn.SetReadDeadline(time.Now().Add(pongWait))
		return nil
	})

	for {
		_, message, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				log.Printf("ws read error user=%s: %v", c.userID, err)
			}
			return
		}

		c.hub.incoming <- &ClientMessage{
			client:  c,
			payload: message,
		}
	}
}

// WritePump writes messages to the WebSocket connection.
// It runs in its own goroutine per client.
func (c *Client) WritePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		c.Close()
	}()

	for {
		select {
		case message, ok := <-c.send:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				// Hub closed the channel.
				c.conn.WriteMessage(websocket.CloseMessage, nil)
				return
			}

			if err := c.conn.WriteMessage(websocket.TextMessage, message); err != nil {
				log.Printf("ws write error user=%s: %v", c.userID, err)
				return
			}

		case <-ticker.C:
			c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

// SendJSON marshals the message and sends it to the client.
func (c *Client) SendJSON(msgType string, data any) error {
	return c.SendJSONWithSeq(msgType, data, 0)
}

// SendJSONWithSeq marshals the message with a sequence number and sends it.
func (c *Client) SendJSONWithSeq(msgType string, data any, seq int64) error {
	payload, err := json.Marshal(data)
	if err != nil {
		return err
	}

	env := Envelope{
		Type: msgType,
		Data: payload,
		Seq:  seq,
	}

	msg, err := json.Marshal(env)
	if err != nil {
		return err
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed {
		return nil
	}

	select {
	case c.send <- msg:
	default:
		// Buffer full, drop message
		log.Printf("ws send buffer full for user=%s, dropping message", c.userID)
	}
	return nil
}

// SendError sends an error message to the client.
func (c *Client) SendError(code, message, callID string) {
	c.SendJSON(MsgError, ErrorMsg{
		Code:    code,
		Message: message,
		CallID:  callID,
	})
}

// Close closes the WebSocket connection.
func (c *Client) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.closed {
		return
	}
	c.closed = true
	close(c.send)
	c.conn.Close()
}

// ClientMessage is an incoming message from a client.
type ClientMessage struct {
	client  *Client
	payload []byte
}

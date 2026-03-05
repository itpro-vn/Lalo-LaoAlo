# Hướng dẫn Testing

## Tổng quan

Lalo sử dụng Go standard testing library với các tools bổ sung:

- **Race detector:** Phát hiện data races
- **Coverage:** Đo test coverage
- **golangci-lint:** Static analysis

---

## Chạy Tests

### Tất cả tests

```bash
# Full test suite với race detector & coverage
make test
# Tương đương: go test ./... -race -cover -count=1

# Quick tests (không race detector)
make test-short
# Tương đương: go test ./... -short
```

### Test package cụ thể

```bash
# Test một package
go test ./internal/session/... -v

# Test một test function
go test ./internal/signaling/... -run TestHandleCallInitiate -v

# Test với race detector
go test ./internal/session/... -race -v

# Test với coverage report
go test ./internal/... -coverprofile=coverage.out
go tool cover -html=coverage.out
```

---

## Cấu trúc Tests

Tests được đặt cùng thư mục với source code (colocated):

```
internal/
├── session/
│   ├── orchestrator.go
│   ├── orchestrator_test.go    # Tests cho orchestrator
│   ├── service.go
│   └── service_test.go         # Tests cho service
├── signaling/
│   ├── handler.go
│   ├── handler_test.go         # Tests cho handler
│   ├── flow.go
│   └── flow_test.go            # Tests cho call flow
└── push/
    ├── gateway.go
    ├── gateway_test.go          # Tests cho gateway
    └── ...
```

---

## Viết Tests

### Convention

```go
package session_test  // Hoặc package session cho internal tests

import (
    "testing"
)

// Test function name: Test<FunctionName>_<Scenario>
func TestCreateSession_Success(t *testing.T) {
    // Arrange
    // ...

    // Act
    result, err := service.CreateSession(ctx, req)

    // Assert
    if err != nil {
        t.Fatalf("unexpected error: %v", err)
    }
    if result.SessionID == "" {
        t.Error("expected non-empty session ID")
    }
}

func TestCreateSession_InvalidCalleeID(t *testing.T) {
    // ...
}
```

### Table-driven Tests

```go
func TestValidateCallType(t *testing.T) {
    tests := []struct {
        name     string
        callType string
        wantErr  bool
    }{
        {"valid 1:1", "1:1", false},
        {"valid group", "group", false},
        {"invalid empty", "", true},
        {"invalid unknown", "unknown", true},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            err := validateCallType(tt.callType)
            if (err != nil) != tt.wantErr {
                t.Errorf("validateCallType(%q) error = %v, wantErr %v",
                    tt.callType, err, tt.wantErr)
            }
        })
    }
}
```

### Mocking

Sử dụng interfaces cho dependency injection:

```go
// Interface
type SessionStore interface {
    Create(ctx context.Context, session *Session) error
    Get(ctx context.Context, id string) (*Session, error)
}

// Mock implementation
type mockSessionStore struct {
    sessions map[string]*Session
}

func (m *mockSessionStore) Create(ctx context.Context, s *Session) error {
    m.sessions[s.ID] = s
    return nil
}

func (m *mockSessionStore) Get(ctx context.Context, id string) (*Session, error) {
    s, ok := m.sessions[id]
    if !ok {
        return nil, ErrNotFound
    }
    return s, nil
}
```

---

## Test Categories

### Unit Tests

Test individual functions/methods:

```bash
go test ./internal/auth/... -v
go test ./internal/session/... -v
go test ./internal/signaling/... -v
go test ./internal/push/... -v
go test ./internal/abr/... -v
```

### Integration Tests

Test với dependencies thực (database, Redis, NATS):

```bash
# Cần infrastructure running
make run-local
go test ./internal/... -tags=integration -v
```

### TURN Connectivity Test

```bash
make test-turn
```

---

## CI Testing

GitHub Actions chạy trên mỗi PR:

```yaml
# .github/workflows/ci.yml
jobs:
  test:
    steps:
      - name: Lint
        run: golangci-lint run ./...

      - name: Test
        run: go test ./... -race -cover -count=1
```

---

## Coverage

### Tạo coverage report

```bash
# Generate coverage
go test ./... -coverprofile=coverage.out

# View trong terminal
go tool cover -func=coverage.out

# View trong browser
go tool cover -html=coverage.out -o coverage.html
open coverage.html
```

### Coverage targets

| Package              | Target |
| -------------------- | ------ |
| `internal/auth`      | 80%+   |
| `internal/session`   | 70%+   |
| `internal/signaling` | 70%+   |
| `internal/push`      | 70%+   |
| `internal/abr`       | 80%+   |
| `internal/events`    | 60%+   |

---

## Debugging Tests

### Verbose output

```bash
go test ./internal/session/... -v -run TestCreateSession
```

### Race condition detection

```bash
go test ./... -race -count=10
```

### Benchmark tests

```go
func BenchmarkPolicyEvaluate(b *testing.B) {
    engine := NewPolicyEngine(defaultConfig)
    samples := generateTestSamples(100)

    b.ResetTimer()
    for i := 0; i < b.N; i++ {
        engine.Evaluate(samples)
    }
}
```

```bash
go test ./internal/abr/... -bench=. -benchmem
```

---

## Test Fixtures

Test data và fixtures nằm trong `tests/`:

```
tests/
├── fixtures/
│   ├── call-config.yaml    # Test config
│   ├── sdp_offer.txt       # Sample SDP
│   └── ...
└── testdata/
    └── ...
```

Sử dụng trong tests:

```go
func TestParseSDP(t *testing.T) {
    data, err := os.ReadFile("../../tests/fixtures/sdp_offer.txt")
    if err != nil {
        t.Fatal(err)
    }
    // ...
}
```

.PHONY: build test lint fmt clean docker-build run-local tidy gen-certs

# Binary output directory
BIN_DIR := bin

# Services
SERVICES := signaling orchestrator policy push

# Go flags
GOFLAGS := -v
LDFLAGS := -s -w

## build: Build all service binaries
build: $(addprefix build-,$(SERVICES))

build-%:
	@echo "Building $*..."
	go build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o $(BIN_DIR)/$* ./cmd/$*/

## test: Run all tests
test:
	go test ./... -race -cover -count=1

## test-short: Run tests without race detector
test-short:
	go test ./... -short -count=1

## lint: Run golangci-lint
lint:
	golangci-lint run ./...

## fmt: Format code
fmt:
	gofmt -s -w .
	goimports -w .

## tidy: Tidy go modules
tidy:
	go mod tidy

## clean: Remove build artifacts
clean:
	rm -rf $(BIN_DIR)

## docker-build: Build Docker images for all services
docker-build: $(addprefix docker-build-,$(SERVICES)) docker-build-coturn docker-build-gateway

docker-build-%:
	docker build -t lalo-$*:latest -f deployments/Dockerfile.$* .

## docker-build-coturn: Build coturn Docker image
docker-build-coturn:
	docker build -t lalo-coturn:latest -f deployments/coturn/Dockerfile .

## docker-build-gateway: Build Nginx gateway image
docker-build-gateway:
	docker build -t lalo-gateway:latest -f deployments/nginx/Dockerfile .

## gen-certs: Generate self-signed TLS certificates for local dev
gen-certs:
	./scripts/gen-certs.sh

## run-local: Start local dependencies via docker-compose
run-local: gen-certs
	docker compose -f docker-compose.yml up -d

## stop-local: Stop local dependencies
stop-local:
	docker compose -f docker-compose.yml down

## test-turn: Test TURN server connectivity
test-turn:
	./scripts/test-turn.sh localhost 3478 lalo-turn-dev-secret

## migrate-up: Run Postgres migrations up
migrate-up:
	./scripts/migrate.sh up

## migrate-down: Rollback last Postgres migration
migrate-down:
	./scripts/migrate.sh down 1

## seed: Seed local database
seed:
	psql -U lalo -d lalo -f scripts/seed.sql

## help: Show this help
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## //' | column -t -s ':'

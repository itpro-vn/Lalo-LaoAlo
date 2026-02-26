// Package db provides database connection and migration helpers.
package db

import (
	"database/sql"
	"fmt"

	"github.com/minhgv/lalo/internal/config"
)

// NewPostgresConn creates a new PostgreSQL connection using the provided config.
func NewPostgresConn(cfg config.PostgresConfig) (*sql.DB, error) {
	db, err := sql.Open("postgres", cfg.DSN())
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}

	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping postgres: %w", err)
	}

	// Connection pool defaults
	db.SetMaxOpenConns(25)
	db.SetMaxIdleConns(5)

	return db, nil
}

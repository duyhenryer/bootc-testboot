package main

import (
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	ListenAddr     string
	LogLevel       string
	LogFormat      string
	LogFile        string
	WorkerMode     string
	MockDataCount  int
	MongoDBURI     string
	MongoDBName    string
	RabbitMQURI    string
	RabbitMQQueue  string
	ValkeyAddr     string
	ValkeyDB       int
}

func loadConfig() (*Config, error) {
	cfg := &Config{
		ListenAddr:    getEnv("LISTEN_ADDR", ":8001"),
		LogLevel:      getEnv("LOG_LEVEL", "info"),
		LogFormat:     getEnv("LOG_FORMAT", "text"),
		LogFile:       getEnv("LOG_FILE", ""),
		WorkerMode:    getEnv("WORKER_MODE", "seed"),
		MockDataCount: getEnvInt("MOCK_DATA_COUNT", 100),
		MongoDBURI:    getEnv("MONGODB_URI", "mongodb://localhost:27017"),
		MongoDBName:   getEnv("MONGODB_DB", "testboot_db"),
		RabbitMQURI:   getEnv("RABBITMQ_URI", "amqp://guest:guest@localhost:5672/"),
		RabbitMQQueue: getEnv("RABBITMQ_QUEUE", "worker_queue"),
		ValkeyAddr:    getEnv("VALKEY_ADDR", "localhost:6379"),
		ValkeyDB:      getEnvInt("VALKEY_DB", 0),
	}

	// Validate required config
	if cfg.MongoDBHost == "" {
		return nil, fmt.Errorf("MONGODB_HOST is required")
	}
	if cfg.RabbitMQHost == "" {
		return nil, fmt.Errorf("RABBITMQ_HOST is required")
	}
	if cfg.ValkeyAddr == "" {
		return nil, fmt.Errorf("VALKEY_ADDR is required")
	}

	return cfg, nil
}

func getEnv(key, defaultValue string) string {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}
	return strings.TrimSpace(value)
}

func getEnvInt(key string, defaultValue int) int {
	value := os.Getenv(key)
	if value == "" {
		return defaultValue
	}
	intVal, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil {
		return defaultValue
	}
	return intVal
}

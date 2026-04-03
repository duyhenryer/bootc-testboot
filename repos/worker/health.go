package main

import (
	"context"
)

// HealthCheck verifies connectivity to all services
func HealthCheck(ctx context.Context) (bool, map[string]string) {
	status := map[string]string{
		"mongodb":   "disconnected",
		"rabbitmq":  "disconnected",
		"valkey":    "disconnected",
	}

	// Check MongoDB
	if mongoMgr != nil && mongoMgr.collection != nil {
		status["mongodb"] = "connected"
	}

	// Check RabbitMQ
	if amqpMgr != nil {
		if st, err := amqpMgr.Status(ctx); err == nil {
			status["rabbitmq"] = st
		}
	}

	// Check Valkey
	if valkeyMgr != nil {
		if err := valkeyMgr.Ping(ctx); err == nil {
			status["valkey"] = "connected"
		}
	}

	allOk := status["mongodb"] == "connected" && status["rabbitmq"] == "connected" && status["valkey"] == "connected"
	return allOk, status
}

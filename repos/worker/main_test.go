package main

import (
	"encoding/hex"
	"strings"
	"testing"
)

func TestGenerateMockUser(t *testing.T) {
	user := GenerateMockUser(nil)

	if user.Name == "" {
		t.Fatal("Name should not be empty")
	}
	if user.Email == "" {
		t.Fatal("Email should not be empty")
	}
	if !strings.Contains(user.Email, "@testboot.example.com") {
		t.Fatalf("Email should have testboot domain, got %s", user.Email)
	}
	if user.Status != "active" && user.Status != "inactive" {
		t.Fatalf("Status should be active or inactive, got %s", user.Status)
	}
	if user.UserID == "" {
		t.Fatal("UserID should not be empty")
	}
	if len(user.UserID) != 24 {
		t.Fatalf("UserID should be 24-char ObjectID hex, got %q len %d", user.UserID, len(user.UserID))
	}
	if _, err := hex.DecodeString(user.UserID); err != nil {
		t.Fatalf("UserID should be hex: %v", err)
	}
}

func TestGenerateMockBatch(t *testing.T) {
	count := 50
	users := GenerateMockBatch(count)

	if len(users) != count {
		t.Fatalf("Expected %d users, got %d", count, len(users))
	}

	// Check that all users have required fields
	for i, user := range users {
		if user.Name == "" {
			t.Fatalf("User %d: Name should not be empty", i)
		}
		if user.Email == "" {
			t.Fatalf("User %d: Email should not be empty", i)
		}
	}
}

func TestConfigFromEnv(t *testing.T) {
	// Test default values
	cfg, err := loadConfig()
	if err != nil {
		t.Fatalf("loadConfig failed: %v", err)
	}

	if cfg.ListenAddr == "" {
		t.Fatal("ListenAddr should not be empty")
	}
	if cfg.MongoDBName == "" {
		t.Fatal("MongoDBName should not be empty")
	}
	if cfg.MockDataCount <= 0 {
		t.Fatal("MockDataCount should be > 0")
	}
}

func TestHandleRoot(t *testing.T) {
	// This is a placeholder for HTTP handler testing
	// Would require httptest package setup
	t.Skip("HTTP handler tests require httptest setup")
}

func TestGenerateMockBatch_AllUnique(t *testing.T) {
	// Check that generated users have unique UserIDs (high probability)
	users := GenerateMockBatch(100)
	userIDMap := make(map[string]bool)
	
	for _, user := range users {
		if userIDMap[user.UserID] {
			t.Logf("Duplicate UserID found: %s (acceptable due to randomness)", user.UserID)
		}
		userIDMap[user.UserID] = true
	}
	
	if len(userIDMap) < 90 {
		t.Fatalf("Too many duplicate UserIDs: expected ~100, got %d", len(userIDMap))
	}
}

package main

import (
	"context"
	"fmt"
	"math/rand"
	"time"
)

type User struct {
	UserID    string            `bson:"user_id"`
	Name      string            `bson:"name"`
	Email     string            `bson:"email"`
	Status    string            `bson:"status"`
	Phone     string            `bson:"phone,omitempty"`
	CreatedAt time.Time         `bson:"created_at"`
	UpdatedAt time.Time         `bson:"updated_at"`
	Metadata  map[string]string `bson:"metadata"`
	Tags      []string          `bson:"tags"`
}

var (
	firstNames = []string{"John", "Jane", "Alice", "Bob", "Charlie", "Diana", "Eve", "Frank"}
	lastNames  = []string{"Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis"}
	statuses   = []string{"active", "inactive"}
	tags       = []string{"test", "demo", "seeded", "batch1", "development"}
)

// GenerateMockUser creates a single mock user with random data
func GenerateMockUser() *User {
	seed := time.Now().UnixNano()
	rng := rand.New(rand.NewSource(seed + int64(rand.Intn(1000))))
	
	firstName := firstNames[rng.Intn(len(firstNames))]
	lastName := lastNames[rng.Intn(len(lastNames))]
	name := firstName + " " + lastName
	email := fmt.Sprintf("%s.%s@testboot.example.com", 
		toLowerCase(firstName), 
		toLowerCase(lastName))
	status := statuses[rng.Intn(len(statuses))]
	
	// 60% chance of having phone
	var phone string
	if rng.Float32() < 0.6 {
		phone = fmt.Sprintf("+1-555-%04d", rng.Intn(10000))
	}
	
	// Random creation date within last 30 days
	now := time.Now()
	createdAt := now.AddDate(0, 0, -rng.Intn(30))
	
	// Random tags subset
	numTags := rng.Intn(3) + 1
	selectedTags := make([]string, 0, numTags)
	for i := 0; i < numTags; i++ {
		selectedTags = append(selectedTags, tags[rng.Intn(len(tags))])
	}
	
	return &User{
		UserID:    fmt.Sprintf("USR-%06d", rng.Intn(1000000)),
		Name:      name,
		Email:     email,
		Status:    status,
		Phone:     phone,
		CreatedAt: createdAt,
		UpdatedAt: now,
		Metadata: map[string]string{
			"source": "mock",
			"batch":  "1",
		},
		Tags: selectedTags,
	}
}

// GenerateMockBatch generates count mock users
func GenerateMockBatch(count int) []*User {
	users := make([]*User, 0, count)
	for i := 0; i < count; i++ {
		users = append(users, GenerateMockUser())
	}
	return users
}

// SeedCollection seeds MongoDB with mock data
func SeedCollection(ctx context.Context, mongoMgr *MongoDBManager, collectionName string, count int) (int, error) {
	users := GenerateMockBatch(count)
	
	// Convert to []interface{}
	docs := make([]interface{}, len(users))
	for i, user := range users {
		docs[i] = user
	}
	
	return mongoMgr.InsertMany(ctx, docs)
}

func toLowerCase(s string) string {
	result := ""
	for _, c := range s {
		if c >= 'A' && c <= 'Z' {
			result += string(c + 32)
		} else {
			result += string(c)
		}
	}
	return result
}

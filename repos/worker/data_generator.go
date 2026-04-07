package main

import (
	"context"
	"fmt"
	"math/rand"
	"time"

	"go.mongodb.org/mongo-driver/bson/primitive"
)

// Default seed collections (parallel).
var DefaultSeedCollections = []string{"users", "orders", "events", "metrics"}

// Approximate average BSON size per document (with payload padding) for quota math.
const approxAvgDocBytes = 2600

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
	Payload   string            `bson:"payload"` // stabilizes size (~2KB)
}

// Order is a mock order document.
type Order struct {
	OrderID   string            `bson:"order_id"`
	Customer  string            `bson:"customer"`
	Amount    float64           `bson:"amount"`
	Currency  string            `bson:"currency"`
	Status    string            `bson:"status"`
	LineItems []string          `bson:"line_items"`
	CreatedAt time.Time         `bson:"created_at"`
	Metadata  map[string]string `bson:"metadata"`
	Payload   string            `bson:"payload"`
}

// Event is a mock event document.
type Event struct {
	EventID   string            `bson:"event_id"`
	Type      string            `bson:"type"`
	Source    string            `bson:"source"`
	Severity  string            `bson:"severity"`
	CreatedAt time.Time         `bson:"created_at"`
	Data      map[string]string `bson:"data"`
	Payload   string            `bson:"payload"`
}

// Metric is a mock metric document.
type Metric struct {
	MetricID   string            `bson:"metric_id"`
	Name       string            `bson:"name"`
	Value      float64           `bson:"value"`
	Unit       string            `bson:"unit"`
	Labels     map[string]string `bson:"labels"`
	RecordedAt time.Time         `bson:"recorded_at"`
	Payload    string            `bson:"payload"`
}

var (
	firstNames = []string{"John", "Jane", "Alice", "Bob", "Charlie", "Diana", "Eve", "Frank"}
	lastNames  = []string{"Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis"}
	statuses   = []string{"active", "inactive"}
	tags       = []string{"test", "demo", "seeded", "batch1", "development"}
	currencies = []string{"USD", "EUR", "VND"}
	evTypes    = []string{"login", "logout", "purchase", "error", "deploy"}
	evSources  = []string{"api", "worker", "nginx", "batch"}
	severities = []string{"info", "warn", "error"}
	metricNames = []string{"cpu_pct", "mem_pct", "req_rate", "latency_ms"}
	units      = []string{"percent", "bytes", "count", "ms"}
)

func fixedPadding(rng *rand.Rand, n int) string {
	const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, n)
	for i := range b {
		b[i] = alphabet[rng.Intn(len(alphabet))]
	}
	return string(b)
}

// GenerateMockUser creates a single mock user with unique user_id.
func GenerateMockUser(rng *rand.Rand) *User {
	if rng == nil {
		rng = rand.New(rand.NewSource(time.Now().UnixNano()))
	}

	firstName := firstNames[rng.Intn(len(firstNames))]
	lastName := lastNames[rng.Intn(len(lastNames))]
	name := firstName + " " + lastName
	email := fmt.Sprintf("%s.%s@testboot.example.com",
		toLowerCase(firstName),
		toLowerCase(lastName))
	status := statuses[rng.Intn(len(statuses))]

	var phone string
	if rng.Float32() < 0.6 {
		phone = fmt.Sprintf("+1-555-%04d", rng.Intn(10000))
	}

	now := time.Now().UTC()
	createdAt := now.AddDate(0, 0, -rng.Intn(30))

	numTags := rng.Intn(3) + 1
	selectedTags := make([]string, 0, numTags)
	for i := 0; i < numTags; i++ {
		selectedTags = append(selectedTags, tags[rng.Intn(len(tags))])
	}

	return &User{
		UserID:    primitive.NewObjectID().Hex(),
		Name:      name,
		Email:     email,
		Status:    status,
		Phone:     phone,
		CreatedAt: createdAt,
		UpdatedAt: now,
		Metadata: map[string]string{
			"source": "mock",
			"batch":  "seed",
		},
		Tags:    selectedTags,
		Payload: fixedPadding(rng, 2000),
	}
}

// GenerateMockOrder creates a mock order.
func GenerateMockOrder(rng *rand.Rand) *Order {
	if rng == nil {
		rng = rand.New(rand.NewSource(time.Now().UnixNano()))
	}
	now := time.Now().UTC()
	items := []string{
		fmt.Sprintf("SKU-%d", rng.Intn(10000)),
		fmt.Sprintf("SKU-%d", rng.Intn(10000)),
	}
	return &Order{
		OrderID:   primitive.NewObjectID().Hex(),
		Customer:  fmt.Sprintf("cust-%d", rng.Intn(1_000_000)),
		Amount:    float64(rng.Intn(100000)) / 100,
		Currency:  currencies[rng.Intn(len(currencies))],
		Status:    statuses[rng.Intn(len(statuses))],
		LineItems: items,
		CreatedAt: now,
		Metadata: map[string]string{
			"channel": "seed",
		},
		Payload: fixedPadding(rng, 2000),
	}
}

// GenerateMockEvent creates a mock event.
func GenerateMockEvent(rng *rand.Rand) *Event {
	if rng == nil {
		rng = rand.New(rand.NewSource(time.Now().UnixNano()))
	}
	now := time.Now().UTC()
	return &Event{
		EventID:   primitive.NewObjectID().Hex(),
		Type:      evTypes[rng.Intn(len(evTypes))],
		Source:    evSources[rng.Intn(len(evSources))],
		Severity:  severities[rng.Intn(len(severities))],
		CreatedAt: now,
		Data: map[string]string{
			"trace": fmt.Sprintf("tr-%d", rng.Int63()),
		},
		Payload: fixedPadding(rng, 2000),
	}
}

// GenerateMockMetric creates a mock metric.
func GenerateMockMetric(rng *rand.Rand) *Metric {
	if rng == nil {
		rng = rand.New(rand.NewSource(time.Now().UnixNano()))
	}
	now := time.Now().UTC()
	name := metricNames[rng.Intn(len(metricNames))]
	return &Metric{
		MetricID:   primitive.NewObjectID().Hex(),
		Name:       name,
		Value:      float64(rng.Intn(10000)) / 100,
		Unit:       units[rng.Intn(len(units))],
		Labels:     map[string]string{"env": "seed", "host": fmt.Sprintf("h-%d", rng.Intn(999))},
		RecordedAt: now,
		Payload:    fixedPadding(rng, 2000),
	}
}

// GenerateMockBatch generates count mock users (legacy / tests).
func GenerateMockBatch(count int) []*User {
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	users := make([]*User, 0, count)
	for i := 0; i < count; i++ {
		users = append(users, GenerateMockUser(rng))
	}
	return users
}

// SeedCollectionUsers inserts only into users (legacy small seeds).
func SeedCollectionUsers(ctx context.Context, mongoMgr *MongoDBManager, count int) (int, error) {
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	var total int
	batchSize := 500
	for i := 0; i < count; i += batchSize {
		n := batchSize
		if i+n > count {
			n = count - i
		}
		docs := make([]interface{}, n)
		for j := 0; j < n; j++ {
			docs[j] = GenerateMockUser(rng)
		}
		inserted, err := mongoMgr.InsertMany(ctx, "users", docs)
		if err != nil {
			return total, err
		}
		total += inserted
	}
	return total, nil
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

package admission

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
)

var (
	testSecret = []byte("runner-test-secret-that-is-at-least-32-bytes")
	testNow    = time.Date(2026, 8, 24, 12, 0, 0, 123_000_000, time.UTC)
)

func TestAuthenticatedAdmissionIsDurablyIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "admissions.json")
	store, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	handler, err := NewHandler(testSecret, store, func() time.Time { return testNow })
	if err != nil {
		t.Fatal(err)
	}
	body := admissionFixture(t)

	first := serveAdmission(t, handler, body, testNow, testSecret)
	if first.Code != http.StatusAccepted {
		t.Fatalf("expected 202, got %d: %s", first.Code, first.Body.String())
	}
	var accepted protocol.AdmissionResponse
	if err := json.Unmarshal(first.Body.Bytes(), &accepted); err != nil {
		t.Fatal(err)
	}
	if accepted.Status != "accepted" || accepted.Event.Sequence != 1 || accepted.Event.EventType != "run.admitted" {
		t.Fatalf("unexpected response: %#v", accepted)
	}
	if accepted.Event.ProtocolVersion != protocol.Version || accepted.Event.RunID != accepted.RunID ||
		accepted.Event.EventID == "" || accepted.Event.Data["task_key"] == nil {
		t.Fatalf("incomplete canonical event: %#v", accepted.Event)
	}

	replay := serveAdmission(t, handler, body, testNow.Add(time.Minute), testSecret)
	if replay.Code != http.StatusAccepted || replay.Header().Get("X-NavishAI-Idempotent-Replay") != "true" {
		t.Fatalf("expected an idempotent replay, got %d", replay.Code)
	}
	if replay.Body.String() != first.Body.String() {
		t.Fatal("replay must return the original canonical event")
	}

	reopened, err := OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	restarted, err := NewHandler(testSecret, reopened, func() time.Time { return testNow.Add(2 * time.Minute) })
	if err != nil {
		t.Fatal(err)
	}
	afterRestart := serveAdmission(t, restarted, body, testNow.Add(2*time.Minute), testSecret)
	if afterRestart.Code != http.StatusAccepted || afterRestart.Body.String() != first.Body.String() {
		t.Fatal("restart must preserve admission idempotency")
	}
	if info, err := os.Stat(path); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("admission state must be mode 0600: info=%v err=%v", info, err)
	}
}

func TestAdmissionRejectsConflictAuthenticationAndBounds(t *testing.T) {
	store, _ := OpenStore("")
	handler, _ := NewHandler(testSecret, store, func() time.Time { return testNow })
	body := admissionFixture(t)
	if response := serveAdmission(t, handler, body, testNow, testSecret); response.Code != http.StatusAccepted {
		t.Fatalf("initial admission failed: %d", response.Code)
	}

	changed := bytes.Replace(body, []byte("3d07f334-88ef-4fe4-a640-421e3ba79921"), []byte("8e74b9af-98d7-4cbf-9dc9-d994fd5b8d46"), 1)
	if response := serveAdmission(t, handler, changed, testNow, testSecret); response.Code != http.StatusConflict {
		t.Fatalf("expected conflict, got %d", response.Code)
	}
	if response := serveAdmission(t, handler, body, testNow, []byte("different-secret-that-is-at-least-32-bytes")); response.Code != http.StatusUnauthorized {
		t.Fatalf("expected bad signature rejection, got %d", response.Code)
	}
	wrongType := httptest.NewRequest(http.MethodPost, protocol.AdmissionPath, bytes.NewReader(body))
	timestamp := strconv.FormatInt(testNow.Unix(), 10)
	signature, _ := protocol.Sign(testSecret, timestamp, wrongType.Method, wrongType.URL.Path, body)
	wrongType.Header.Set("Content-Type", "text/plain")
	wrongType.Header.Set("X-NavishAI-Timestamp", timestamp)
	wrongType.Header.Set("X-NavishAI-Signature", signature)
	wrongTypeResponse := httptest.NewRecorder()
	handler.ServeHTTP(wrongTypeResponse, wrongType)
	if wrongTypeResponse.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("expected content type rejection, got %d", wrongTypeResponse.Code)
	}
	if response := serveAdmission(t, handler, body, testNow.Add(-protocol.MaximumSkew-time.Second), testSecret); response.Code != http.StatusUnauthorized {
		t.Fatalf("expected stale timestamp rejection, got %d", response.Code)
	}

	oversized := httptest.NewRequest(http.MethodPost, protocol.AdmissionPath, strings.NewReader(strings.Repeat("x", protocol.MaxBodyBytes+1)))
	oversized.Header.Set("X-NavishAI-Timestamp", "0")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, oversized)
	if response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected oversized rejection, got %d", response.Code)
	}
	chunked := httptest.NewRequest(http.MethodPost, protocol.AdmissionPath, strings.NewReader(strings.Repeat("x", protocol.MaxBodyBytes+1)))
	chunked.ContentLength = -1
	chunkedResponse := httptest.NewRecorder()
	handler.ServeHTTP(chunkedResponse, chunked)
	if chunkedResponse.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected chunked oversized rejection, got %d", chunkedResponse.Code)
	}

	malformed := []byte(`{"protocol_version":"v1"}`)
	if response := serveAdmission(t, handler, malformed, testNow, testSecret); response.Code != http.StatusUnprocessableEntity {
		t.Fatalf("expected signed malformed request rejection, got %d", response.Code)
	}
	retainedV1 := bytes.Replace(body, []byte(`"protocol_version": "v2"`), []byte(`"protocol_version": "v1"`), 1)
	if response := serveAdmission(t, handler, retainedV1, testNow, testSecret); response.Code != http.StatusUnprocessableEntity {
		t.Fatalf("expected retained v1 request rejection, got %d", response.Code)
	}
}

func TestConcurrentReplayReturnsOneCanonicalAdmission(t *testing.T) {
	store, _ := OpenStore("")
	handler, _ := NewHandler(testSecret, store, func() time.Time { return testNow })
	body := admissionFixture(t)
	const workers = 12
	responses := make(chan string, workers)
	errors := make(chan int, workers)
	var wait sync.WaitGroup
	for range workers {
		wait.Add(1)
		go func() {
			defer wait.Done()
			response := serveAdmission(t, handler, body, testNow, testSecret)
			if response.Code != http.StatusAccepted {
				errors <- response.Code
				return
			}
			responses <- response.Body.String()
		}()
	}
	wait.Wait()
	close(responses)
	close(errors)
	if len(errors) != 0 {
		t.Fatalf("concurrent admission returned status %d", <-errors)
	}
	var canonical string
	for body := range responses {
		if canonical == "" {
			canonical = body
		}
		if body != canonical {
			t.Fatal("concurrent replay returned different canonical events")
		}
	}
}

func serveAdmission(t *testing.T, handler http.Handler, body []byte, at time.Time, secret []byte) *httptest.ResponseRecorder {
	return serveAdmissionAt(t, handler, protocol.AdmissionPath, body, at, secret)
}

func serveAdmissionAt(t *testing.T, handler http.Handler, path string, body []byte, at time.Time, secret []byte) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, path, bytes.NewReader(body))
	timestamp := strconv.FormatInt(at.Unix(), 10)
	signature, err := protocol.Sign(secret, timestamp, request.Method, request.URL.Path, body)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-NavishAI-Timestamp", timestamp)
	request.Header.Set("X-NavishAI-Signature", signature)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func admissionFixture(t *testing.T) []byte {
	t.Helper()
	path := filepath.Join("..", "..", "..", "test", "fixtures", "files", "runner_protocol", "v2", "admission_request.json")
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return body
}

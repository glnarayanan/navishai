package protocol

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAdmissionContractFixture(t *testing.T) {
	body := readFixture(t, "admission_request.json")
	request, decodedBody, err := DecodeAdmission(strings.NewReader(string(body)))
	if err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	if string(decodedBody) != string(body) {
		t.Fatal("decoder did not retain the exact signed bytes")
	}
	if request.ProtocolVersion != Version || request.Task.Attempt != 1 || request.Agent.RoleKey != "support_investigator" {
		t.Fatalf("unexpected fixture decode: %#v", request)
	}
	if request.Agent.AllowedTools[2] != "knowledge_search" || request.Agent.MaxToolCalls != 20 {
		t.Fatalf("unexpected policy decode: %#v", request.Agent)
	}
}

func TestAdmissionRejectsUnknownAndOutOfBoundsFields(t *testing.T) {
	body := readFixture(t, "admission_request.json")
	unknown := strings.Replace(string(body), `"protocol_version": "v1"`, `"protocol_version": "v1", "provider": "arbitrary"`, 1)
	if _, _, err := DecodeAdmission(strings.NewReader(unknown)); err == nil {
		t.Fatal("expected an unknown field to fail")
	}
	oversized := strings.Replace(string(body), `"max_steps": 10`, `"max_steps": 21`, 1)
	if _, _, err := DecodeAdmission(strings.NewReader(oversized)); err == nil {
		t.Fatal("expected an out-of-bounds policy to fail")
	}
	duplicateTool := strings.Replace(string(body), `"case_read", "conversation_read"`, `"case_read", "case_read"`, 1)
	if _, _, err := DecodeAdmission(strings.NewReader(duplicateTool)); err == nil {
		t.Fatal("expected duplicate tools to fail")
	}
	var request AdmissionRequest
	if err := json.Unmarshal(body, &request); err != nil {
		t.Fatal(err)
	}
	request.Task.InputContext = strings.Repeat("x", 128*1024)
	bounded, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := DecodeAdmission(strings.NewReader(string(bounded))); err != nil {
		t.Fatalf("expected 128 KiB context to pass: %v", err)
	}
	request.Task.InputContext += "x"
	tooLarge, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := DecodeAdmission(strings.NewReader(string(tooLarge))); err == nil {
		t.Fatal("expected context over 128 KiB to fail")
	}
}

func TestSharedSignatureVector(t *testing.T) {
	var vector struct {
		Secret    string `json:"secret"`
		Timestamp string `json:"timestamp"`
		Method    string `json:"method"`
		Path      string `json:"path"`
		Body      string `json:"body"`
		Signature string `json:"signature"`
	}
	if err := json.Unmarshal(readFixture(t, "signature_vector.json"), &vector); err != nil {
		t.Fatal(err)
	}
	signature, err := Sign([]byte(vector.Secret), vector.Timestamp, vector.Method, vector.Path, []byte(vector.Body))
	if err != nil {
		t.Fatal(err)
	}
	if signature != vector.Signature {
		t.Fatalf("expected signature %s, got %s", vector.Signature, signature)
	}
	if !Verify([]byte(vector.Secret), vector.Timestamp, vector.Method, vector.Path, []byte(vector.Body), signature) {
		t.Fatal("expected vector signature to verify")
	}
	if Verify([]byte(vector.Secret), vector.Timestamp, vector.Method, vector.Path, []byte(vector.Body+" "), signature) {
		t.Fatal("changed body must not verify")
	}
}

func TestCanonicalEventValidationIsStrict(t *testing.T) {
	event, err := NewCanonicalEvent(
		"3d07f334-88ef-4fe4-a640-421e3ba79921", 2, "run.started", time.Now(),
		map[string]any{"adapter": "scripted", "scenario": "success", "attempt": 1},
	)
	if err != nil || event.Validate() != nil {
		t.Fatalf("expected canonical event, event=%#v err=%v", event, err)
	}
	event.Data["unexpected"] = true
	if event.Validate() == nil {
		t.Fatal("expected unknown event data to fail")
	}
}

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	path := filepath.Join("..", "..", "..", "test", "fixtures", "files", "runner_protocol", "v1", name)
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture %s: %v", path, err)
	}
	return body
}

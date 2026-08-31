package scripted

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

const (
	maxFixtureBytes = 256 * 1024
	maxAttempts     = 10
	maxToolCalls    = 20
	maxOutputBytes  = 100 * 1024
)

var ErrInvalidScript = errors.New("invalid scripted adapter fixture")

type Script struct {
	Scenario string    `json:"scenario"`
	Attempts []Attempt `json:"attempts"`
}

type Attempt struct {
	Number      int      `json:"number"`
	Result      string   `json:"result"`
	DelayMillis int      `json:"delay_millis"`
	ToolCalls   []string `json:"tool_calls"`
	OutputJSON  string   `json:"output_json"`
	Usage       Usage    `json:"usage"`
}

type Usage struct {
	InputUnits  int `json:"input_units"`
	OutputUnits int `json:"output_units"`
}

type Output struct {
	Text string `json:"text"`
}

func Load(path string) (Script, error) {
	body, err := ReadFixture(path)
	if err != nil {
		return Script{}, fmt.Errorf("open script: %w", err)
	}
	return Decode(bytes.NewReader(body))
}

// ReadFixture returns one bounded snapshot of a scripted fixture. Callers
// that need both its digest and parsed form can use this snapshot for both
// operations without reopening a mutable path.
func ReadFixture(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	body, err := io.ReadAll(io.LimitReader(file, maxFixtureBytes+1))
	if err != nil || len(body) > maxFixtureBytes {
		return nil, ErrInvalidScript
	}
	return body, nil
}

func Decode(reader io.Reader) (Script, error) {
	body, err := io.ReadAll(io.LimitReader(reader, maxFixtureBytes+1))
	if err != nil || len(body) > maxFixtureBytes {
		return Script{}, ErrInvalidScript
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	var script Script
	if err := decoder.Decode(&script); err != nil {
		return Script{}, ErrInvalidScript
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) || script.validate() != nil {
		return Script{}, ErrInvalidScript
	}
	return script, nil
}

func (script Script) attempt(number int) (Attempt, bool) {
	for _, attempt := range script.Attempts {
		if attempt.Number == number {
			return attempt, true
		}
	}
	return Attempt{}, false
}

func (script Script) validate() error {
	if strings.TrimSpace(script.Scenario) == "" || len(script.Scenario) > 100 || len(script.Attempts) == 0 || len(script.Attempts) > maxAttempts {
		return ErrInvalidScript
	}
	seen := make(map[int]struct{}, len(script.Attempts))
	for _, attempt := range script.Attempts {
		if attempt.Number < 1 || attempt.Number > 100 || attempt.DelayMillis < 0 || attempt.DelayMillis > int((10*time.Second)/time.Millisecond) ||
			len(attempt.ToolCalls) > maxToolCalls || attempt.Usage.InputUnits < 0 || attempt.Usage.OutputUnits < 0 {
			return ErrInvalidScript
		}
		if _, exists := seen[attempt.Number]; exists {
			return ErrInvalidScript
		}
		seen[attempt.Number] = struct{}{}
		tools := make(map[string]struct{}, len(attempt.ToolCalls))
		for _, tool := range attempt.ToolCalls {
			if strings.TrimSpace(tool) == "" || len(tool) > 64 {
				return ErrInvalidScript
			}
			if _, exists := tools[tool]; exists {
				return ErrInvalidScript
			}
			tools[tool] = struct{}{}
		}
		switch attempt.Result {
		case "success":
			if attempt.OutputJSON == "" || len(attempt.OutputJSON) > maxOutputBytes {
				return ErrInvalidScript
			}
		case "retryable_error", "wait":
			if attempt.OutputJSON != "" || (attempt.Result == "wait" && attempt.DelayMillis == 0) {
				return ErrInvalidScript
			}
		default:
			return ErrInvalidScript
		}
	}
	return nil
}

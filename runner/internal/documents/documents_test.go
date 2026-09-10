package documents

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/protocol"
	"github.com/glnarayanan/navishai/runner/internal/supervisor"
)

type fixtureProcess struct {
	run func(supervisor.Request) (supervisor.Result, error)
}

func (p fixtureProcess) Run(_ context.Context, r supervisor.Request) (supervisor.Result, error) {
	return p.run(r)
}

type extractorFunc func(context.Context, []byte) ([]byte, error)

func (f extractorFunc) Extract(ctx context.Context, b []byte) ([]byte, error) { return f(ctx, b) }

var secret = []byte("01234567890123456789012345678901")

func validRequest() Request {
	digest := sha256.Sum256(compoundSignature)
	return Request{"v1", "11111111-1111-4111-8111-111111111111", hex.EncodeToString(digest[:]), "doc", base64.StdEncoding.EncodeToString(compoundSignature)}
}
func serve(t *testing.T, h *Handler, body []byte, signed bool) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest("POST", Path, bytes.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if signed {
		timestamp := strconv.FormatInt(time.Now().Unix(), 10)
		signature, _ := protocol.Sign(secret, timestamp, "POST", Path, body)
		r.Header.Set("X-NavishAI-Timestamp", timestamp)
		r.Header.Set("X-NavishAI-Signature", signature)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestHandlerRejectsUntrustedOrMalformedDocumentsWithoutConversion(t *testing.T) {
	h, _ := NewHandler(secret, extractorFunc(func(context.Context, []byte) ([]byte, error) { t.Fatal("invoked for invalid request"); return nil, nil }))
	valid := validRequest()
	body, _ := json.Marshal(valid)
	if result := serve(t, h, body, false); result.Code != 401 {
		t.Fatal(result.Code)
	}
	for _, mutate := range []func(*Request){func(r *Request) { r.WorkspaceKey = "../other" }, func(r *Request) { r.Format = "docx" }, func(r *Request) { r.ContentSHA256 = strings.Repeat("0", 64) }, func(r *Request) { r.ContentBase64 += "\n" }, func(r *Request) { r.ContentBase64 = "not-base64" }, func(r *Request) { r.ContentBase64 = strings.Repeat("A", base64.StdEncoding.EncodedLen(MaxInput)+4) }} {
		request := valid
		mutate(&request)
		body, _ := json.Marshal(request)
		if result := serve(t, h, body, true); result.Code != 422 {
			t.Fatal(result.Code)
		}
	}
	body = bytes.Replace(body, []byte(`"format":"doc"`), []byte(`"filename":"/etc/passwd","format":"doc"`), 1)
	if result := serve(t, h, body, true); result.Code != 422 {
		t.Fatal(result.Code)
	}
	if result := serve(t, h, bytes.Repeat([]byte("a"), MaxBody+1), true); result.Code != 413 {
		t.Fatal(result.Code)
	}
}

func TestHandlerBindsResultAndFailsClosedWhenUnavailableOrBusy(t *testing.T) {
	input := validRequest()
	body, _ := json.Marshal(input)
	h, _ := NewHandler(secret, nil)
	if r := serve(t, h, body, true); r.Code != 503 {
		t.Fatal(r.Code)
	}
	h.extractor = extractorFunc(func(context.Context, []byte) ([]byte, error) { return []byte("safe text"), nil })
	r := serve(t, h, body, true)
	if r.Code != 200 {
		t.Fatal(r.Code)
	}
	var output map[string]string
	if json.Unmarshal(r.Body.Bytes(), &output) != nil || len(output) != 6 || output["workspace_key"] != input.WorkspaceKey || output["content_sha256"] != input.ContentSHA256 || output["text_base64"] != base64.StdEncoding.EncodeToString([]byte("safe text")) {
		t.Fatal(r.Body.String())
	}
	h.slots <- struct{}{}
	h.slots <- struct{}{}
	if r := serve(t, h, body, true); r.Code != 503 {
		t.Fatal(r.Code)
	}
}

func TestConverterBoundsOutputAndCleansEveryRequest(t *testing.T) {
	for _, scenario := range []string{"success", "symlink", "oversize", "invalid_utf8", "timeout", "failure"} {
		t.Run(scenario, func(t *testing.T) {
			root := t.TempDir()
			converter := Converter{root: root, executable: "/approved/navishai-document", runner: fixtureProcess{func(r supervisor.Request) (supervisor.Result, error) {
				if r.Executable != "/approved/navishai-document" || r.HomeDir != r.WorkingDir || r.EgressProfileKey != "" || r.Credentials["TMPDIR"] != r.WorkingDir {
					t.Fatal("unsafe invocation")
				}
				profile, err := os.ReadFile(filepath.Join(r.WorkingDir, "profile/user/registrymodifications.xcu"))
				if err != nil || !bytes.Contains(profile, []byte("DisableMacrosExecution")) {
					t.Fatal("missing locked profile")
				}
				output := filepath.Join(r.WorkingDir, "input.txt")
				switch scenario {
				case "symlink":
					err = os.Symlink("/etc/passwd", output)
				case "oversize":
					err = os.WriteFile(output, bytes.Repeat([]byte("x"), MaxText+1), 0600)
				case "invalid_utf8":
					err = os.WriteFile(output, []byte{0xff}, 0600)
				case "timeout":
					return supervisor.Result{TimedOut: true}, nil
				case "failure":
					return supervisor.Result{ExitCode: 1}, nil
				default:
					err = os.WriteFile(output, []byte("converted"), 0600)
				}
				if err != nil {
					t.Fatal(err)
				}
				return supervisor.Result{}, nil
			}}}
			text, err := converter.Extract(context.Background(), compoundSignature)
			if scenario == "success" {
				if err != nil || string(text) != "converted" {
					t.Fatal(err)
				}
			} else if err == nil {
				t.Fatal("unsafe output accepted")
			}
			entries, err := os.ReadDir(root)
			if err != nil || len(entries) != 0 {
				t.Fatal("conversion files retained")
			}
		})
	}
}

func TestExcludedRootResolutionPreservesMissingPathsAndSymlinks(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if resolved, err := resolveConfiguredRoot(filepath.Join(root, "not-installed", "runtime")); err != nil || resolved != filepath.Join(root, "not-installed", "runtime") {
		t.Fatalf("missing root: %q %v", resolved, err)
	}
	alias := filepath.Join(root, "alias")
	if err := os.Symlink(root, alias); err != nil {
		t.Fatal(err)
	}
	if resolved, err := resolveConfiguredRoot(filepath.Join(alias, "missing")); err != nil || resolved != filepath.Join(root, "missing") {
		t.Fatalf("symlink ancestor: %q %v", resolved, err)
	}
	if _, err := resolveConfiguredRoot("relative/home"); err == nil {
		t.Fatal("relative excluded root accepted")
	}
}

type forbiddenBody struct{ t *testing.T }

func (body forbiddenBody) Read([]byte) (int, error) {
	body.t.Fatal("read unsigned slow request body")
	return 0, nil
}
func (forbiddenBody) Close() error { return nil }
func TestUnsignedBodyCannotOccupyConversionSlots(t *testing.T) {
	handler, _ := NewHandler(secret, nil)
	request := httptest.NewRequest("POST", Path, nil)
	request.Body = forbiddenBody{t}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != 401 || len(handler.slots) != 0 {
		t.Fatalf("unsigned transport reserved process capacity: %d", response.Code)
	}
}

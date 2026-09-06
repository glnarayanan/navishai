package protocol

import (
	"encoding/json"
	"testing"
)

func TestPersonalRoutingRequiresOwnerAndForbidsImplicitFallback(t *testing.T) {
	var original AdmissionRequest
	if err := json.Unmarshal(readFixture(t, "admission_request.json"), &original); err != nil {
		t.Fatal(err)
	}
	original.Routing.PersonalAccount = &PersonalAccount{AccountKey: "9334c36b-98a9-4314-8b40-c42f5d1c16b8", MembershipID: 4}
	original.Routing.AdapterKey = "codex_subscription"
	original.Routing.ExecutionMode = ExecutionModeStrongIsolated
	original.Routing.IsolationPolicy = IsolationPolicyStrongRequired
	original.Routing.SelectionReason = "primary"
	original.Agent.FallbackProfileKeys = []string{}
	if err := original.Validate(); err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*AdmissionRequest){
		func(r *AdmissionRequest) {
			r.Routing.PersonalAccount = &PersonalAccount{AccountKey: "9334c36b-98a9-4314-8b40-c42f5d1c16b8"}
		},
		func(r *AdmissionRequest) { r.Routing.ExecutionMode = ExecutionModeHostTrusted },
		func(r *AdmissionRequest) { r.Routing.AdapterKey = "scripted" },
		func(r *AdmissionRequest) { r.Routing.SelectionReason = "fallback" },
		func(r *AdmissionRequest) { r.Agent.FallbackProfileKeys = []string{"fallback"} },
	} {
		request := original
		mutate(&request)
		if request.Validate() == nil {
			t.Fatal("unsafe personal routing accepted")
		}
	}
}

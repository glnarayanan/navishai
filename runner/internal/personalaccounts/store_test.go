package personalaccounts

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
)

var testOwner = Owner{"4ee58722-70ad-4b11-89f7-23a1edc78d77", 4}

const testKey = "9334c36b-98a9-4314-8b40-c42f5d1c16b8"

func TestStoreScopesCredentialsAndRetainsApprovalAcrossRestart(t *testing.T) {
	root := privateRoot(t)
	login := func(ctx context.Context, home string, challenge func(Challenge) error) error { return nil }
	verify := func(ctx context.Context, account Account, home string) (runtimecatalog.Installation, TestEvidence, error) {
		return runtimecatalog.Installation{ConfigurationFingerprint: "approved"}, TestEvidence{Status: "passed", ConfigurationFingerprint: "approved"}, nil
	}
	store, err := OpenStore(root, login, verify)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Start(testOwner, testKey); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for {
		account, _ := store.Status(testOwner, testKey)
		if account.State == "connected" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("connection did not finish")
		}
		time.Sleep(time.Millisecond)
	}
	for _, owner := range []Owner{{testOwner.WorkspaceKey, 5}, {"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", 4}} {
		if _, err := store.Status(owner, testKey); err != ErrConflict {
			t.Fatal("cross-owner status permitted")
		}
		if _, err := store.Start(owner, testKey); err != ErrConflict {
			t.Fatal("cross-owner start permitted")
		}
		if _, _, _, err := store.Acquire(owner, testKey, "approved"); err != ErrConflict {
			t.Fatal("cross-owner execution permitted")
		}
	}
	if _, _, _, err := store.Acquire(testOwner, testKey, "changed"); err != ErrConflict {
		t.Fatal("changed fingerprint permitted")
	}
	_, home, release, err := store.Acquire(testOwner, testKey, "approved")
	if err != nil || home != root+"/"+testKey+"/home" {
		t.Fatal("incorrect credential home", err)
	}
	if _, _, _, err := store.Acquire(testOwner, testKey, "approved"); err != ErrConflict {
		t.Fatal("concurrent execution acquired mutable credentials")
	}
	if _, err := store.Disconnect(testOwner, testKey); err != ErrConflict {
		t.Fatal("deleted active execution credentials")
	}
	if err := store.PurgeWorkspace(testOwner.WorkspaceKey); err != ErrConflict {
		t.Fatal("purged active execution credentials")
	}
	release()
	release()
	store, err = OpenStore(root, login, verify)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Disconnect(testOwner, testKey); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := store.Acquire(testOwner, testKey, "approved"); err != ErrConflict {
		t.Fatal("disconnected execution permitted")
	}
	if err := store.PurgeWorkspace(testOwner.WorkspaceKey); err != nil {
		t.Fatal(err)
	}
}

func TestInterruptedLoginCannotBecomeConnected(t *testing.T) {
	started := make(chan struct{})
	store, err := OpenStore(privateRoot(t), func(ctx context.Context, _ string, _ func(Challenge) error) error {
		close(started)
		<-ctx.Done()
		return ctx.Err()
	}, func(context.Context, Account, string) (runtimecatalog.Installation, TestEvidence, error) {
		t.Error("verified canceled login")
		return runtimecatalog.Installation{}, TestEvidence{}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Start(testOwner, testKey); err != nil {
		t.Fatal(err)
	}
	<-started
	if _, err := store.Disconnect(testOwner, testKey); err != ErrConflict {
		t.Fatal("pending cancellation should request retry")
	}
	deadline := time.Now().Add(time.Second)
	for {
		account, _ := store.Status(testOwner, testKey)
		if account.State == "failed" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("login not canceled")
		}
		time.Sleep(time.Millisecond)
	}
	if _, err := store.Disconnect(testOwner, testKey); err != nil {
		t.Fatal(err)
	}
}

func privateRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0700); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestDisconnectBeforeStartPersistsOwnerScopedTombstone(t *testing.T) {
	root := privateRoot(t)
	login := func(context.Context, string, func(Challenge) error) error {
		t.Error("disconnected account started login")
		return ErrUnavailable
	}
	verify := func(context.Context, Account, string) (runtimecatalog.Installation, TestEvidence, error) {
		t.Error("disconnected account verified")
		return runtimecatalog.Installation{}, TestEvidence{}, ErrUnavailable
	}
	store, err := OpenStore(root, login, verify)
	if err != nil {
		t.Fatal(err)
	}
	account, err := store.Disconnect(testOwner, testKey)
	if err != nil || account.State != "disconnected" || account.Owner != testOwner {
		t.Fatalf("missing-start disconnect: %#v %v", account, err)
	}
	store, err = OpenStore(root, login, verify)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		account, err = store.Start(testOwner, testKey)
		if err != nil || account.State != "disconnected" {
			t.Fatalf("delayed start resurrected account: %#v %v", account, err)
		}
		account, err = store.Disconnect(testOwner, testKey)
		if err != nil || account.State != "disconnected" {
			t.Fatalf("repeated disconnect: %#v %v", account, err)
		}
	}
	other := Owner{WorkspaceKey: testOwner.WorkspaceKey, MembershipID: testOwner.MembershipID + 1}
	if _, err := store.Start(other, testKey); err != ErrConflict {
		t.Fatal("other member claimed tombstone")
	}
	if _, err := store.Disconnect(other, testKey); err != ErrConflict {
		t.Fatal("other member replaced tombstone")
	}
	if _, err := os.Stat(store.home(testKey)); !os.IsNotExist(err) {
		t.Fatalf("tombstone created credential home: %v", err)
	}
}

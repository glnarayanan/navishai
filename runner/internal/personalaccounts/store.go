package personalaccounts

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/glnarayanan/navishai/runner/internal/runtimecatalog"
)

var ErrConflict = errors.New("personal account ownership or state conflict")

type Owner struct {
	WorkspaceKey string `json:"workspace_key"`
	MembershipID int64  `json:"membership_id"`
}

type Account struct {
	Owner
	AccountKey   string                       `json:"account_key"`
	State        string                       `json:"state"`
	Installation *runtimecatalog.Installation `json:"installation,omitempty"`
	RuntimeTest  *TestEvidence                `json:"runtime_test,omitempty"`
	Challenge    *Challenge                   `json:"challenge,omitempty"`
	ExpiresAt    time.Time                    `json:"expires_at"`
}

type TestEvidence struct {
	Status                   string    `json:"status"`
	ConfigurationFingerprint string    `json:"configuration_fingerprint"`
	ExecutionMode            string    `json:"execution_mode"`
	EffectiveModel           string    `json:"effective_model"`
	TestedAt                 time.Time `json:"tested_at"`
	UsageObserved            bool      `json:"usage_observed"`
	InputUnits               int       `json:"input_units"`
	OutputUnits              int       `json:"output_units"`
	FailureCode              string    `json:"failure_code"`
}

type Login func(context.Context, string, func(Challenge) error) error
type Verify func(context.Context, Account, string) (runtimecatalog.Installation, TestEvidence, error)

type Store struct {
	mu       sync.Mutex
	root     string
	accounts map[string]Account
	pending  map[string]context.CancelFunc
	leases   map[string]int
	login    Login
	verify   Verify
}

func OpenStore(root string, login Login, verify Verify) (*Store, error) {
	if !filepath.IsAbs(root) || login == nil || verify == nil {
		return nil, ErrUnavailable
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0077 != 0 {
		return nil, ErrUnavailable
	}
	store := &Store{root: root, accounts: map[string]Account{}, pending: map[string]context.CancelFunc{}, leases: map[string]int{}, login: login, verify: verify}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if !uuidPattern.MatchString(entry.Name()) || !entry.IsDir() {
			return nil, ErrUnavailable
		}
		info, err := entry.Info()
		if err != nil || info.Mode().Perm()&0077 != 0 {
			return nil, ErrUnavailable
		}
		file, err := os.Open(filepath.Join(root, entry.Name(), "account.json"))
		if err != nil {
			return nil, err
		}
		body, err := io.ReadAll(io.LimitReader(file, 64*1024+1))
		file.Close()
		if err != nil {
			return nil, err
		}
		var account Account
		if len(body) > 64*1024 || json.Unmarshal(body, &account) != nil || !validOwner(account.Owner) || account.AccountKey != entry.Name() {
			return nil, ErrUnavailable
		}
		account.Challenge = nil
		if account.State == "pending" || account.State == "starting" {
			account.State = "failed"
		}
		if account.State != "connected" && account.State != "failed" && account.State != "disconnected" {
			return nil, ErrUnavailable
		}
		if account.State == "connected" && (account.Installation == nil || account.RuntimeTest == nil || account.RuntimeTest.Status != "passed" || account.RuntimeTest.ConfigurationFingerprint != account.Installation.ConfigurationFingerprint) {
			return nil, ErrUnavailable
		}
		store.accounts[account.AccountKey] = account
	}
	return store, nil
}

func (store *Store) Start(owner Owner, key string) (Account, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if !validOwner(owner) || !uuidPattern.MatchString(key) {
		return Account{}, ErrConflict
	}
	if account, ok := store.accounts[key]; ok {
		if account.Owner != owner {
			return Account{}, ErrConflict
		}
		return account, nil
	}
	for _, account := range store.accounts {
		if account.Owner == owner && account.State != "disconnected" && account.State != "failed" {
			return Account{}, ErrConflict
		}
	}
	account := Account{Owner: owner, AccountKey: key, State: "starting", ExpiresAt: time.Now().UTC().Add(15 * time.Minute)}
	if err := os.Mkdir(filepath.Join(store.root, key), 0700); err != nil {
		return Account{}, ErrUnavailable
	}
	if err := os.Mkdir(store.home(key), 0700); err != nil {
		_ = os.RemoveAll(filepath.Join(store.root, key))
		return Account{}, ErrUnavailable
	}
	if err := store.save(account); err != nil {
		_ = os.RemoveAll(filepath.Join(store.root, key))
		return Account{}, err
	}
	store.accounts[key] = account
	ctx, cancel := context.WithDeadline(context.Background(), account.ExpiresAt)
	store.pending[key] = cancel
	go store.connect(ctx, account)
	return account, nil
}

func (store *Store) Status(owner Owner, key string) (Account, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	account, ok := store.accounts[key]
	if !ok || account.Owner != owner {
		return Account{}, ErrConflict
	}
	return account, nil
}

func (store *Store) Disconnect(owner Owner, key string) (Account, error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	if !validOwner(owner) || !uuidPattern.MatchString(key) {
		return Account{}, ErrConflict
	}
	account, ok := store.accounts[key]
	if !ok {
		account = Account{Owner: owner, AccountKey: key, State: "disconnected", ExpiresAt: time.Now().UTC()}
		if err := os.Mkdir(filepath.Join(store.root, key), 0700); err != nil {
			return Account{}, ErrUnavailable
		}
		if err := store.save(account); err != nil {
			_ = os.RemoveAll(filepath.Join(store.root, key))
			return Account{}, err
		}
		store.accounts[key] = account
		return account, nil
	}
	if account.Owner != owner || store.leases[key] > 0 {
		return Account{}, ErrConflict
	}
	if cancel, ok := store.pending[key]; ok {
		cancel()
		return Account{}, ErrConflict
	}
	account.State = "disconnected"
	account.Challenge = nil
	account.Installation = nil
	account.RuntimeTest = nil
	if err := store.save(account); err != nil {
		return Account{}, err
	}
	store.accounts[key] = account
	if err := os.RemoveAll(store.home(key)); err != nil {
		return Account{}, ErrUnavailable
	}
	return account, nil
}

func (store *Store) PurgeWorkspace(workspace string) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	if !uuidPattern.MatchString(workspace) {
		return ErrConflict
	}
	busy := false
	for key, account := range store.accounts {
		if account.WorkspaceKey != workspace {
			continue
		}
		if store.leases[key] > 0 {
			busy = true
		}
		if cancel, ok := store.pending[key]; ok {
			cancel()
			busy = true
		}
	}
	if busy {
		return ErrConflict
	}
	for key, account := range store.accounts {
		if account.WorkspaceKey != workspace {
			continue
		}
		if err := os.RemoveAll(filepath.Join(store.root, key)); err != nil {
			return ErrUnavailable
		}
		delete(store.accounts, key)
	}
	return nil
}

func (store *Store) Acquire(owner Owner, key, fingerprint string) (Account, string, func(), error) {
	store.mu.Lock()
	defer store.mu.Unlock()
	account, ok := store.accounts[key]
	if !ok || account.Owner != owner || account.State != "connected" || account.Installation == nil || account.Installation.ConfigurationFingerprint != fingerprint || store.leases[key] > 0 {
		return Account{}, "", nil, ErrConflict
	}
	store.leases[key]++
	var once sync.Once
	release := func() { once.Do(func() { store.mu.Lock(); defer store.mu.Unlock(); store.leases[key]-- }) }
	return account, store.home(key), release, nil
}

func (store *Store) connect(ctx context.Context, account Account) {
	err := store.login(ctx, store.home(account.AccountKey), func(challenge Challenge) error {
		store.mu.Lock()
		defer store.mu.Unlock()
		account.State = "pending"
		account.Challenge = &challenge
		store.accounts[account.AccountKey] = account
		return nil
	})
	var installation runtimecatalog.Installation
	var evidence TestEvidence
	if err == nil {
		installation, evidence, err = store.verify(ctx, account, store.home(account.AccountKey))
	}
	success := err == nil && ctx.Err() == nil && evidence.Status == "passed"
	store.mu.Lock()
	defer store.mu.Unlock()
	store.pending[account.AccountKey]()
	delete(store.pending, account.AccountKey)
	account.Challenge = nil
	account.State = "failed"
	if success {
		account.State = "connected"
		account.Installation = &installation
		account.RuntimeTest = &evidence
	}
	if err := store.save(account); err != nil {
		account.State = "failed"
		account.Installation = nil
		account.RuntimeTest = nil
	}
	store.accounts[account.AccountKey] = account
	if account.State == "failed" {
		_ = os.RemoveAll(store.home(account.AccountKey))
	}
}

func (store *Store) home(key string) string { return filepath.Join(store.root, key, "home") }
func (store *Store) save(account Account) error {
	account.Challenge = nil
	body, err := json.Marshal(account)
	if err != nil {
		return ErrUnavailable
	}
	path := filepath.Join(store.root, account.AccountKey, "account.json")
	if err := os.WriteFile(path+".new", body, 0600); err != nil {
		return ErrUnavailable
	}
	if err := os.Rename(path+".new", path); err != nil {
		return ErrUnavailable
	}
	return nil
}
func validOwner(owner Owner) bool {
	return uuidPattern.MatchString(owner.WorkspaceKey) && owner.MembershipID > 0
}

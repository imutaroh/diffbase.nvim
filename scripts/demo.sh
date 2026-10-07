#!/usr/bin/env bash
# Build a small demo repository and open Neovim in a scene that is ready for a screenshot.
#
#   scripts/demo.sh [scene] [dir]
#
# scene: setup (default) | hero | tree | menu
# dir:   where the demo lives (default: ${TMPDIR:-/tmp}/diffbase-demo)
#
# The repository is recreated from scratch on every run, with fixed authors and dates, so the commit
# hashes are the same every time. The script only ever deletes <dir> itself, and only when <dir> is
# empty or carries the marker file .diffbase-demo that this script creates.

set -eu

SCENES="setup hero tree menu"
MARKER=".diffbase-demo"

usage() {
  echo "usage: scripts/demo.sh [scene] [dir]" >&2
  echo "scenes: $SCENES" >&2
  exit 2
}

SCENE=${1:-setup}
case " $SCENES " in
*" $SCENE "*) ;;
*) usage ;;
esac

BASE_TMP=${TMPDIR:-/tmp}
BASE_TMP=${BASE_TMP%/}
DIR=${2:-$BASE_TMP/diffbase-demo}
# Make DIR absolute: the origin remote URL and the scene paths are used from inside the repository,
# where a relative path would resolve differently. Logical pwd keeps the path short (no /private).
case "$DIR" in
/*) ;;
*) DIR=$PWD/$DIR ;;
esac
if [ -d "$DIR" ]; then
  DIR=$(cd "$DIR" && pwd)
fi
DIR=${DIR%/}
REPO=$DIR/todo-api
ORIGIN=$DIR/origin.git

# ---------------------------------------------------------------------------------------------------
# Safety: refuse to delete anything that this script did not create.
# ---------------------------------------------------------------------------------------------------
case "$DIR" in
"" | "/" | "$HOME" | "$HOME/")
  echo "demo.sh: refusing to use '$DIR'" >&2
  exit 1
  ;;
esac

# Deleting the current directory (or one above it) would leave the shell in a removed directory.
case "$PWD/" in
"$DIR/"*)
  echo "demo.sh: '$DIR' contains the current directory; run the script from somewhere else" >&2
  exit 1
  ;;
esac

if [ -e "$DIR" ] && [ ! -d "$DIR" ]; then
  echo "demo.sh: '$DIR' exists and is not a directory" >&2
  exit 1
fi
if [ -d "$DIR" ]; then
  if [ -f "$DIR/$MARKER" ]; then
    rm -rf "$DIR"
  elif [ -n "$(ls -A "$DIR")" ]; then
    echo "demo.sh: '$DIR' is not empty and has no $MARKER marker; refusing to delete it" >&2
    exit 1
  fi
fi
mkdir -p "$DIR"
: >"$DIR/$MARKER"

# ---------------------------------------------------------------------------------------------------
# git with a fixed identity, ignoring the user's global and system config (hooks, signing, templates),
# so that the hashes are reproducible.
# ---------------------------------------------------------------------------------------------------
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@example.com
export GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@example.com

g() { git -C "$REPO" "$@"; }

# commit_at <unix time> <message>
commit_at() {
  GIT_AUTHOR_DATE="@$1 +0000" GIT_COMMITTER_DATE="@$1 +0000" g commit -q -m "$2"
}

fmt_go() {
  if command -v gofmt >/dev/null 2>&1; then
    (cd "$REPO" && find . -name '*.go' -not -path './.git/*' -exec gofmt -w {} +)
  fi
}

mkdir -p "$REPO/cmd/server" "$REPO/internal/todo"

# ===================================================================================================
# Base (main): "Initial todo API"
# ===================================================================================================
cat >"$REPO/go.mod" <<'EOF'
module example.com/todo-api

go 1.22
EOF

cat >"$REPO/README.md" <<'EOF'
# todo-api

A small in-memory todo API written in Go.

## Run

```sh
go run ./cmd/server
```

The server listens on `:8080`. Set `ADDR` to change it.

## Endpoints

| Method | Path | Description |
| --- | --- | --- |
| GET | /todos | List todos |
| POST | /todos | Create a todo |
| GET | /todos/{id} | Get one todo |
| POST | /todos/{id}/done | Mark a todo as done |

## Test

```sh
go test ./...
```
EOF

cat >"$REPO/cmd/server/main.go" <<'EOF'
// Command server runs the todo HTTP API.
package main

import (
	"log"
	"net/http"
	"os"
	"time"

	"example.com/todo-api/internal/todo"
)

func main() {
	addr := ":8080"
	if v := os.Getenv("ADDR"); v != "" {
		addr = v
	}

	mux := http.NewServeMux()
	todo.NewHandler(todo.NewStore()).Register(mux)

	srv := &http.Server{
		Addr:              addr,
		Handler:           logRequests(mux),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("todo-api listening on %s", addr)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}

// logRequests logs the method, path and duration of every request.
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}
EOF

cat >"$REPO/internal/todo/store.go" <<'EOF'
package todo

import (
	"errors"
	"sort"
	"sync"
	"time"
)

// ErrNotFound is returned when a todo does not exist.
var ErrNotFound = errors.New("todo not found")

// Todo is a single task.
type Todo struct {
	ID        int       `json:"id"`
	Title     string    `json:"title"`
	Done      bool      `json:"done"`
	CreatedAt time.Time `json:"created_at"`
}

// Store keeps todos in memory.
type Store struct {
	mu     sync.Mutex
	nextID int
	items  map[int]Todo
}

// NewStore returns an empty store.
func NewStore() *Store {
	return &Store{nextID: 1, items: make(map[int]Todo)}
}

// List returns all todos ordered by ID.
func (s *Store) List() []Todo {
	s.mu.Lock()
	defer s.mu.Unlock()

	out := make([]Todo, 0, len(s.items))
	for _, t := range s.items {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// Get returns the todo with the given ID.
func (s *Store) Get(id int) (Todo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	t, ok := s.items[id]
	if !ok {
		return Todo{}, ErrNotFound
	}
	return t, nil
}

// Create adds a new todo and returns it.
func (s *Store) Create(title string) Todo {
	s.mu.Lock()
	defer s.mu.Unlock()

	t := Todo{ID: s.nextID, Title: title, CreatedAt: time.Now()}
	s.items[t.ID] = t
	s.nextID++
	return t
}

// Complete marks a todo as done.
func (s *Store) Complete(id int) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	t, ok := s.items[id]
	if !ok {
		return ErrNotFound
	}
	t.Done = true
	s.items[t.ID] = t
	return nil
}
EOF

cat >"$REPO/internal/todo/store_test.go" <<'EOF'
package todo

import "testing"

func TestCreateAssignsIncreasingIDs(t *testing.T) {
	s := NewStore()
	a := s.Create("write docs")
	b := s.Create("review PR")
	if a.ID != 1 || b.ID != 2 {
		t.Fatalf("got IDs %d and %d, want 1 and 2", a.ID, b.ID)
	}
}

func TestGetMissing(t *testing.T) {
	s := NewStore()
	if _, err := s.Get(42); err != ErrNotFound {
		t.Fatalf("Get(42) error = %v, want ErrNotFound", err)
	}
}

func TestComplete(t *testing.T) {
	s := NewStore()
	created := s.Create("ship it")
	if err := s.Complete(created.ID); err != nil {
		t.Fatalf("Complete: %v", err)
	}
	got, _ := s.Get(created.ID)
	if !got.Done {
		t.Fatal("todo is not marked done")
	}
}

func TestListIsSortedByID(t *testing.T) {
	s := NewStore()
	for _, title := range []string{"a", "b", "c"} {
		s.Create(title)
	}
	list := s.List()
	for i, todo := range list {
		if todo.ID != i+1 {
			t.Fatalf("list[%d].ID = %d, want %d", i, todo.ID, i+1)
		}
	}
}
EOF

cat >"$REPO/internal/todo/handler.go" <<'EOF'
package todo

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
)

// Handler serves the todo HTTP API.
type Handler struct {
	store *Store
}

// NewHandler returns a handler backed by store.
func NewHandler(store *Store) *Handler {
	return &Handler{store: store}
}

// Register mounts the routes on mux.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /todos", h.list)
	mux.HandleFunc("POST /todos", h.create)
	mux.HandleFunc("GET /todos/{id}", h.get)
	mux.HandleFunc("POST /todos/{id}/done", h.complete)
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	todos := h.store.List()
	if r.URL.Query().Get("debug") == "1" {
		log.Printf("list: returning %d todos", len(todos))
	}
	writeJSON(w, http.StatusOK, todos)
}

type createRequest struct {
	Title string `json:"title"`
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	var req createRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	// TODO: validate the title properly.
	if req.Title == "" {
		http.Error(w, "title is required", http.StatusBadRequest)
		return
	}
	writeJSON(w, http.StatusCreated, h.store.Create(req.Title))
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		http.Error(w, "bad id", http.StatusBadRequest)
		return
	}
	t, err := h.store.Get(id)
	if errors.Is(err, ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	writeJSON(w, http.StatusOK, t)
}

func (h *Handler) complete(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		http.Error(w, "bad id", http.StatusBadRequest)
		return
	}
	if err := h.store.Complete(id); errors.Is(err, ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("encode response: %v", err)
	}
}
EOF

fmt_go
git init -q -b main "$REPO"
g add -A
commit_at 1767607200 "Initial todo API"

# A bare clone acts as origin, so that origin/HEAD exists and the "main" base resolves to the
# merge-base with origin/main.
git clone -q --bare "$REPO" "$ORIGIN"
g remote add origin "$ORIGIN"
g fetch -q origin
g remote set-head origin main >/dev/null

g switch -q -c feature/validation

# ===================================================================================================
# feature/validation, commit 1: due dates in the store
# ===================================================================================================
cat >"$REPO/internal/todo/store.go" <<'EOF'
package todo

import (
	"errors"
	"sort"
	"sync"
	"time"
)

// ErrNotFound is returned when a todo does not exist.
var ErrNotFound = errors.New("todo not found")

// Todo is a single task.
type Todo struct {
	ID        int        `json:"id"`
	Title     string     `json:"title"`
	Done      bool       `json:"done"`
	Due       *time.Time `json:"due,omitempty"`
	CreatedAt time.Time  `json:"created_at"`
}

// Store keeps todos in memory. It is safe for concurrent use.
type Store struct {
	mu     sync.Mutex
	nextID int
	todos  map[int]Todo
}

// NewStore returns an empty store.
func NewStore() *Store {
	return &Store{nextID: 1, todos: make(map[int]Todo)}
}

// List returns all todos ordered by ID.
func (s *Store) List() []Todo {
	s.mu.Lock()
	defer s.mu.Unlock()

	out := make([]Todo, 0, len(s.todos))
	for _, t := range s.todos {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// Get returns the todo with the given ID.
func (s *Store) Get(id int) (Todo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	t, ok := s.todos[id]
	if !ok {
		return Todo{}, ErrNotFound
	}
	return t, nil
}

// Create adds a new todo and returns it. due may be nil.
func (s *Store) Create(title string, due *time.Time) Todo {
	s.mu.Lock()
	defer s.mu.Unlock()

	t := Todo{ID: s.nextID, Title: title, Due: due, CreatedAt: time.Now()}
	s.todos[t.ID] = t
	s.nextID++
	return t
}

// Complete marks a todo as done and returns it.
func (s *Store) Complete(id int) (Todo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	t, ok := s.todos[id]
	if !ok {
		return Todo{}, ErrNotFound
	}
	t.Done = true
	s.todos[t.ID] = t
	return t, nil
}
EOF

cat >"$REPO/internal/todo/store_test.go" <<'EOF'
package todo

import (
	"errors"
	"testing"
	"time"
)

func TestCreateAssignsIncreasingIDs(t *testing.T) {
	s := NewStore()
	a := s.Create("write docs", nil)
	b := s.Create("review PR", nil)
	if a.ID != 1 || b.ID != 2 {
		t.Fatalf("got IDs %d and %d, want 1 and 2", a.ID, b.ID)
	}
}

func TestCreateKeepsDue(t *testing.T) {
	s := NewStore()
	due := time.Date(2030, 1, 2, 9, 0, 0, 0, time.UTC)
	got := s.Create("renew passport", &due)
	if got.Due == nil || !got.Due.Equal(due) {
		t.Fatalf("Due = %v, want %v", got.Due, due)
	}
}

func TestGetMissing(t *testing.T) {
	s := NewStore()
	if _, err := s.Get(42); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Get(42) error = %v, want ErrNotFound", err)
	}
}

func TestComplete(t *testing.T) {
	s := NewStore()
	created := s.Create("ship it", nil)
	done, err := s.Complete(created.ID)
	if err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if !done.Done {
		t.Fatal("todo is not marked done")
	}
}

func TestListIsSortedByID(t *testing.T) {
	s := NewStore()
	for _, title := range []string{"a", "b", "c"} {
		s.Create(title, nil)
	}
	list := s.List()
	for i, todo := range list {
		if todo.ID != i+1 {
			t.Fatalf("list[%d].ID = %d, want %d", i, todo.ID, i+1)
		}
	}
}
EOF

# The handler has to follow the new store signatures in the same commit to keep the build green.
cat >"$REPO/internal/todo/handler.go" <<'EOF'
package todo

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
)

// Handler serves the todo HTTP API.
type Handler struct {
	store *Store
}

// NewHandler returns a handler backed by store.
func NewHandler(store *Store) *Handler {
	return &Handler{store: store}
}

// Register mounts the routes on mux.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /todos", h.list)
	mux.HandleFunc("POST /todos", h.create)
	mux.HandleFunc("GET /todos/{id}", h.get)
	mux.HandleFunc("POST /todos/{id}/done", h.complete)
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	todos := h.store.List()
	if r.URL.Query().Get("debug") == "1" {
		log.Printf("list: returning %d todos", len(todos))
	}
	writeJSON(w, http.StatusOK, todos)
}

type createRequest struct {
	Title string `json:"title"`
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	var req createRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	// TODO: validate the title properly.
	if req.Title == "" {
		http.Error(w, "title is required", http.StatusBadRequest)
		return
	}
	writeJSON(w, http.StatusCreated, h.store.Create(req.Title, nil))
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		http.Error(w, "bad id", http.StatusBadRequest)
		return
	}
	t, err := h.store.Get(id)
	if errors.Is(err, ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	writeJSON(w, http.StatusOK, t)
}

func (h *Handler) complete(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		http.Error(w, "bad id", http.StatusBadRequest)
		return
	}
	if _, err := h.store.Complete(id); errors.Is(err, ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("encode response: %v", err)
	}
}
EOF

fmt_go
g add -A
commit_at 1767787200 "Store due dates and return completed todos"

# ===================================================================================================
# feature/validation, commit 2: request validation
# ===================================================================================================
cat >"$REPO/internal/todo/validate.go" <<'EOF'
package todo

import (
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

// maxTitleLen is the longest title accepted, in characters.
const maxTitleLen = 120

// ValidationError describes why a request was rejected.
type ValidationError struct {
	Field   string `json:"field"`
	Message string `json:"message"`
}

func (e *ValidationError) Error() string {
	return fmt.Sprintf("%s: %s", e.Field, e.Message)
}

// Validate checks a create request before it reaches the store.
// now is passed in so that tests can pin the clock.
func (req createRequest) Validate(now time.Time) error {
	title := strings.TrimSpace(req.Title)
	switch {
	case title == "":
		return &ValidationError{Field: "title", Message: "is required"}
	case utf8.RuneCountInString(title) > maxTitleLen:
		return &ValidationError{
			Field:   "title",
			Message: fmt.Sprintf("must be at most %d characters", maxTitleLen),
		}
	}
	if req.Due != nil && req.Due.Before(now) {
		return &ValidationError{Field: "due", Message: "must be in the future"}
	}
	return nil
}
EOF

cat >"$REPO/internal/todo/handler.go" <<'EOF'
package todo

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Handler serves the todo HTTP API.
type Handler struct {
	store *Store
	now   func() time.Time
}

// NewHandler returns a handler backed by store.
func NewHandler(store *Store) *Handler {
	return &Handler{store: store, now: time.Now}
}

// Register mounts the routes on mux.
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /todos", h.list)
	mux.HandleFunc("POST /todos", h.create)
	mux.HandleFunc("GET /todos/{id}", h.get)
	mux.HandleFunc("POST /todos/{id}/done", h.complete)
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	todos := h.store.List()
	writeJSON(w, http.StatusOK, todos)
}

type createRequest struct {
	Title string     `json:"title"`
	Due   *time.Time `json:"due"`
}

func (h *Handler) create(w http.ResponseWriter, r *http.Request) {
	var req createRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid JSON body", http.StatusBadRequest)
		return
	}
	if err := req.Validate(h.now()); err != nil {
		writeJSON(w, http.StatusUnprocessableEntity, err)
		return
	}
	t := h.store.Create(strings.TrimSpace(req.Title), req.Due)
	writeJSON(w, http.StatusCreated, t)
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		http.Error(w, "id must be a number", http.StatusBadRequest)
		return
	}
	t, err := h.store.Get(id)
	if errors.Is(err, ErrNotFound) {
		http.Error(w, "todo not found", http.StatusNotFound)
		return
	}
	writeJSON(w, http.StatusOK, t)
}

func (h *Handler) complete(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.Atoi(r.PathValue("id"))
	if err != nil {
		http.Error(w, "id must be a number", http.StatusBadRequest)
		return
	}
	t, err := h.store.Complete(id)
	if errors.Is(err, ErrNotFound) {
		http.Error(w, "todo not found", http.StatusNotFound)
		return
	}
	writeJSON(w, http.StatusOK, t)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("encode response: %v", err)
	}
}
EOF

fmt_go
g add -A
commit_at 1767960000 "Validate create requests"

# Publish the first two commits, so that the "unpushed" base has exactly one commit to show.
g push -q -u origin feature/validation 2>/dev/null

# ===================================================================================================
# feature/validation, commit 3 (not pushed): server timeouts and docs
# ===================================================================================================
cat >"$REPO/cmd/server/main.go" <<'EOF'
// Command server runs the todo HTTP API.
package main

import (
	"errors"
	"log"
	"net/http"
	"os"
	"time"

	"example.com/todo-api/internal/todo"
)

func main() {
	addr := ":8080"
	if v := os.Getenv("ADDR"); v != "" {
		addr = v
	}

	mux := http.NewServeMux()
	todo.NewHandler(todo.NewStore()).Register(mux)

	srv := &http.Server{
		Addr:              addr,
		Handler:           logRequests(mux),
		ReadHeaderTimeout: 5 * time.Second,
		WriteTimeout:      10 * time.Second,
	}
	log.Printf("todo-api listening on %s", addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

// logRequests logs the method, path and duration of every request.
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}
EOF

cat >"$REPO/README.md" <<'EOF'
# todo-api

A small in-memory todo API written in Go.

## Run

```sh
go run ./cmd/server
```

The server listens on `:8080`. Set `ADDR` to change it.

## Endpoints

| Method | Path | Description |
| --- | --- | --- |
| GET | /todos | List todos |
| POST | /todos | Create a todo (optional `due`, RFC 3339) |
| GET | /todos/{id} | Get one todo |
| POST | /todos/{id}/done | Mark a todo as done and return it |

## Validation

`POST /todos` answers `422 Unprocessable Entity` with `{"field", "message"}` when:

- `title` is empty or longer than 120 characters,
- `due` is in the past.

## Test

```sh
go test ./...
```
EOF

fmt_go
g add -A
commit_at 1768132800 "Set a write timeout and document validation"

# ===================================================================================================
# Work in progress: one uncommitted change and one untracked file.
# ErrNotFound moves from store.go (uncommitted deletion) to errors.go (untracked), which shows that
# diffbase counts both: the deletion as red lines, the untracked file as an all-green new file.
# ===================================================================================================
sed -e '/^\/\/ ErrNotFound is returned/,/^$/d' -e '/^	"errors"$/d' \
  "$REPO/internal/todo/store.go" >"$REPO/internal/todo/store.go.tmp"
mv "$REPO/internal/todo/store.go.tmp" "$REPO/internal/todo/store.go"

cat >"$REPO/internal/todo/errors.go" <<'EOF'
package todo

import "errors"

// Errors returned by the store. Handlers map them to HTTP status codes.
var (
	// ErrNotFound is returned when a todo does not exist.
	ErrNotFound = errors.New("todo not found")
)
EOF

fmt_go

# ---------------------------------------------------------------------------------------------------
# Scenes. Each scene is a Lua file sourced by your normal Neovim config (plain `nvim`).
# It waits for diffbase's DiffBaseChanged event instead of sleeping, so lazy-loaded plugins are ready.
# ---------------------------------------------------------------------------------------------------
write_scene_lib() {
  cat >"$DIR/scene-lib.lua" <<'EOF'
-- Shared helpers for the demo scenes (generated by scripts/demo.sh).
local M = {}

-- Run fn once, shortly after the first DiffBaseChanged event that follows `:DiffBase <base>`.
function M.on_diffbase(base, fn)
  vim.api.nvim_create_autocmd("User", {
    pattern = "DiffBaseChanged",
    once = true,
    callback = function()
      vim.defer_fn(fn, 150)
    end,
  })
  vim.cmd("DiffBase " .. base)
end

-- Make the window that shows `path` current.
function M.focus_file(path)
  local want = vim.fn.fnamemodify(path, ":p")
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p") == want then
      vim.api.nvim_set_current_win(win)
      return win
    end
  end
end

-- Scroll so that the line matching `top` is at the top, then put the cursor on `cursor`.
-- 'scrolloff' is set to 0 for this window, otherwise `zt` keeps that many lines above `top`.
function M.frame(top, cursor)
  vim.wo.scrolloff = 0
  vim.fn.cursor(1, 1)
  local lnum = vim.fn.search(top, "cW")
  if lnum > 0 then
    vim.cmd("normal! zt")
  end
  if cursor then
    vim.fn.search(cursor, "W")
  end
end

-- Clear the command line, so that startup messages from the user's config stay out of the capture.
function M.clear_messages()
  vim.cmd('redraw | echo ""')
end

return M
EOF
}

write_scene() {
  case "$1" in
  hero)
    cat >"$DIR/scene-hero.lua" <<'EOF'
-- hero: editing view with the branch diff, neo-tree counts on the left.
local lib = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/scene-lib.lua")
local file = "internal/todo/handler.go"
vim.defer_fn(function()
  lib.on_diffbase("main", function()
    vim.cmd("Neotree show reveal_file=" .. vim.fn.fnameescape(vim.fn.fnamemodify(file, ":p")))
    vim.defer_fn(function()
      lib.focus_file(file)
      lib.frame([[^func (h \*Handler) list]], [[invalid JSON body]])
      lib.clear_messages()
    end, 200)
  end)
end, 100)
EOF
    ;;
  tree)
    cat >"$DIR/scene-tree.lua" <<'EOF'
-- tree: neo-tree focused, every changed directory expanded.
local lib = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/scene-lib.lua")
local function reveal(path, action)
  vim.cmd("Neotree " .. action .. " reveal_file=" .. vim.fn.fnameescape(vim.fn.fnamemodify(path, ":p")))
end
vim.defer_fn(function()
  lib.on_diffbase("main", function()
    reveal("cmd/server/main.go", "show")
    vim.defer_fn(function()
      reveal("internal/todo/handler.go", "focus")
      lib.clear_messages()
    end, 200)
  end)
end, 100)
EOF
    ;;
  menu)
    cat >"$DIR/scene-menu.lua" <<'EOF'
-- menu: the base picker, opened over the diff view.
local lib = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/scene-lib.lua")
local file = "internal/todo/handler.go"
vim.defer_fn(function()
  lib.on_diffbase("main", function()
    vim.cmd("Neotree show reveal_file=" .. vim.fn.fnameescape(vim.fn.fnamemodify(file, ":p")))
    vim.defer_fn(function()
      lib.focus_file(file)
      lib.frame([[^func (h \*Handler) list]])
      lib.clear_messages()
      require("diffbase").pick()
    end, 200)
  end)
end, 100)
EOF
    ;;
  esac
}

hint() {
  case "$1" in
  hero) echo "hero: capture the whole window: green/red lines, word diff in create(), neo-tree +N -M counts." ;;
  tree) echo "tree: capture the neo-tree column: per-file and per-directory counts, errors.go (untracked) as new." ;;
  menu) echo "menu: capture the picker over the diff view (labels come from your diffbase config)." ;;
  esac
}

echo "demo repo: $REPO"
echo "branch:    feature/validation (3 commits ahead of main, last one unpushed, plus work in progress)"

if [ "$SCENE" = "setup" ]; then
  echo
  echo "scenes:"
  for s in hero tree menu; do
    printf '  scripts/demo.sh %-5s  # %s\n' "$s" "$(hint "$s")"
  done
  exit 0
fi

write_scene_lib
write_scene "$SCENE"
hint "$SCENE"
# Hand the user's own git config back to Neovim.
unset GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
cd "$REPO"
exec nvim internal/todo/handler.go -S "$DIR/scene-$SCENE.lua"

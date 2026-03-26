# java-server Development Guide

Single-file Emacs package for Java server container management (Tomcat, Spring Boot),
with JDK auto-detection and optional dape integration.  Does NOT include general
Java editing utilities (MyBatis navigation, decompilation) — those belong in
personal config or a separate package.

## Shared Guidelines

Also follow:
- `~/repos/coding-guidelines/general.md`
- `~/repos/coding-guidelines/elisp.md`

Keep this file focused on package-specific constraints that are not already covered there.

## First Principles

- **Question every abstraction**: Before adding a layer or indirection, ask "is this solving a real problem right now?" If the answer is hypothetical, don't add it.
- **Simplify relentlessly**: Three similar lines of code are better than a premature abstraction. This is a single-file package — keep it that way unless a genuinely distinct responsibility emerges.
- **Delete, don't deprecate**: If something is unused, remove it entirely. No backward-compatibility shims, no re-exports, no "removed" comments.

## Diagnosis and Testing

- **Find the root cause before changing behavior**: Do not stack timing or fallback patches without naming the failing layer.
- **After two failed fixes, stop patching and switch to diagnosis**: Gather logs, adapter events, or runtime evidence before changing behavior again.
- **Prefer failing regression tests for bug fixes**: When practical, add the test before the fix and make sure it proves the bug.
- **Errors must surface clearly**: Catch only at the outer boundary where the package can turn failures into user-facing messages.

## Architecture

- **No side effects on load**: Loading `java-server.el` must not alter Emacs behavior. All behavior activation goes through `java-server-mode` or `with-eval-after-load`.
- **No top-level `add-to-list`, `add-hook`, or `keymap-global-set`**: These belong inside `java-server-mode` activation or `with-eval-after-load` blocks.
- **Subprocess isolation**: Build/deploy subprocesses use project-specific JDK via `let`-bound `process-environment`. The global `JAVA_HOME` (used by eglot, apheleia, etc.) is never mutated by build/deploy commands.
- **Optional dependencies**: `dape`, `eglot`, `nerd-icons` are all optional. Guard with `featurep`, `fboundp`, `with-eval-after-load`, or `declare-function`.
- **Reuse Emacs infrastructure**: Use `completing-read`, `start-process-shell-command`, standard hooks, `define-minor-mode`, etc.

## Version Baseline

- **Emacs 29.1+** (for `when-let*`, `if-let*`, `keymap-set`).
- Do not silently raise this baseline.

## Naming

- **Public API**: `java-server-` prefix. No double dash for public symbols.
- **Internal/private**: `java-server--` double-dash prefix. Never call from outside this file.
- **Predicates**: multi-word names end in `-p` (e.g., `java-server--port-open-p`).
- **Unused args**: prefix with `_` (e.g., `(_event)`).

## Control Flow

- Avoid deep `let` -> `if` -> `let` chains. Favor flat, linear control flow using `if-let*`, `when-let*`.
- Use `pcase`/`pcase-let` for structured destructuring instead of nested `car`/`cdr`/`nth`.

## Error Handling

- **`user-error`** for user-caused problems (no project root, no Tomcat home, no JAR found). Does NOT trigger `debug-on-error`.
- **`error`** for programmer bugs only.
- **`condition-case`** to handle recoverable errors. Wrap non-essential operations (desktop notifications, port checks) so errors never block primary results.
- Error messages should state what is wrong, not what should be (e.g., "No Tomcat process found" not "Tomcat must be running").

## State Management

- **Plain `defvar`** for global state (process objects, status indicators, mode-line strings).
- **`defcustom`** for all user-configurable values. Always specify `:type` precisely and `:group 'java-server`.

## Function Design

- Keep functions under ~30 lines. Extract helpers when a function exceeds this.
- Name extracted helpers to describe WHAT they compute, not WHERE they're called from.
- Pure computation (no side effects) should be separate from process management.
- Interactive commands should be thin wrappers: validate input, call internal function, show feedback.

## Autoloads

- `;;;###autoload` only on interactive commands (`java-server-mode`, `java-server-tomcat-deploy`, `java-server-spring-boot-run`, `java-server-select-jdk`, etc.).
- Never autoload internal functions, defcustom, or defvar.
- Use `declare-function` for functions from optional dependencies to silence byte-compiler.

## nerd-icons

- Always guard with `(fboundp 'nerd-icons-faicon)`.
- Provide plain-text fallback when icons are unavailable.

## Pre-Commit Checklist

### 1. Read the full diff

```bash
git diff HEAD
```

### 2. Byte-compile with zero warnings

```bash
emacs -Q --batch -f batch-byte-compile java-server.el
```

### 3. Load test in clean Emacs

```bash
emacs -Q --batch --eval '(load "java-server.el")'
```

Must produce no errors and no side effects.

## Quality Checks

- `(byte-compile-file "java-server.el")` produces no warnings.
- All public functions have docstrings.
- File starts with `;;; -*- lexical-binding: t -*-` and ends with `(provide 'java-server)` / `;;; java-server.el ends here`.

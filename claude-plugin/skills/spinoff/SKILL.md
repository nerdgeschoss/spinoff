---
name: spinoff
description: How to work in a spinoff slot, a git worktree named <project>.<n> with its own devcontainer. Use when the working directory is such a slot, when a Bash call was blocked with a hint to use `spinoff exec`, when running the app, tests or any Ruby/Node toolchain command in a slot, or when a spinoff command fails.
---

# Working in a spinoff slot

A slot is a git worktree next to the project's main checkout, named `<project>.<n>` (for example `acme.0`). Each slot has its own devcontainer, with its own database and services. Your session runs on the host; only toolchain commands belong in the container.

## Run toolchain commands with `spinoff exec`

Run everything that needs the project's toolchain through `spinoff exec`: bundle, rails, rake, ruby, gem, rspec, rubocop, yarn, npm, npx, node and anything under `bin/`. For example:

```sh
spinoff exec bin/rails test
spinoff exec bundle exec rspec spec/models
spinoff exec yarn lint
```

- It runs in the container in the same subdirectory you're in, with the arguments exactly as given, and returns the command's own output and exit code.
- Exit code 125 means spinoff itself failed (the container didn't start, Docker isn't running, a tool is missing), not the command. Run `spinoff doctor` and follow its hints.
- The first call after the container was stopped starts it, which takes a few seconds.
- Long-running processes such as `bin/dev` or `bin/rails server` stay in the foreground. Run them in a background shell rather than detaching them.
- Plain host tools (git, file edits, searches, `gh`) don't need `spinoff exec`.

## Branches

The slot starts detached at the starting point; spinoff never creates, renames or deletes branches. Create one with git when you're ready to commit (`git switch -c <name>`) and push it before the session ends. When the session ends, spinoff releases the slot only if nothing would be lost. Uncommitted changes, unpushed commits or detached commits keep the slot locked, so push or discard them first.

## Reaching the app

The app runs inside the container. Check it from there, for example `spinoff exec curl -s localhost:3000`. Ports are only reachable from the host if the project's compose file publishes them, or through VS Code's port forwarding when the slot is open with `spinoff open`.

## Other commands

- `spinoff list`: the repo's slots, their branch, whether their container is running, and who holds them (`claude: <session>` for Claude Code sessions).
- `spinoff release --slot <n>`: release a slot from anywhere in the repo. Worktrees of subagents aren't released automatically, so release them when they're done.
- `spinoff doctor`: check that git, Docker, Docker Compose and the devcontainer CLI are set up, with a fix for everything that's missing.

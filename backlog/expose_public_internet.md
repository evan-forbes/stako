---
name: Expose Daemon To Public Internet
description: Backlog placeholder for safely exposing the stako daemon beyond the local machine.
type: backlog
---

# Expose Daemon To Public Internet

The first iteration of the stako daemon binds locally only. Public exposure is deferred.

## What this includes

- Authentication for remote callers (vs. trust-the-loopback model used initially).
- TLS termination strategy.
- Tunnel/relay vs. inbound port choices.
- Rate limiting and abuse controls.
- Audit logging for remote actions.
- Deciding which API surfaces (web view, MCP, control endpoints) are exposable at all.

## Why deferred

Local-only is enough to validate the stack model, web view, CLI, and MCP integration. Public exposure adds a meaningful security surface that should not be designed before the local API is stable.

# Product Design Guide

This document is the entry point for Magent product designs, covering writing rules,
section responsibilities, and the component design index. See [Architecture](../ARCHITECTURE.md)
for package-wide API, layer, ownership, and lifecycle boundaries. The relevant SPECs define
functional constraints and acceptance criteria.

## Writing Rules

- Keep component designs under `docs/design/` and register them in this document's index.
  The architecture document links to this guide.
- Label each design as current implementation or target design before the main content.
  Link to the relevant architecture or SPEC instead of copying requirements. Check source and tests
  before claiming behavior is implemented; target designs and their migration notes must satisfy
  the referenced SPECs.
- A component `Contract` defines both data and methods. Each method declaration is a normative
  implementation constraint, not an implementation walkthrough: its name, argument labels and
  order, types and optionality, return type, `throws` / `async`, isolation, access level,
  `static` / `mutating`, overloads, and defaults must not change during implementation.
- Derive states from differences in accepted input, allowed operations, resource ownership, and
  termination behavior. State the initial state, legal transitions, and responsible methods.
  Preserve distinct protocol modes such as SOCKS5 TCP relay and UDP association; do not impose
  a uniform state count or enum across components. Parsing, dialing, and pending writes remain
  method-flow steps unless they establish a distinct behavior boundary.
- Each component design declares its constrained component, owning type, and allowed extension
  scope. It lists exact Swift declarations for every product entry, lifecycle operation, protocol
  callback, and product-flow method it owns. Third-party callbacks identify their source.
  When a versioned SPEC defines a collaborator's exact declaration or data structure, cite that
  version and section: the citation is equally binding and should not duplicate the SPEC. Contract
  text then records only the component's necessary call responsibility.
- Do not expand a constrained method set through a private helper, extension, wrapper, protocol,
  or source file. Before adding, deleting, renaming, combining, overloading, or changing a
  signature, update the design with its caller, ownership, and reason, obtain user confirmation,
  then implement it. A design may keep a service-level dependency external when its API has not
  been designed; it must not invent a configuration parameter or placeholder API to fill the gap.
- Focus on component purpose, caller contracts, workflows, integration, and edge cases.
  Keep the component's identity distinct from its internal algorithm. Exclude algorithm explanations,
  data-structure details, and implementation walkthroughs; refer to SPECs for those constraints.
- SPECs must remain independent of product designs. References flow from design to SPEC;
  SPECs must not reference, depend on, or compare with product-design documents.
- Keep benchmark scenarios, commands, measurement methods, performance analysis, and results
  under `docs/benchmark/`. Designs only link to the relevant material.
- When moving documents, update incoming links, outgoing links, and indexes together.
  Preserve historical commit-qualified paths used to retrieve evidence.

## Section Structure

Component designs use four sections in this order: `Context`, `Contract`, `Core Logic`, and `Corners`.
Keep these English headings without translation. Body text may use Chinese, and subsections may be added
as needed. Place the document title, status, and reference links before the four sections.
This guide organizes design documents and does not itself follow the component design structure.

| Section | What to describe |
| --- | --- |
| `Context` | The problem the component solves, its callers and scope, and its responsibility and ownership boundaries with other components. |
| `Contract` | Inputs, outputs, configuration, defaults, error semantics, invariants, constrained type/extension scope, and exact method declarations callers can rely on. Reference the architecture or SPEC for shared constraints. |
| `Core Logic` | Main workflows, state transitions, integration, and lifecycle from the perspective of callers and collaborating components, without internal algorithm details or implementation walkthroughs. |
| `Corners` | Observable behavior for empty values, invalid input, failures, concurrency, shutdown, and other edge cases, including explicitly unsupported scenarios. |

Place migration notes under the relevant section and describe caller-visible differences.
Do not create a separate migration section or use migration notes as exceptions to the SPEC.

## Component Design Index

Statuses below follow each document's own declaration. A target design does not imply implemented behavior.

| Document | Status | Scope |
| --- | --- | --- |
| [MagentTCPConnection design](MagentTCPConnection-DESIGN.md) | Target design; runtime assembly required | Accepted TCP ownership, bounded protocol detection, constructors aligned with the four Connection contracts, data handoff and lifecycle. |
| [Socks4Connection design](Socks4Connection-DESIGN.md) | Target design; trailing-dot and runtime contracts require alignment | SOCKS4 / SOCKS4a CONNECT entry ownership, reply barrier, Wire integration, relay and lifecycle boundaries, governed by the [SOCKS4 SPEC](../SOCKS4_PROXY_SPEC.md) and [Wire SPEC](../WIRES_SPEC.md). |
| [Socks5Connection design](Socks5Connection-DESIGN.md) | Target design; model/Core and runtime contracts require alignment | No-auth method negotiation, TCP CONNECT and per-control-connection UDP associations; fixed method contracts and lifecycle under the current SOCKS5 scope and Wire SPEC. |
| [HttpConnectConnection design](HttpConnectConnection-DESIGN.md) | Target design; model/Core and listener contracts require alignment | CONNECT validation without inbound authentication, success barrier, bidirectional remainder and half-close; shared ProxyConnection contract and current HTTP/Wire scope. |
| [HttpForwardConnection design](HttpForwardConnection-DESIGN.md) | Target design; full HTTP model and service contracts require alignment | HTTP transactions without inbound authentication, chunked/trailers, Expect, ordered keep-alive/pipelining, WebSocket and subsequent CONNECT handoff. |
| [MagentCache design](MagentCache_Design.md) | Target design; source migration is pending | Cache caller contracts, Core integration, expiration, invalidation, and shutdown boundaries, governed by the [Cache SPEC](../W-TinyLFU_CACHE_SPCE.md). |
| [Routing and access control design](MagentAccessControl_Design.md) | Current implementation | Rule matching, node selection, runtime ownership, and decision caching, with current routing boundaries defined alongside the architecture. |

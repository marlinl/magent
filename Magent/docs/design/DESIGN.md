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
- Group each owning type's method contract into `非 private 方法` and `private 方法`, in that
  order, with declarations and their responsibilities under the corresponding group. Classify by
  the method's own access declaration: `internal`, `public`, `fileprivate`, and omitted access
  belong to the non-private group; `static` does not change the group. Non-private does not mean
  public API. If one group is empty, state that it has no methods; do not change access levels
  or signatures just to fit the grouping.
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
- Keep designs concise: define resource owners, meaningful states, completion/close ordering, and
  exact method declarations once. Give each method its caller and responsibility in a compact table;
  describe lifecycle transitions once instead of repeating the same flow per callback. Link to SPEC
  limits, parsing rules, error matrices, and acceptance vectors rather than copying them. Do not add
  types, layers, helpers, state cases, or configuration merely to make the document look complete.
- Design the smallest necessary member set before implementation. Do not turn an inventory of
  existing implementation fields into the target contract. For the current Connection designs,
  `MagentTCPConnection`, each concrete TCP Connection, and the existing
  `Socks5UDPConnection` have at most six instance members. The main handler owns the first-request
  buffer and the HTTP request length calculated after the head is complete; concrete initializers
  parse that handoff without I/O,
  and `start(context:)` begins protocol work only after the main handler installs the owner. Computed properties, static storage, and new owner types
  must not be used to bypass this limit. Constants may stay as documented method-local values.
- Prefer mutually exclusive protocol phases to independent Boolean flags for request acceptance,
  reply submission, startup, and cleanup. List every state case and associated value explicitly.
  Associated values must belong to that phase and disappear when it ends; moving the old field
  list into a `State`, context, tuple, dictionary, or captured mutable box is not simplification.
  Actual in-flight writes and EOF still need an explicit contract: state why each remaining
  completion barrier or byte reservation is necessary, rather than pretending it is temporary.
  Operation-local values may live until their one Future chain completes, but must not become
  a second connection owner or a permanent substitute for undeclared members.
- SPECs must remain independent of product designs. References flow from design to SPEC;
  SPECs must not reference, depend on, or compare with product-design documents.
- Keep benchmark scenarios, commands, measurement methods, performance analysis, and results
  under `docs/benchmark/`. Designs only link to the relevant material.
- When moving documents, update incoming links, outgoing links, and indexes together.
  Preserve historical commit-qualified paths used to retrieve evidence.

## Implementation Strict Mode

Implementing product requirements and refactoring their production code must use strict mode.
Read the applicable component design and its referenced architecture and SPECs before editing code.
The design's declarations, behavior, states, ownership, and lifecycle rules are binding implementation
constraints, including for private code; declared method and member sets are complete contracts, not examples.

- **Methods:** Do not add, delete, rename, split, combine, overload, or change a declared method
  without explicit user confirmation of the design change. Preserve every signature detail listed
  in Writing Rules, including initializers, lifecycle methods, and protocol callbacks.
- **Members:** The `Contract` must list exact declarations for all constrained instance and static
  members, including stored and computed properties. Preserve names, types, optionality, access levels,
  `let` / `var`, `static` / `class`, `lazy`, initial/default values, accessors, isolation, and
  strong/weak/unowned ownership where applicable. Initialization, allowed mutation entry points,
  state relationships, and lifetime are also binding. Do not add, remove, replace, or repurpose members,
  or change these constraints without explicit user confirmation of the design change.
- **No bypasses:** Apply the same rules to types, protocol conformances, enum cases, dependencies,
  and ownership boundaries. Private helpers, extensions, nested types, wrappers, protocols, extra
  files, closures, containers, property wrappers, or associated storage must not hide undeclared
  methods, persistent state, or responsibilities. Convenience, deduplication, testing, and optimization
  are not exemptions. Method-body details and local temporary values must stay within the documented contract.
- **Design gaps and changes:** If the design is missing, ambiguous, contradictory, or cannot support
  the requirement, stop the affected implementation. Identify the exact mismatch and propose the
  smallest design revision, recording the affected declarations, callers, ownership, and reason.
  Update the design and obtain explicit user confirmation before implementing that revision;
  do not change code first and rewrite the design afterward to justify it. A general request to
  implement or refactor does not authorize contract changes. Existing explicit approval of the
  specific change remains valid and does not need to be requested again. Continue unaffected work.
  A target-design label does not approve declarations that the document still marks as pending confirmation.
- **Verification:** Before delivery, compare the implementation against the design for method and
  member declarations, states, behavior, and resource ownership. Resolve unapproved deviations and
  report any remaining design gaps. Passing builds or tests does not replace this contract check.

## Section Structure

Component designs use four sections in this order: `Context`, `Contract`, `Core Logic`, and `Corners`.
Keep these English headings without translation. Body text may use Chinese, and subsections may be added
as needed. Place the document title, status, and reference links before the four sections.
This guide organizes design documents and does not itself follow the component design structure.

| Section | What to describe |
| --- | --- |
| `Context` | The problem the component solves, its callers and scope, and its responsibility and ownership boundaries with other components. |
| `Contract` | Inputs, outputs, configuration, defaults, error semantics, invariants, constrained type/extension scope, exact method and member declarations, and member initialization, mutation, ownership, and lifetime constraints. Reference the architecture or SPEC for shared constraints. |
| `Core Logic` | Main workflows, state transitions, integration, and lifecycle from the perspective of callers and collaborating components, without internal algorithm details or implementation walkthroughs. |
| `Corners` | Observable behavior for empty values, invalid input, failures, concurrency, shutdown, and other edge cases, including explicitly unsupported scenarios. |

Place migration notes under the relevant section and describe caller-visible differences.
Do not create a separate migration section or use migration notes as exceptions to the SPEC.

## Component Design Index

Statuses below follow each document's own declaration. A target design does not imply implemented behavior.

| Document | Status | Scope |
| --- | --- | --- |
| [MagentCore design](MagentCore-DESIGN.md) | Target design; implementation verification pending | Runtime-scoped rules, decision caching, node/Wire selection, and downstream Channel creation for Connection targets. |
| [MagentTCPConnection design](MagentTCPConnection-DESIGN.md) | Target design; implementation verification pending | Mixed-protocol accepted TCP ownership, unique dispatch and restart-scoped cleanup. |
| [Socks4Connection design](Socks4Connection-DESIGN.md) | Target design; six-member contract, source migration pending | Strict SOCKS4/4a CONNECT, reply barrier, Wire integration and half-close under the [SOCKS4 SPEC](../SOCKS4_PROXY_SPEC.md). |
| [Socks5Connection design](Socks5Connection-DESIGN.md) | Target design; six-member contract, source migration pending | No-auth negotiation, TCP CONNECT and UDP resources owned by each control connection. |
| [HttpConnectConnection design](HttpConnectConnection-DESIGN.md) | Target design; six-member contract, source migration pending | Model-based CONNECT validation, strict request ordering, success barrier and half-close. |
| [HttpForwardConnection design](HttpForwardConnection-DESIGN.md) | Target design; six-member contract, source migration pending | One complete request, model-based rewrite, transparent response relay and cleanup. |
| [MagentCache design](MagentCache_Design.md) | Target design; source migration is pending | Cache caller contracts, Core integration, expiration, invalidation, and shutdown boundaries, governed by the [Cache SPEC](../W-TinyLFU_CACHE_SPCE.md). |

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
| `Contract` | Inputs, outputs, configuration, defaults, error semantics, and invariants callers can rely on. Reference the architecture or SPEC for shared constraints. |
| `Core Logic` | Main workflows, state transitions, integration, and lifecycle from the perspective of callers and collaborating components, without internal algorithm details or implementation walkthroughs. |
| `Corners` | Observable behavior for empty values, invalid input, failures, concurrency, shutdown, and other edge cases, including explicitly unsupported scenarios. |

Place migration notes under the relevant section and describe caller-visible differences.
Do not create a separate migration section or use migration notes as exceptions to the SPEC.

## Component Design Index

Statuses below follow each document's own declaration. A target design does not imply implemented behavior.

| Document | Status | Scope |
| --- | --- | --- |
| [MagentCache design](MagentCache_Design.md) | Target design; source migration is pending | Cache caller contracts, Core integration, expiration, invalidation, and shutdown boundaries, governed by the [Cache SPEC](../W-TinyLFU_CACHE_SPCE.md). |
| [Routing and access control design](MagentAccessControl_Design.md) | Current implementation | Rule matching, node selection, runtime ownership, and decision caching, with current routing boundaries defined alongside the architecture. |

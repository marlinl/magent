# W-TinyLFU Cache Specification

Version: 1.0 draft

Date: 2026-09-22

Status: specification draft

## 1. Scope and normative level

This document defines an in-process, thread-safe W-TinyLFU cache whose capacity is limited by entry count.
The body specifies cache functionality, observable behavior, algorithmic invariants, resource boundaries, and acceptance criteria.

"Must" denotes a condition required for conformance with this specification; "should" permits an alternative with a stated rationale.
The API names in this document denote semantic operations; they do not require adding Swift protocols, wrapper layers, or source files with those names.

W-TinyLFU combines a small Window LRU, recent-frequency-based TinyLFU admission, and a Main SLRU.
TinyLFU determines whether a candidate is worth replacing a Main-cache victim, while Window gives new data a short-term residence opportunity.
This composition originates from the [TinyLFU paper](https://arxiv.org/abs/1512.00727).

The following are **product choices of this specification**, not requirements that every W-TinyLFU implementation must adopt:

- Fixed partitions, deterministic retention of the older item on equal frequency, and the counters and aging parameters specified below.
- A strict externally observable capacity bound, synchronously completed policy maintenance, and no dropped access records.
- TTL, invalidation barriers, removal notifications, loading, and close semantics.

v1 provides no persistence, distributed consistency, byte-weighted capacity, automatic refresh, dynamic expansion,
bulk APIs, single-flight load coalescing, background loaders, or adaptive Window sizing.
It does not promise a higher hit rate than LRU for arbitrary workloads, nor lock-free, wait-free, or worst-case O(1) operations.

## 2. Data, configuration, and terminology

### 2.1 Key and Value

- A Key must have stable equality and hashing; its relevant contents must not change while resident or participating in an unfinished operation.
- Equal Keys must have equal hashes, but equal hashes cannot substitute for Key equality.
- The cache performs no case folding, trimming, host normalization, or business-version inference.
- A String adapter should follow its language's equality semantics; canonically equivalent Swift `String` encodings must access the same entry.
- Keys and Values must be safe for cross-thread use; a Swift adapter requires `Sendable` conformance.
- The cache may retain references, but does not deep-copy Values or protect their internal state for callers.
- A miss must be distinguishable from a cached business null; for example, Swift uses an outer Optional to represent a miss.

Generic Key support is a semantic capability; an implementation that provides only String Keys may declare itself a String-restricted version of this specification.
The particular hash algorithm is not an external contract. Production should use a randomized hash or equivalent protection;
a public fixed hash should not be presented as a collision-attack guarantee.

### 2.2 Configuration

| Configuration | Default | Constraints |
|---|---|---|
| `capacity = C` | required | Non-negative integer; charged by resident entry count |
| `expiration` | `never` | One of `never`, `afterWrite(T)`, or `afterAccess(T)` |
| `onRemoval` | none | Optional, thread-safe, non-throwing callback that receives key/value/reason |

Invalid configuration must be rejected when the instance is created, without publishing a partially initialized instance.
Negative capacity, non-positive TTL, TTL that cannot be represented at the supported time precision, and integer overflow in partition, sketch, or time calculations are all invalid configuration.
Implementations must not rely on integer wraparound or silently clamp an invalid parameter to a different valid configuration.
A language adapter declares its supported maximum capacity and time precision; it cannot promise that every non-negative `Int` can be allocated.

`C = 0` disables storage: get misses, contains is false, size is 0, and put has no effect.
Optional loading operations may still execute their loader; a disabled instance must not allocate policy space related to its nominal capacity or start scheduled maintenance.
A bypass result that never entered the cache does not trigger a removal notification.

### 2.3 State terminology

- **resident entry**: a key/value version that still exists in the map and may have expired without yet being physically removed.
- **valid entry**: a resident, current version that has not expired at the operation's time-observation point.
- **candidate**: an entry evicted from the Window LRU end; it is not the newly arrived entry.
- **victim**: an entry selected from the Probation LRU end when Main is full.
- **commit**: the atomic boundary at which a change takes effect for other operations.
- **request record**: one logical access counted in the frequency sketch; see §5.2.

## 3. Operation contract

### 3.1 Required operations

| Operation | RUNNING state | CLOSED state |
|---|---|---|
| `get(key)` | Returns a valid Value or a miss; hits update access order | miss |
| `contains(key)` | Checks validity only; does not record access, renew expiry, or adjust order | false |
| `put(key, value)` | Inserts or replaces, completing capacity and policy adjustments before commit | no-op |
| `invalidate(key)` | Invalidates the current entry and publication eligibility of same-key loads started earlier | no-op |
| `removeAll()` | Clears resident entries, policy and frequency history, and revokes publication eligibility of all existing loads | no-op |
| `estimatedSize()` | Returns the resident count at an atomic observation point, possibly including uncollected expired items | 0 |
| `cleanUp()` | Removes all resident entries expired at this operation's time-observation point | no-op |
| `close()` | Enters the terminal state and releases resident state held by the cache | idempotent no-op |

The cache-state changes of these operations must be linearizable: each call has an effect point between invocation and return,
and concurrent observations must correspond to a serial execution order that preserves real-time ordering.
Loaders and user callbacks run outside cache-state commits and are not part of that atomic region.

"Empty after clear" and "readable after write" are both defined at their respective commit points.
If another thread or reentrant callback subsequently modifies the cache, the state may have changed by the time the operation returns.
A concurrent removal before a get returns does not retroactively invalidate a result read at an earlier valid-time point.

### 3.2 Writes and replacements

Every direct put must record one request.
If the same key has expired, first remove its old version as `expired`, then insert the new entry.
If the same key has a valid value, replace the value version without changing the resident count, and update the order of its partition as for one hit.
Notify the valid old version as `replaced`, even when the old and new Values are equal or refer to the same object.

New entries enter at Window MRU. A put is not a promise of permanent retention; later operations may evict it.
Puts at capacity 0 and in CLOSED do not record requests or notify a value that was never cached.

### 3.3 Presence and size

contains may remove an expired entry that it observes, but must not turn observation into a hot access.
estimatedSize does not clean up, renew expiry, or record frequency; its result must always lie in `[0, C]`.
Its "estimated" nature means it can differ from the count of valid entries and a caller's later observation, not that arbitrary incorrect counts are permitted.

## 4. W-TinyLFU partitions and state transitions

### 4.1 Fixed capacity allocation

Use integer division, rounding down:

```text
C = 0: W = 0, M = 0, P = 0
C > 0:
    W = max(1, floor(C / 100))
    M = C - W
    P = floor(4 * M / 5)
```

W is the Window limit, M is the whole Main limit, and P is the Protected limit.
Computing `4 * M / 5` must avoid intermediate multiplication overflow.
Probation may occupy all Main space not used by Protected; it has no fixed independent hard limit.
`M - P` is the space left for Probation when Main is full and Protected has reached its limit.

| C | W | M | P |
|---:|---:|---:|---:|
| 0 | 0 | 0 | 0 |
| 1 | 1 | 0 | 0 |
| 2 | 1 | 1 | 0 |
| 3 | 1 | 2 | 1 |
| 100 | 1 | 99 | 79 |
| 101 | 1 | 100 | 80 |
| 200 | 2 | 198 | 158 |
| 4096 | 40 | 4056 | 3244 |

The 1%/80% split is a fixed v1 default policy, not a theorem of optimal proportions.
Dynamic ratios and workload-based hill climbing belong to a later, separate policy version.

### 4.2 Hits

| Hit location | Transition |
|---|---|
| Window | Move to Window MRU |
| Probation | Remove from Probation and enter Protected MRU |
| Protected | Move to Protected MRU |

When Protected exceeds P, demote entries from Protected LRU to Probation MRU until the limit is satisfied.
Demotion does not remove an entry, change the total count, or trigger a callback.
When `P = 0`, a Probation hit remains in Probation and moves to its MRU; no Protected node is retained.

### 4.3 Complete insertion and admission order

The following pseudocode describes the semantics of one new-entry insertion. Time `now` is sampled once for this cache transaction;
frequency request recording has already completed as specified by §5. Cleanup, insertion, and eviction are published externally as one commit.

```text
insertNew(entry, now):
    remove every resident entry with deadline <= now, reason expired
    add entry to the map and Window MRU

    while Window.count > W:
        candidate = Window.removeLRU()

        if M == 0:
            remove candidate, reason capacity
        else if Probation.count + Protected.count < M:
            add candidate to Probation MRU
        else:
            victim = Probation.LRU
            if frequency(candidate.key) > frequency(victim.key):
                remove victim, reason capacity
                add candidate to Probation MRU
            else:
                remove candidate, reason admissionRejected
```

Compare frequency only when Main is full and both candidate and victim are valid at this time-observation point.
On equal frequency retain the victim. When Main has a free slot, accept the candidate directly; a low frequency must not leave that slot unused.

When the partition invariants hold, `M > 0` and full Main necessarily imply a Probation node because `P < M`.
Failure to find a victim is an internal-structure error; an implementation should not silently evict Protected to conceal the inconsistency.

When TTL or explicit removal creates space, do not proactively move Main nodes back to Window or require capacity to be filled immediately.
However, nodes expired at this observation point must not compete on frequency to reject or displace a valid candidate.

### 4.4 Invariants

The following must hold after every cache-state commit:

1. `0 <= map.count <= C`, and `map.count = Window.count + Probation.count + Protected.count`.
2. `Window.count <= W`, `Probation.count + Protected.count <= M`, and `Protected.count <= P`.
3. Every resident entry belongs to exactly one partition; every partition node can find the map entry with the same identity in reverse.
4. List heads and tails, previous and next links, and counts agree; there are no cycles, duplicate links, or removed nodes.
5. A key has at most one resident value version; an old-version event cannot remove or alter a replacement version.
6. A removed node is eventually no longer retained by the map, a partition, the expiry index, or an internal cache event.

An unpublished critical section may temporarily hold one candidate awaiting insertion, but other APIs cannot observe capacity overflow.
The capacity limit applies to entry count; it is not a limit on all in-process Value references or total memory bytes.

## 5. TinyLFU frequency estimation

### 5.1 Fixed v1 parameters

v1 uses an aging Count-Min Sketch without a Doorkeeper.
This is the specific TinyLFU approximation selected by this document; it does not claim to reproduce every optimization from the paper or Caffeine.

| Parameter | Rule |
|---|---|
| Row count d | 4 |
| Per-row width L | `nextPowerOfTwo(max(1, C))`; do not allocate when C=0 |
| Counter range | 0…15, saturating increment |
| Estimate | The minimum of the four corresponding counters |
| First aging threshold S | `10 * C`, used only when C>0 |
| Aging | Right-shift every counter by 1; request count `q = floor(q / 2)` |

Each request increments the corresponding counter in each of four rows; counters already at 15 do not increase further; request count q always increases by 1.
When `q >= S`, complete that record first, then age the whole table.
Thus the first aging occurs at S requests, and later aging usually occurs every S/2 requests.
This order also applies to an admission operation that happens to trigger aging; admission uses the aged estimate.

The four row indices must be properly mixed to avoid degenerating into one hash bucket; seeds and index functions remain stable within an instance.
Hash collisions and counter saturation can cause inaccurate estimates and incorrect rejections, but cannot change the map's key/value correctness.
Frequency is bounded, approximate recent popularity, not exact LFU or a fixed wall-clock-time window.
No frequency aging occurs while there are no requests; TTL uses an independent clock mechanism.

### 5.2 How many times one request is recorded

| Behavior | Frequency records | Order/TTL behavior |
|---|---:|---|
| Direct get hit | 1 | Hit move; renew afterAccess expiry |
| Direct get miss or finds expiry | 1 | No hit move; remove expired entry |
| Direct put insertion or replacement | 1 | Insert or hit move; update write/access time |
| First query of getOrLoad | 1 | Handle a hit as get; a miss starts loading |
| Second query and successful refill of the same getOrLoad | 0 | Returning an existing value may perform a hit move and renewal; refill acts as a new insertion |
| contains, size, cleanup, invalidation, close | 0 | Follow their respective contracts |
| Partition promotion/demotion, internal add/remove event | 0 | Do not record frequency again |

A caller that first invokes get and then getOrLoad makes two independent API requests and may record twice in total.
A loader error does not revoke its first miss record; an absent key also needs popularity history.
invalidate, expiry, and capacity eviction do not attempt to subtract a key from shared counters, which would corrupt estimates for colliding keys.
removeAll clears the whole sketch; loaders started before it must not repollute that frequency history when they complete.

v1 does not drop logical request records or allow an expired read's frequency record to disappear because of "lazy deletion."
Approximation comes from sketch collisions, saturation, and aging, not an additional undefined layer of event sampling.

## 6. Expiry

### 6.1 Time rules

Use a monotonic clock. The implementation must declare its time unit and maximum representable duration; rounding must not extend the requested TTL.
TTL must be greater than 0 at the supported time precision. Deadline calculations must check overflow.

| Policy | Deadline |
|---|---|
| never | No deadline and no expiry index |
| afterWrite(T) | Time of most recent successful insertion or replacement + T |
| afterAccess(T) | Time of most recent successful insertion, replacement, or hit read + T |

`now >= deadline` means expired; access exactly at the boundary must miss.
Reading and renewal are one cache transaction: an expired entry cannot be revived by that read.
A valid afterAccess put renews expiry; contains and size do not renew it.
A loader's TTL begins when its result is successfully published, not when the loader starts.

afterAccess renews on both reads and writes. This is an explicit choice of this specification and agrees with
[Caffeine's expireAfterAccess definition](https://github.com/ben-manes/caffeine/wiki/Eviction).
It is distinct from the alternative valid product semantic of renewing only on reads.

### 6.2 Logical expiry and physical collection

get/contains must synchronously determine whether the target key is valid.
Before inserting a new entry, remove every resident item expired at this time point, then perform capacity competition.
After cleanUp completes, no node expired at its time-observation point remains.

No background task is required during idle periods, so expiry need not release memory as soon as it occurs without calls.
Expired objects cannot continue to hit or use their historical high frequency to prevent a new object from using space on the next insertion.
An optional timer may only trigger the same cleanUp semantics; it cannot be required for read correctness or capacity safety.

An updatable deadline index is recommended, such as a min-heap with one index item per resident node.
afterAccess renewal should update the existing index item; it must not append obsolete timer records that never converge on every read.
If lazy invalidation records are used, the implementation must provide a hard budget proportional to C and a compaction rule.

## 7. Concurrent loading and invalidation barriers

### 7.1 Optional loading operation

An implementation may provide `getOrLoad(key, loader)`. loader is a synchronous, throwing function supplied by the caller;
it runs on the calling thread and outside every cache lock; the cache creates no background loading task.
Multiple misses for the same key may execute the loader repeatedly; different calls are not promised to return the same object.
Return errors unchanged, do not cache failures, and do not rename or wrap loader errors as other business errors.

When the cache is closed, a new getOrLoad must report `CacheClosed` and must not silently start its loader.
At capacity 0 while still RUNNING, invoke the loader and return its result, bypassing storage completely.
Once a loader has started, close does not forcibly interrupt it; it may return a result or throw its original error, but can no longer publish a result.

### 7.2 Two-phase rules

The first query, frequency recording, and miss-load ticket registration must complete in one cache transaction.
A ticket represents whether this load remains eligible to publish; it neither represents that the key is resident nor coalesces loaders.
If the first query finds an expired node, remove the old node before registering this ticket so removal of the old node cannot revoke the newly started load.

```text
first query:
    closed -> CacheClosed
    capacity is 0 -> call loader outside the lock, return directly
    record one request; valid value hit -> update hit state and return
    miss -> register load ticket, then call loader outside the lock

after loader success, in one cache transaction:
    closed -> do not publish; return this loader result
    key currently has a valid value -> return it, update hit state but do not record frequency again
    ticket is revoked -> do not publish; return this loader result
    otherwise -> atomically reconfirm key absence and commit the loaded result without recording frequency again

unregister this load ticket on every success, error, and close path
```

Result checking and publication must be one conditional commit operation; an unprotected "second get, then put" is forbidden.
If refill encounters an expired old node, it must remove it and reconfirm the ticket; it cannot skip the invalidation condition.

### 7.3 What revokes an old load

| Committed operation | Revoked load-publication eligibility |
|---|---|
| invalidate(k), including when k is absent | Every load for k registered before it |
| put(k, v) or successful publication of k by one load | Other previously registered loads for k |
| Expiry, capacity eviction, or admission rejection of k | Previously registered loads for k |
| removeAll / close | Every previously registered load |

Writes or invalidations that do not involve k must not revoke k's load eligibility.
If capacity adjustment for put(j) actually evicts k, it involves k and must revoke k's old tickets by the removal rule.
A revoked loader may still return its computed result to its original caller; the guarantee is that it is no longer written to the cache.
If the business requires even the original request to be denied an old result, it must separately define business-version checking or cancellation semantics.

An implementation may use a global-clear generation plus per-key publication versions, or an equivalent ticket-invalidation mechanism.
It must not permanently retain tombstones or versions for every key ever seen: metadata may exist only with a resident item or an unfinished load.
Version reuse must avoid ABA; overflow must not silently make an old ticket valid again.

### 7.4 Required interleaving examples

```text
L1: miss(k), register ticket, start reading old data
I : invalidate(k) returns, or removeAll() returns
L1: loader returns old
Requirement: L1 may return old to its original caller, but old must not reappear in the cache as a result

L1: miss(k), begin loading old
P : put(k, new) commits
L1: loader returns old
Requirement: if new remains valid, L1 returns new; it cannot overwrite new

L1, L2: concurrently load the same missing key
L1: successfully publishes v1
I : invalidate(k)
L2: completes
Requirement: L2 must not republish a result whose load began before invalidation
```

## 8. Concurrency implementation and maintenance boundaries

The v1 correctness reference model is a serial state machine: related changes to the map, partitions, frequency records, deadlines, and load tickets commit together.
An implementation may use one lock or another concurrent design that can demonstrate equivalence.
No dedicated thread, DispatchQueue, EventLoopGroup, actor, or read/write buffer is required.

v1 requires policy changes to finish with the operation; "drain later" cannot explain observable capacity overflow, reordering, or lost accesses.
Batching and parallel maintenance are internal optimizations only when they preserve the observable semantics above.
If a future version chooses bounded temporary excess or lossy access sampling, it must publish another explicit contract version and error boundary.

Loaders and removal callbacks must not be invoked while holding the cache lock.
Destruction or release of Key/Value may execute user code; replacement and removal should release the last cache reference outside the lock.
Key hashing and equality may run in the map-lookup critical section; callers should ensure they neither block nor reenter this cache.

Synchronous APIs may incur lock waiting, sketch aging, or batch expiry-cleanup costs.
The absence of a future alone must not be used to claim suitability for a latency-sensitive NIO EventLoop; whether to call on an EventLoop
must be evaluated with the loader, capacity, TTL, and tail-latency budget.

## 9. Removal notifications and lifecycle

### 9.1 onRemoval

The notification payload must include the removed version's key, value, and reason:

| reason | Meaning |
|---|---|
| capacity | A resident item was evicted for capacity or partition competition |
| admissionRejected | A Window candidate did not pass frequency comparison when Main was full |
| expired | It had expired at the operation's time-observation point |
| explicit | Removed by invalidate |
| cleared | Removed by removeAll |
| replaced | A valid Value was replaced |
| closed | close removed a remaining resident item |

Each value version that was ever resident is allowed exactly one removal reason and one notification.
Storing the same object under two keys forms two independent entries; replacing with the same object also forms a new value version.
Invalid puts, unpublished load results, movement within partitions, and duplicate removals do not notify.

The reason is determined by the operation that wins the commit; when an operation has found expiry, expired takes priority over subsequent explicit removal or replacement.
For example, if invalidate observes an expired item, notify expired; only a valid item notifies explicit.
removeAll/close may uniformly classify resident items not already removed by another path as cleared/closed respectively;
they need not perform a per-item TTL check again for bulk clearing.

After the locked state ends, the operation that initiated removal invokes callbacks synchronously; they may reenter the cache.
Callbacks on different threads may run concurrently, and execution order does not represent commit order; slow callbacks increase the initiating operation's duration.
A callback grants no resource lease: another thread may still hold the just-returned Value, so a notification cannot establish that no one uses it.

### 9.2 close

close must complete in this order; the first three items form the cache-state commit and the fourth runs after commit:

1. RUNNING enters irreversible CLOSED and revokes all existing load-publication eligibility.
2. Clear the map, every partition, frequency, and deadline index; the resident count becomes 0.
3. Stop any optional future scheduled-maintenance commits and release the related resources owned by the cache.
4. Outside the lock, notify the versions removed this time with reason closed.

Repeated close does not notify again or wait for user callbacks or loaders already started by another thread.
The first close does not wait for loaders to complete either; it does not own cancellation capability for loaders.
Removal callbacks already committed by other operations but not yet finished may complete after close.
Thus close is a **cache-state and publication-eligibility barrier**, not a completion barrier for all user code.

Releasing the instance must not leave an ARC retain cycle. Explicit close provides deterministic close notifications;
object destruction requires only resource release and does not make arbitrary user callbacks during destruction.

## 10. Complexity and resource budget

The following assumes O(1) Key hashing/equality and fixed-width integer operations, with no adversarial hash-table collisions.
Actual String hashing and comparison also include key-length cost; lock waiting, loader time, and callback time are separate.

| Operation/structure | Cost and boundary |
|---|---|
| Map lookup, partition move, one admission | Expected O(1) |
| One frequency record | Usually O(1); whole-table aging is O(C) in one worst case and amortized O(1) by record count |
| get/put without TTL | Expected amortized O(1), excluding lock waiting |
| Indexed TTL check/update | O(log C) with a min-heap; the clock check itself is O(1) |
| New insertion collecting e expired items | O((e+1) log C) with a min-heap; in the worst case it can involve the entire cache |
| removeAll / close | O(C + A), where A is the number of active load records the implementation must process |
| cleanUp | Depends on expired-node count and deadline-index design; it must not be declared constant time |
| Policy space | O(C) for map, lists, deadline index, and sketch together |
| Loading space | O(A), depending on simultaneously executing caller loaders rather than total historical keys |

The O(1) writes in the table assume active loads for the same key share one revocable marker and updating it does not traverse every ticket.
If an implementation revokes tickets one by one, it must include the number of active loads for that key in write and removal complexity.

The theoretical counter payload of the four-row sketch is `4 * L * 4 bit = 2L bytes`; storing counters as UInt8 makes it `4L bytes`.
This excludes array, node, object, lock, and allocator overhead; the counter payload must not be presented as total memory cost.

Cache capacity does not limit concurrent loader count, Value size, or returned values held by callers.
When a strict process-memory budget is required, callers must also limit load concurrency and object size, or use a different weighted-cache specification.

## 11. Acceptance specification

### 11.1 Deterministic functionality and policy

Tests should use an advanceable reference clock and independent reference model to construct boundaries rather than guessing order with long sleeps.
The reference clock may belong to the specification model; this does not require adding test-only hooks to the production API.
Integration tests for a production implementation must still verify real-time and real-concurrency boundaries.

| ID | Scenario | Must satisfy |
|---|---|---|
| A01 | C=0; get/put/getOrLoad | No residents or removal notifications; a RUNNING loader can still execute |
| A02 | C=1, sequentially insert A/B | A is removed for capacity, B is resident, and Main is empty |
| A03 | C=2/3/100/101/4096 | Matches the §4.1 table and every partition invariant holds |
| A04 | Main has a free slot | Candidate enters Probation unconditionally |
| A05 | Main is full; candidate estimate is greater than/less than/equal to victim | Accept/reject/reject respectively, with the correct callback reason |
| A06 | A Window hot item and a new insertion coexist | Candidate is Window LRU; the newly inserted MRU cannot be selected incorrectly |
| A07 | Probation hit and Protected excess | Map count is unchanged after promotion and demotion |
| A08 | Probation hit with P=0 | It remains in Probation and Protected remains empty |
| A09 | Direct get miss, hit, put; loading refill | Each logical request records frequency only as §5.2 specifies |
| A10 | Counter reaches 15, q reaches S | No counter wraparound; age at the specified time |
| A11 | Hotset migration after a cold scan | Report hit rate and adaptation; do not assert "always better than LRU" |
| A12 | Hash collision, equal keys with different representations | Values do not cross-contaminate; an equal key has one entry |
| A13 | Cached business null | Outer hit and miss are distinguishable |

### 11.2 TTL and notifications

| ID | Scenario | Must satisfy |
|---|---|---|
| E01 | Before, exactly at, and after deadline | hit, miss, miss |
| E02 | Repeated reads under afterWrite | Do not extend TTL |
| E03 | afterAccess read, put, contains | The first two renew; contains does not |
| E04 | A hot item has expired and a new key needs space | Remove the expired item first; its high frequency cannot reject a valid candidate |
| E05 | Rewrite the same key after expiry | Old version expires once; new version has an independent deadline |
| E06 | cleanUp after a long idle period | Resident expired items and their index entries are removed at the observation point |
| E07 | Continuously renew one key for a long time | Deadline index does not grow without bound with cumulative read count |
| E08 | Replacement, removal, callback reentry | One notification per version; key/value/reason match the actually removed version |

### 11.3 Concurrency, loading, and close

| ID | Scenario | Must satisfy |
|---|---|---|
| C01 | Concurrent get/put/invalidate/removeAll | History satisfies §3.1 and the full structure check passes |
| C02 | Another thread continuously observes size during writes | Always `0 <= size <= C` |
| C03 | Pause loader after miss, then invalidate or removeAll | Old result cannot refill |
| C04 | put a new value while loader is paused | Old result cannot overwrite the new value |
| C05 | Two loaders, with publication then invalidation in between | The later finisher cannot revive an invalidated key |
| C06 | invalidate while the same key is missing | Can still revoke previously registered load eligibility for that key |
| C07 | Write/invalidation does not involve target key | Does not revoke unrelated load eligibility; must revoke when it evicts the target key incidentally |
| C08 | Loader throws | Original error is returned, no failed entry, ticket is unregistered |
| C09 | Loader/callback reenters cache | Does not deadlock by holding an internal lock |
| C10 | close races with get/put/loading | No refill or resident item after close; new loading reports CacheClosed |
| C11 | Concurrent or reentrant repeated close | Idempotent; no duplicate notification or wait for its own callback |
| C12 | Unbounded historical keys, bounded load concurrency | Tombstone/ticket space grows only with current residents or active loads |
| C13 | Release cache without explicit close | No resource retain cycle; no need to send compensating business callbacks |

Concurrent interleavings must use barriers/semaphores to control crucial ordering; randomized stress tests can only supplement, not replace, these interleaving tests.
Structure checks should cover bidirectional consistency between map and partitions, the deadline index, and active tickets, not only final size.
Swift concurrency checking, Thread Sanitizer, and real integration tests are distinct evidence and should be reported separately.

### 11.4 Performance acceptance

A benchmark must cover at least: stable hotsets, uniform random access, one-time scans, hotset migration, write-heavy workloads, batched TTL expiry,
long keys, single-thread operation, and multithread contention on a shared cache.
For every run, record source version, build mode, device, capacity, working set, request distribution, random seed, warmup, and measurement interval.

Report throughput, p50/p95/p99, effective hit rate, loader invocation count, peak resident count, and actual memory.
When internal counts are provided, report expired, capacity, and admissionRejected separately; hit quality cannot be inferred from one total-removal count.
The reference implementation and LRU use the same trace, capacity, and loading cost; do not mix request throughput with loader throughput.
Record latency not actually collected as "not measured"; do not use 0 as a substitute.
This specification has no historical QPS threshold; set a concrete performance budget after the implementation target and hardware are determined.

## Appendix A: References and scope boundary

1. [TinyLFU: A Highly Efficient Cache Admission Policy](https://arxiv.org/abs/1512.00727):
   Algorithmic background and admission based on recent popularity; this document's concurrency and lifecycle contract is an independent product design.
2. [Caffeine Design](https://github.com/ben-manes/caffeine/wiki/Design):
   Illustrates implementation ideas such as sketches, partitions, and batched maintenance. Caffeine's adaptive partitioning, lossy read recording, and concurrency optimizations are not inherited automatically by this document.
3. [Caffeine Eviction](https://github.com/ben-manes/caffeine/wiki/Eviction):
   Used to check afterWrite/afterAccess terminology; this document's strict capacity and cleanup timing must be implemented independently as specified in its body.

These sources support the algorithmic and terminology background; they do not prove the correctness of every product choice in this document.

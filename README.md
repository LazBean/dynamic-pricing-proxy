# Dynamic Pricing Proxy

A Rails service that sits in front of a dynamic pricing model API ([tripladev/rate-api](https://hub.docker.com/r/tripladev/rate-api)) and caches results to stay within its usage limits.

## Quick Start

```bash
# Build and run
docker compose up -d --build

# Test the endpoint
curl 'http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'
```

## Running Tests

```bash
# Full test suite
docker compose exec interview-dev ./bin/rails test

# Specific file
docker compose exec interview-dev ./bin/rails test test/controllers/pricing_controller_test.rb
```

## Design Decisions

### The Problem

The upstream rate API has two hard constraints:

- A fetched price is valid for up to **5 minutes**
- Hard limit of **1,000 requests/day**

First thing that came to mind — the service needs to handle **10,000+ requests/day** from users, but without caching the upstream limit would be gone in minutes.

---

### What I Found in the Existing Code

Before writing anything I read through the scaffold and found a few things to fix:

**Bug: error handling**
While testing I noticed that sometimes the API returns `{"error":"error"}` — a completely useless error message. Digging into the code I found why: on API failure, `rate.body` is a JSON string, but the code treated it as a Hash (`rate.body['error']`). In Ruby, calling `[]` on a String does a substring search — so `'{"error":"some message"}'['error']` returns `"error"`, not the actual message. The real error from the upstream API was silently swallowed every time.

**Bug: nil result on success**
If the API returns `200` but the requested combination is missing from the `rates` array, `@result` is `nil` while `valid?` returns `true`. The controller would silently return `{ rate: null }`.

**Inconsistent rate type**
Running the endpoint a few times I noticed the rate API returns the rate sometimes as a `String`, sometimes as an `Integer`. Consumers shouldn't have to deal with this.

**No timeout**
No timeout on the HTTP client — if the rate API is slow or stuck, our service just waits forever.

---

### Error Handling

I fixed the bugs above and made the service return proper status codes depending on what went wrong:

- **Invalid request** (bad params) → `400 Bad Request` — already validated in the scaffold, kept as-is
- **Rate API error or unexpected response** → `502 Bad Gateway`
- **Rate API timeout or network failure** → `503 Service Unavailable`

I also considered returning a stale cached price when the API fails, but decided against it — an old price is worse than no price here, someone could book a room at the wrong rate.

The API token is moved out of the source code into an environment variable in `docker-compose.yml`.

---

### Caching Strategy

**Individual vs. batch fetching**

My first instinct was to cache each `(period, hotel, room)` combo separately and fetch from the API on a miss. Then I worked through the numbers: 36 unique combinations, cache TTL of 5 minutes, means up to 288 refreshes per combo per day — `36 × 288 = 10,368 API calls/day`. That is 10x over the 1,000-call limit.

The rate API accepts multiple combinations in a single POST and that counts as **one call** against the daily limit. So I fetch all 36 combinations at once on any cache miss and cache each result for 5 minutes. This caps usage at **288 API calls/day** regardless of user traffic.

Tradeoff: I fetch all 36 even when only one was needed. For 36 fixed combinations that's fine. If the catalog ever grew to thousands of entries, the smarter move would be to group by `hotel` or `period` and only fetch the relevant subset on a miss.

**Cache backend**

Rails ships with several cache store implementations out of the box. I went through them to find what fits best here:

| Option      | Pros                                      | Cons                                         |
| ----------- | ----------------------------------------- | -------------------------------------------- |
| MemoryStore | Zero dependencies                         | Not shared across processes, lost on restart |
| FileStore   | Shared on same host                       | Slow                                         |
| **Redis**   | Shared across processes, fast, native TTL | Requires an extra container                  |

Redis is the right choice. Without it, each Puma worker maintains its own separate cache and the same upstream API call gets repeated across workers.

---

### Structured Logging

I added structured log lines for cache hits, cache misses, upstream response time, and errors. Mainly so that if something goes wrong in production you can actually tell what happened — was it a cache miss storm? A slow upstream? An error from the API? Without logs you're just guessing.

The assignment mentioned logging, metrics, or traces. Logging felt like the right fit here — it's a single service, not a distributed system. Prometheus-style metrics would make more sense once you have multiple services and need to dashboard things.

---

### Concurrency

After implementing the cache I realized there's a potential race condition on cold start: if several requests hit the service at the same moment and the cache is empty, they all see a miss and all go to the upstream API at once. With a batch fetch that's the daily quota gone in seconds.

After finding out about possible solutions I landed on a `Mutex` with double-checked locking. A plain mutex doesn't fully solve it — threads waiting for the lock will still all fetch one after another once they get in. The fix is to re-check the cache after acquiring the lock. If another thread already did the work while you were waiting, you skip the fetch and use what's already there.

I also looked at a Redis lock (`SET NX EX`) instead, which would cover the same race across multiple processes too. Decided it was overkill here — the cross-process window is tiny and a few extra calls at cache expiry don't meaningfully affect the daily budget. Something to add if the number of processes grows.

---

### Tests

The existing tests had two problems: they were mocking `RateApiClient.get_rate` (single fetch, which no longer exists), and the error response body was a Hash when HTTParty actually returns a String. I had to update the mocks to match real behavior.

For the new caching logic I also hit an issue with the test cache store — `null_store` silently discards all writes, so any cache hit/miss test would never work. Switched to `memory_store` in the test environment and added `Rails.cache.clear` in setup to keep tests isolated from each other.

New tests I added:

- Cache hit — pre-populate cache, verify the upstream API is never called
- Single upstream call — two identical requests, assert `get_rates` was called exactly once
- 502 on API error, 503 on timeout, 502 when the rate is missing from the response
- Rate normalized to Integer regardless of what the upstream returns

---

## Summary

The core issue — users send 10k requests/day but the upstream API only allows 1k. The fix is a Redis cache with a 5-minute TTL that fetches all 36 combinations in one batch call on any miss, which keeps upstream usage under 300 calls/day.

Along the way I also found and fixed several bugs in the scaffold that would have caused problems regardless of caching. The result is a service that handles the throughput requirement, stays well within quota, and fails gracefully when the upstream is unavailable.

Total time spent on the assignment: ~4 hours.

---

## AI Usage

This solution was developed with Claude Code (claude-sonnet-4-6) as a coding assistant. The architecture, design decisions, and trade-off analysis reflect my own reasoning. Claude was used to help write and validate the implementation.

---

## Changelog

| Commit                                                                  | Description                                                                |
| ----------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `fix: add timeout and move API token to env`                            | 10s timeout on HTTP client, token moved to env var                         |
| `fix: proper error handling, status codes, and rate type normalization` | Fixed `body['error']` bug, added 502/503 codes, normalized rate to Integer |
| `chore: add Redis for caching`                                          | Redis in docker-compose, configured as Rails cache store                   |
| `feat: implement bulk caching with Redis`                               | Batch fetch all 36 combinations on miss, cache each for 5 min              |
| `fix: prevent double error when upstream fetch fails`                   | Added `return unless valid?` to stop overwriting error status              |
| `feat: add structured logging to PricingService`                        | Log cache hit/miss, upstream response time, errors                         |
| `test: rewrite and expand test suite`                                   | Updated mocks, added cache/error/timeout/normalization tests               |
| `refactor: remove unused get_rate method`                               | No longer called anywhere; replaced by get_rates                           |
| `refactor: deduplicate validation constants`                            | Controller now references PricingService constants instead of redefining   |
| `fix: prevent race condition with double-checked locking`               | Class-level Mutex serializes upstream fetches within a single process      |
| `docs: finalize README`                                                 | Updated concurrency section to reflect Mutex implementation                |

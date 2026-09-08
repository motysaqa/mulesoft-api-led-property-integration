# Request walkthrough

One request, end to end:

```
GET /channel/v1/properties/PROP-1001/quote?checkIn=2026-06-01&checkOut=2026-06-05&guests=2&currency=EUR
```

## Happy path

```mermaid
sequenceDiagram
    autonumber
    participant CM as Channel manager
    participant AM as API Manager policies
    participant EXP as Experience API
    participant PRC as Process API
    participant SP as System API (property)
    participant SR as System API (rates)
    participant BP as Property backend
    participant BR as Legacy rates (SOAP)

    CM->>AM: GET /quote<br/>client_id, Bearer JWT
    Note over AM: client ID enforcement → JWT validation<br/>→ rate limit → IP allowlist
    AM->>EXP: forwarded + X-Correlation-ID

    Note over EXP: APIKit validates against the RAML<br/>checkOut → lastNight = checkOut − 1 day
    EXP->>PRC: GET /availability-pricing?from=06-01&to=06-04

    Note over PRC: validate range and guests
    par Parallel (scatter-gather)
        PRC->>SP: GET /properties/PROP-1001/availability
        SP->>BP: GET /backend/v1/.../availability
        BP-->>SP: calendar (units, closed flags)
        Note over SP: availability-to-canonical.dwl<br/>two flags → one `bookable`
        SP-->>PRC: canonical availability
    and
        PRC->>SR: GET /rates?propertyId=...&ratePlanCode=STD
        Note over PRC: cache miss
        SR->>BR: SOAP GetRates
        BR-->>SR: GetRatesResponse (AmountMinor)
        Note over SR: rates-to-canonical.dwl<br/>cents → decimal, "" → null
        SR-->>PRC: canonical rates
    end

    Note over PRC: store rates in Object Store (TTL 300s)<br/>merge-availability-pricing.dwl:<br/>join by date · FX · occupancy · tax · group by month
    PRC-->>EXP: canonical quote

    Note over EXP: quote-to-channel.dwl<br/>flatten months, rename to partner terms
    EXP-->>AM: 200 Quote + X-Correlation-ID
    AM-->>CM: 200
```

The two system calls run in parallel, so worst-case latency is
`max(property, rates)` rather than their sum. On a cache hit the rates branch
returns without leaving the process API at all.

## Failure path: the rates backend is down

```mermaid
sequenceDiagram
    autonumber
    participant EXP as Experience API
    participant PRC as Process API
    participant SR as System API (rates)
    participant BR as Legacy rates (SOAP)

    EXP->>PRC: GET /availability-pricing
    PRC->>SR: GET /rates
    SR->>BR: SOAP GetRates
    BR--xSR: connection refused
    Note over SR: until-successful (inner): retry ×3 @ 500 ms
    SR->>BR: retry
    BR--xSR: connection refused
    Note over SR: until-successful (outer): wait 2 s, repeat the burst
    SR->>BR: retry
    BR--xSR: connection refused
    Note over SR: RETRY_EXHAUSTED → global handler
    SR-->>PRC: 502 BACKEND_UNAVAILABLE (+ correlationId)
    Note over PRC: scatter-gather reports<br/>MULE:COMPOSITE_ROUTING
    PRC-->>EXP: 502 DOWNSTREAM_UNAVAILABLE
    Note over EXP: SERVICE_UNAVAILABLE, no internals leaked
    EXP-->>EXP: 502 to the partner, same correlationId
```

Two decisions are worth calling out, because both are the kind of thing that goes
wrong silently:

- **A 404 is not a retry.** The property system API adds `404` to the request
  validator's success codes so an unknown property never burns four retries and
  four seconds before returning the answer it already had.
- **A partial merge is a wrong answer, not a partial one.** If the rates branch
  fails, the process API returns 502 rather than a quote with missing prices.
  A channel manager that receives a price sells at that price.

## Failure path: a night has no rate

Not an error. The merge marks the night `priced: false`, lists it under
`gaps.unpricedDates`, and sets `quotable: false`. The partner gets a 200 with an
explicit reason it cannot sell the stay, which is far more useful than a 502 —
and it is covered by
`merge-separates-unpriced-nights-from-unavailable-ones` in the MUnit suite.

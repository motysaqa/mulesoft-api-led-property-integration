# Troubleshooting

This file is split deliberately. The first section is problems that actually
occurred while building this repository, with the real error text. The second is
traps that are documented and designed around here but that I have **not**
reproduced in this repo — they are labelled as such rather than dressed up as
war stories.

---

## Part 1 — Hit while building this repository

### `NETSDK1022: Duplicate 'Content' items were included`

**Where:** building the property-backend mock.

```
error NETSDK1022: Duplicate 'Content' items were included. The .NET SDK includes
'Content' items from your project directory by default. You can either remove
these items from your project file, or set the 'EnableDefaultContentItems'
property to 'false' ... The duplicate items were: 'data\properties.json'
```

**Cause:** the csproj used `<Content Include="data\properties.json" .../>` to get
the sample data copied to the output directory. The Web SDK already globs that
file as `Content`, so `Include` added it a second time.

**Fix:** use `Update`, not `Include` — it attaches metadata to the item the SDK
already created:

```xml
<Content Update="data\properties.json" CopyToOutputDirectory="PreserveNewest"/>
```

### Mock data was not reproducible across restarts

**Where:** both mocks, before they were ever committed.

**Symptom:** the availability calendar and the nightly rates for the same
property and date changed every time the process was restarted, which would have
made the contract tests intermittently fail for no reason.

**Cause:** both mocks derived their pseudo-random values from
`string.GetHashCode()`. .NET randomises string hash codes per process by design
(it is a hash-flooding mitigation), so the "deterministic" seed was anything but.

**Fix:** an explicit FNV-1a hash in both mocks, so the same input always yields
the same bucket:

```csharp
static uint StableHash(string value)
{
    unchecked
    {
        uint hash = 2166136261;
        foreach (var c in value) { hash ^= c; hash *= 16777619; }
        return hash;
    }
}
```

**Wider lesson:** any test fixture built on a hash needs the hash pinned. The
same applies to `Guid.GetHashCode()`, `Random` without a seed, and
`DateTime.Now` anywhere in a fixture.

### The MUnit suites have not been executed

Stated plainly because the alternative is dishonest: Maven is not installed in the
environment this repo was authored in, and the Mule runtime plus the MUnit
plugins are distributed from MuleSoft's credentialed EE repository. The suites in
`*/src/test/munit/` are written against the flows in this repo and the expected
values were computed by hand from the fixtures (see the header comment in
`merge-availability-pricing-test-suite.xml`), but **they have not been run**.

The .NET mocks, by contrast, were built and exercised: the property backend was
verified to filter by city, return a 404 for an unknown property, and produce a
day-by-day calendar; the SOAP mock was verified to return a well-formed
`GetRatesResponse` and a SOAP 1.1 fault with HTTP 500.

Run the suites yourself with `scripts/run-tests.sh` once you have credentials
configured (see [setup.md](setup.md)), and correct any expected value that turns
out to be off before showing this repo to anyone.

---

## Part 2 — Designed around, not reproduced here

These are the failure modes the code deliberately guards against. They are
documented behaviour of Mule 4 and the connectors, not incidents from this build.

### Retry and backoff

`until-successful` in Mule 4 has a **fixed** `millisBetweenRetries`. There is no
`multiplier` attribute and no jitter, which surprises people arriving from
Polly, Resilience4j or Spring Retry.

The approximation used here nests two scopes:

```xml
<until-successful maxRetries="1" millisBetweenRetries="2000">      <!-- outer -->
  <until-successful maxRetries="3" millisBetweenRetries="500">     <!-- inner -->
    <http:request .../>
  </until-successful>
</until-successful>
```

Quick retries absorb a blip; one longer pause covers a restart. It is not true
exponential backoff and it has no jitter — for that you need either a custom Java
component or the retry built into the connector's reconnection strategy.

Two things that bite here:

- **`until-successful` retries anything that throws**, including a 404 that came
  back as an `HTTP:NOT_FOUND` error. That is why the request validators in this
  repo add `404` to the success codes: a business "no" must not cost four
  attempts. Do the same for any status that is an answer rather than a failure.
- **The scope's payload does not survive by default.** Use `target` on the
  request (as the system APIs do) or the payload after the scope may not be what
  you expect.

### Scatter-gather failures

Any route failing makes the whole scope raise `MULE:COMPOSITE_ROUTING`, and the
individual failures are inside `error.errorMessage.payload.failures`, keyed by
route index — not in `error.description`. Logging `error.description` alone tells
you nothing about *which* branch failed. The process API's handler logs the
route indices for exactly that reason.

Scatter-gather also does not short-circuit: if route 0 fails immediately, route 1
still runs to completion.

### Web Service Consumer

- **Package the WSDL with the app.** Pointing `wsdlLocation` at a live URL means
  the app fails to *deploy* when the legacy host is down, which turns a partial
  outage into a total one. The WSDL here lives in
  `src/main/resources/wsdl/` and the endpoint address stays configurable.
- **A SOAP fault is `WSC:SOAP_FAULT`, not a connectivity error.** Handling only
  `WSC:CONNECTIVITY` sends every business rejection down the 502 path. The rates
  system API maps the fault to 422 separately.
- **Namespaces are mandatory in the DataWeave that reads the response.**
  `payload.body.GetRatesResponse` silently yields `null`; you need
  `ns rates http://legacy.rates.portfolio.com/` and `payload.body.rates#GetRatesResponse`.
  A `null` here looks exactly like an empty result, so it is worth asserting on.
- **A single repeated element is not an array.** One `<DailyRate>` reads as an
  object, several read as an array. `as Array` normalises it —
  `rates-to-canonical.dwl` does this and the comment explains why.

### APIKit flow names must match the RAML exactly

APIKit derives flow names from the specification:

```
get:\properties\(propertyId)\quote:experience-api-config
```

URI parameters use `(parentheses)`, not `{braces}`, and the config name suffix
must match `<apikit:config name="...">`. Get it wrong and you get
`APIKIT:NOT_IMPLEMENTED` at runtime with a perfectly valid-looking flow sitting
right there. Studio's "Generate flows from spec" avoids the whole class of typo.

### DataWeave gotchas exercised by this code

- **`default` catches `null`, not coercion failures.** `"abc" as Date default null`
  raises rather than returning null. Validate the shape first — the date checks in
  this repo use a regex plus a lexicographic compare on ISO strings, which is
  both correct and cheap.
- **`skipNullOn = "everywhere"` removes null keys from the output.** Consumers
  must treat "absent" and "null" as the same thing. The OAS spec marks
  `QuoteNight.price` as optional for this reason.
- **`groupBy` yields arrays**, so a lookup index needs `[0]` on the way out:
  `(ratesByDate[date] default [])[0]`.
- **Round money once.** Rounding per operation accumulates error; the FX module
  converts, then the merge applies the surcharge, then `round2` runs once.

### Environment issues that look like code issues

| Symptom | Actual cause |
|---|---|
| `401 Unauthorized` downloading `mule-*-ee` artifacts | No Anypoint credentials in `~/.m2/settings.xml` |
| `Unsupported class file major version` on build | JDK 8 or 11; Mule 4.6 needs JDK 17 or 21 |
| App deploys but every request 500s at start-up | `config-dev.yaml` missing — copy it from `config-example.yaml` |
| `Address already in use` | Another Mule app on the same port; the four apps use 8080–8083 and the mocks 5081–5082 |
| APIKit returns 404 for a path that is in the RAML | The RAML on the classpath is stale; `mvn clean` and redeploy |

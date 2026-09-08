# Mock backends

Two standalone .NET 8 services that stand in for the systems of record. They are
part of the repository so the whole integration can be run from a fresh clone
with no access to anything external.

| Service | Port | Protocol | Stands in for |
|---|---|---|---|
| `property-backend` | 5081 | REST / JSON | The property and inventory system |
| `legacy-rates-soap` | 5082 | SOAP 1.1, document/literal | A legacy rate engine |

```bash
../scripts/run-mocks.sh start
../scripts/run-mocks.sh stop
```

## They are awkward on purpose

A mock that returns exactly the canonical model proves nothing. These reproduce
the specific shapes that make system APIs worth writing:

- a nested `address` object and `maxOccupancy` rather than `capacity`
- amenity **codes**, not labels
- two independent "you cannot book this" flags (`closed`, `closedToArrival`)
- SOAP amounts as **minor units** in a `long`
- `<PromotionCode/>` present but empty rather than absent
- business errors as **SOAP faults with HTTP 500**, not as HTTP 4xx

## Determinism

Both derive their values from an explicit FNV-1a hash of the inputs, so the same
property and date always yield the same answer across restarts. .NET randomises
`string.GetHashCode()` per process, which broke this during development — see
`docs/troubleshooting.md`.

## Fault injection

The property backend accepts a `fail` query parameter, which is how the retry and
error mapping in the Mule layer are exercised without unplugging anything:

```bash
curl "http://localhost:5081/backend/v1/properties?fail=500"      # HTTP 500
curl "http://localhost:5081/backend/v1/properties?fail=timeout"  # 30-second stall
```

The SOAP mock returns a fault for any `PropertyId` starting with `UNKNOWN`:

```bash
curl -X POST -H 'Content-Type: text/xml' \
     --data '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><GetRates xmlns="http://legacy.rates.portfolio.com/"><PropertyId>UNKNOWN-1</PropertyId><RatePlanCode>STD</RatePlanCode><FromDate>2026-06-01</FromDate><ToDate>2026-06-02</ToDate></GetRates></soap:Body></soap:Envelope>' \
     http://localhost:5082/LegacyRatesService
```

## Sample data

`property-backend/data/properties.json` holds six synthetic properties in
Valencia, Faro and Amsterdam. `PROP-1006` is `INACTIVE` on purpose: the process
layer must filter it out, and `contract_tests.py` asserts that it does.

All data is invented. Nothing here derives from any real property, operator or
booking platform.

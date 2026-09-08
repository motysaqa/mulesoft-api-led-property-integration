%dw 2.0

/**
 * Static FX table and money formatting helpers.
 *
 * A production process API would call a rates provider (and cache it); keeping the
 * table here makes the pricing transformation deterministic and unit-testable,
 * which is exactly what the MUnit assertions depend on.
 *
 * Rates are expressed as "1 unit of `from` = N units of EUR".
 */

var toEur = {
  "EUR": 1.0,
  "USD": 0.92,
  "GBP": 1.17,
  "AED": 0.25,
  "SAR": 0.245,
  "JOD": 1.30
}

var symbols = {
  "EUR": "€",
  "USD": "$",
  "GBP": "£",
  "AED": "AED ",
  "SAR": "SAR ",
  "JOD": "JOD "
}

/** True when both currencies are in the table, i.e. a conversion is possible. */
fun canConvert(from: String, to: String): Boolean =
  (toEur[from] != null) and (toEur[to] != null)

/**
 * Convert via EUR. Returns null rather than a wrong number when either currency
 * is unknown, so the caller has to decide what an unquotable stay looks like.
 */
fun convert(amount: Number, from: String, to: String): Number | Null =
  if (from == to) amount
  else if (!canConvert(from, to)) null
  else round2((amount * toEur[from]) / toEur[to])

/** Half-up to 2 decimals. Money is rounded once, at the end, never per operation. */
fun round2(n: Number): Number = round(n * 100) / 100

fun symbolFor(currency: String): String = symbols[currency] default (currency ++ " ")

/** e.g. formatMoney(1234.5, "EUR") -> "€1,234.50" */
fun formatMoney(amount: Number | Null, currency: String): String | Null =
  if (amount == null) null
  else symbolFor(currency) ++ (amount as String {format: "#,##0.00"})

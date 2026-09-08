%dw 2.0
output application/json skipNullOn = "everywhere"

/**
 * Canonical availability+pricing -> channel-manager quote.
 *
 * The process layer answers in stay terms (from/to nights). A channel manager
 * books in hotel terms (check-in/check-out), so the last charged night is the
 * night before check-out and that translation lives here, at the edge, rather
 * than leaking a channel convention into the shared process model.
 *
 * The month grouping the process API produces is flattened back to a single
 * ordered list, because this consumer renders a table, not a calendar.
 */

var ccy = payload.currency default "EUR"

fun money(amount, formatted) =
  if (amount == null) null
  else { amount: amount, currency: ccy, formatted: formatted default (amount as String) }
---
{
  propertyId: payload.propertyId,
  checkIn:    vars.checkIn,
  checkOut:   vars.checkOut,
  nights:     payload.stay.nights default 0,
  guests:     payload.stay.guests default (vars.guests default 2),
  ratePlanCode: payload.stay.ratePlanCode default "STD",
  sellable:   payload.quotable default false,

  nightly: (valuesOf(payload.calendar default {})
              flatMap ((month) -> month.nights default [])
              orderBy ((n) -> n.date)) map (n) -> {
    date:         n.date,
    dayOfWeek:    n.dayOfWeek,
    available:    n.bookable default false,
    price:        money(n.amount, n.amountFormatted),
    restrictions: n.restrictions default []
  },

  totals: {
    subtotal: money(payload.pricing.subtotal default 0, payload.pricing.subtotalFormatted),
    tax:      money(payload.pricing.tax default 0, payload.pricing.taxFormatted),
    total:    money(payload.pricing.total default 0, payload.pricing.totalFormatted)
  },

  // Surfaced so the partner can grey out the exact nights instead of retrying blind.
  unavailableDates: (payload.gaps.unavailableDates default []) ++ (payload.gaps.unpricedDates default []),

  correlationId: correlationId
}

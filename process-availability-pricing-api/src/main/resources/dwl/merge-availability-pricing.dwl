%dw 2.0
output application/json skipNullOn = "everywhere"

import * from modules::FxRates

/**
 * Merge an availability calendar with a rate calendar into one quotable stay.
 *
 * Inputs (set by the flow, never read from the HTTP payload directly):
 *   vars.availability   canonical availability from system-property-api
 *   vars.rates          canonical rates from system-legacy-rates-soap-api
 *   vars.guests         requested party size
 *   vars.targetCurrency ISO code the channel wants to be quoted in
 *
 * The interesting parts, and why they are here rather than in the experience API:
 *   - the two calendars are joined by date, not by position, because either side
 *     may be missing nights;
 *   - a night with availability but no rate is "unpriced", which is different from
 *     "unavailable" and the channel needs to tell them apart;
 *   - money is converted once and rounded once, at the end;
 *   - nights are grouped by month so a long stay renders as a calendar, not a list.
 */

var guests        = (vars.guests default 1) as Number
var targetCcy     = upper((vars.targetCurrency default "EUR") as String)
var sourceCcy     = upper((vars.rates.currency default "EUR") as String)
var taxRate       = (p('pricing.defaultTaxRate') default "0.10") as Number
var nights        = (vars.availability.nights default []) as Array

// groupBy yields one-element arrays, so the lookup takes the head. Building the
// index once keeps the join linear instead of scanning the rate list per night.
var ratesByDate   = ((vars.rates.rates default []) as Array) groupBy ((r) -> r.date as String)

fun rateFor(date: String) = (ratesByDate[date] default [])[0]

fun dayName(date: String): String = (date as Date) as String {format: "EEEE"}

fun isWeekend(date: String): Boolean = ["Friday", "Saturday"] contains dayName(date)

/**
 * Party-size surcharge. Two guests are the baseline; each extra guest adds 15%,
 * which is the kind of rule that belongs in the process layer because neither
 * system of record knows about it.
 */
fun occupancyMultiplier(n: Number): Number =
  if (n <= 2) 1.0 else 1.0 + (0.15 * (n - 2))

var priced = nights map (night) -> do {
  var rate      = rateFor(night.date as String)
  var baseMajor = if (rate == null) null else (rate.amount as Number)
  // Convert first, then apply the surcharge, then round exactly once.
  var converted = if (baseMajor == null) null else convert(baseMajor, sourceCcy, targetCcy)
  var nightly   = if (converted == null) null else round2(converted * occupancyMultiplier(guests))
  ---
  {
    date:         night.date,
    dayOfWeek:    dayName(night.date as String),
    weekend:      isWeekend(night.date as String),
    bookable:     (night.bookable default false) as Boolean,
    restrictions: night.restrictions default [],
    // Null here is meaningful: the night exists in inventory but carries no rate.
    amount:       nightly,
    amountFormatted: formatMoney(nightly, targetCcy),
    promotionCode: rate.promotionCode default null,
    priced:       nightly != null
  }
}

var quotable      = priced filter ((n) -> n.bookable and n.priced)
var subtotal      = round2(sum(quotable map ((n) -> n.amount as Number)) default 0)
var tax           = round2(subtotal * taxRate)
var total         = round2(subtotal + tax)
var unavailable   = priced filter ((n) -> !n.bookable) map ((n) -> n.date)
var unpriced      = priced filter ((n) -> n.bookable and !n.priced) map ((n) -> n.date)
---
{
  propertyId: vars.availability.propertyId default vars.rates.propertyId default null,
  stay: {
    from: vars.availability.requestedRange.from default (nights[0].date default null),
    to:   vars.availability.requestedRange.to default (nights[-1].date default null),
    nights: sizeOf(nights),
    guests: guests,
    ratePlanCode: vars.rates.ratePlanCode default "STD"
  },
  currency: targetCcy,
  // A channel manager can only sell the stay when every night is both open and priced.
  quotable: sizeOf(nights) > 0 and sizeOf(unavailable) == 0 and sizeOf(unpriced) == 0,

  // Grouped by calendar month so a multi-month stay renders as month blocks.
  calendar: (priced groupBy ((n) -> (n.date as Date) as String {format: "yyyy-MM"}))
    mapObject ((monthNights, month) -> {
      (month): {
        label: (month ++ "-01") as Date as String {format: "MMMM yyyy"},
        nights: monthNights orderBy ((n) -> n.date),
        bookableNights: sizeOf(monthNights filter ((n) -> n.bookable)),
        monthSubtotal: round2(sum((monthNights filter ((n) -> n.bookable and n.priced)) map ((n) -> n.amount as Number)) default 0)
      }
    }),

  pricing: {
    subtotal: subtotal,
    subtotalFormatted: formatMoney(subtotal, targetCcy),
    taxRate: taxRate,
    tax: tax,
    taxFormatted: formatMoney(tax, targetCcy),
    total: total,
    totalFormatted: formatMoney(total, targetCcy),
    averageNightly: if (sizeOf(quotable) == 0) null else round2(subtotal / sizeOf(quotable)),
    // Reported so the channel can see when a converted price is being shown.
    sourceCurrency: sourceCcy,
    converted: sourceCcy != targetCcy,
    occupancyMultiplier: occupancyMultiplier(guests),
    weekendNights: sizeOf(quotable filter ((n) -> n.weekend))
  },

  gaps: {
    unavailableDates: unavailable,
    unpricedDates: unpriced
  },

  meta: {
    source: "process-availability-pricing-api",
    correlationId: correlationId,
    generatedAt: now() as String {format: "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"}
  }
}

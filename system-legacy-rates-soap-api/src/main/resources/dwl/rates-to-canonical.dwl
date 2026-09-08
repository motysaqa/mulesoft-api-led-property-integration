%dw 2.0
output application/json skipNullOn = "everywhere"
ns rates http://legacy.rates.portfolio.com/

/**
 * SOAP GetRatesResponse -> canonical rate calendar.
 *
 * Three legacy quirks are absorbed here so nothing above the system layer has to
 * know about them:
 *   1. Amounts arrive as minor units (cents) in a long, not a decimal.
 *   2. A single DailyRate element is not wrapped in an array by the XML reader,
 *      so it has to be coerced with `as Array`.
 *   3. Empty PromotionCode elements arrive as "" rather than being absent.
 */

var response = payload.body.rates#GetRatesResponse

// XML with one repeated child reads as an object, with many as an array.
var dailyRates = (response.rates#DailyRates.*rates#DailyRate default []) as Array

fun minorToMajor(minor) = ((minor default 0) as Number) / 100

fun blankToNull(s) = if ((s default "") as String == "") null else (s as String)
---
{
  propertyId:   response.rates#PropertyId as String,
  ratePlanCode: response.rates#RatePlanCode default "STD",
  currency:     upper((response.rates#Currency default "EUR") as String),
  rates: dailyRates map (rate) -> {
    date:          rate.rates#Date as String,
    // Kept as a Number so the process layer can do arithmetic without reparsing.
    amount:        minorToMajor(rate.rates#AmountMinor),
    amountMinor:   (rate.rates#AmountMinor default 0) as Number,
    taxIncluded:   (rate.rates#TaxIncluded default false) as Boolean,
    promotionCode: blankToNull(rate.rates#PromotionCode)
  },
  meta: {
    count: sizeOf(dailyRates),
    source: "system-legacy-rates-soap-api",
    correlationId: correlationId
  }
}

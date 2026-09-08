%dw 2.0
output application/json skipNullOn = "everywhere"

/**
 * Backend -> canonical availability calendar.
 *
 * The backend returns one row per night with an inventory counter. The canonical
 * shape the process layer wants is a per-date list plus a summary it can use to
 * short-circuit pricing when nothing is bookable.
 */

fun isBookable(night) =
  ((night.unitsAvailable default 0) as Number > 0) and
  ((night.closed default false) as Boolean == false)
---
{
  propertyId: payload.propertyId as String,
  requestedRange: {
    from: vars.fromDate,
    to:   vars.toDate
  },
  nights: (payload.calendar default []) map (night) -> {
    date:           night.date as String,
    unitsAvailable: (night.unitsAvailable default 0) as Number,
    minStay:        (night.minimumStay default 1) as Number,
    // Two independent backend flags collapse into one decision for callers.
    bookable:       isBookable(night),
    restrictions: [
      if ((night.closed default false) as Boolean) "CLOSED" else null,
      if (((night.minimumStay default 1) as Number) > 1) "MIN_STAY" else null,
      if ((night.closedToArrival default false) as Boolean) "CLOSED_TO_ARRIVAL" else null
    ] filter ($ != null)
  },
  summary: {
    totalNights:    sizeOf(payload.calendar default []),
    bookableNights: sizeOf((payload.calendar default []) filter isBookable($)),
    fullyAvailable: sizeOf((payload.calendar default [])) > 0 and
                    sizeOf((payload.calendar default []) filter (not isBookable($))) == 0
  },
  meta: {
    source: "system-property-api",
    correlationId: correlationId
  }
}

%dw 2.0
output application/json skipNullOn = "everywhere"

/**
 * Backend -> canonical property list.
 *
 * The backend speaks its own dialect (nested address object, `maxOccupancy`,
 * amenity codes). Everything above the system layer sees only this shape, so a
 * backend rename never reaches the process or experience APIs.
 */

var amenityLabels = {
  "WIFI":     "Wi-Fi",
  "POOL":     "Swimming pool",
  "PARK":     "Parking",
  "AC":       "Air conditioning",
  "KITCHEN":  "Kitchen",
  "PETS":     "Pet friendly",
  "BALCONY":  "Balcony"
}

fun labelFor(code) = amenityLabels[code as String] default (code as String)

fun trimmed(s) = (s default "") as String trim
---
{
  properties: (payload.items default payload default []) map (p) -> {
    propertyId:   p.id as String,
    name:         trimmed(p.name),
    // Null-safe: a backend record with no address still yields a usable object.
    city:         trimmed(p.address.city default ""),
    countryCode:  upper(trimmed(p.address.countryCode default "")),
    postalCode:   p.address.postalCode default null,
    capacity:     (p.maxOccupancy default 0) as Number,
    bedrooms:     (p.bedrooms default 0) as Number,
    ratePlanCode: p.ratePlanCode default "STD",
    amenities:    (p.amenities default []) map (code) -> {
      code:  code as String,
      label: labelFor(code)
    },
    active: (p.status default "ACTIVE") == "ACTIVE"
  },
  meta: {
    count: sizeOf(payload.items default payload default []),
    source: "system-property-api"
  }
}

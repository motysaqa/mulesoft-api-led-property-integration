%dw 2.0
output application/json skipNullOn = "everywhere"

/**
 * Canonical property list -> channel-manager list.
 *
 * Two things happen here that deliberately do not happen further down:
 *   - amenities collapse from {code, label} objects to plain labels, because the
 *     partner renders them and never matches on them;
 *   - paging is applied at the edge, so the process layer stays stateless about
 *     how any one consumer wants to page.
 */

var all      = (payload.properties default []) as Array
var page     = (vars.page default 1) as Number
var pageSize = (vars.pageSize default 20) as Number
var offset   = (page - 1) * pageSize
---
{
  items: (all[offset to (offset + pageSize - 1)] default []) map (p) -> {
    propertyId:  p.propertyId,
    name:        p.name,
    city:        p.city,
    countryCode: p.countryCode,
    capacity:    p.capacity default 0,
    bedrooms:    p.bedrooms default 0,
    amenities:   (p.amenities default []) map ((a) -> a.label default (a as String))
  },
  page: page,
  pageSize: pageSize,
  total: sizeOf(all)
}

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

// Mock property/inventory backend.
//
// This stands in for the system of record that system-property-api wraps. It
// deliberately speaks the awkward dialect a real one would: a nested address,
// `maxOccupancy` rather than `capacity`, amenity codes rather than labels, and a
// day-by-day calendar with two independent "you cannot book this" flags.
//
// It also supports fault injection (?fail=timeout|500) so the retry and error
// mapping in the Mule layer can be exercised without unplugging anything.

var builder = WebApplication.CreateBuilder(args);

// Fixed port so the Mule config and the run scripts agree; ASPNETCORE_URLS still wins.
if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("ASPNETCORE_URLS")))
    builder.WebHost.UseUrls("http://localhost:5081");

builder.Services.ConfigureHttpJsonOptions(o =>
{
    o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
    o.SerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
});

var app = builder.Build();

var dataPath = Path.Combine(AppContext.BaseDirectory, "data", "properties.json");
var properties = JsonSerializer.Deserialize<List<Property>>(
                     File.ReadAllText(dataPath),
                     new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                 ?? throw new InvalidOperationException($"No sample data at {dataPath}");

const string Base = "/backend/v1";

app.MapGet("/health", () => Results.Ok(new { status = "UP", service = "property-backend-mock" }));

app.MapGet($"{Base}/properties", async (string? city, int? minCapacity, string? fail) =>
{
    if (await Fault.Apply(fail) is { } fault) return fault;

    var results = properties
        .Where(p => city is null || string.Equals(p.Address.City, city, StringComparison.OrdinalIgnoreCase))
        .Where(p => minCapacity is null || p.MaxOccupancy >= minCapacity)
        .ToList();

    return Results.Ok(new { items = results, total = results.Count });
});

app.MapGet($"{Base}/properties/{{propertyId}}/availability", async (
    string propertyId, string? from, string? to, string? fail) =>
{
    if (await Fault.Apply(fail) is { } fault) return fault;

    var property = properties.FirstOrDefault(p =>
        string.Equals(p.Id, propertyId, StringComparison.OrdinalIgnoreCase));

    // A real inventory system answers 404 for an unknown id; the Mule layer relies
    // on that being distinguishable from a transport failure.
    if (property is null)
        return Results.NotFound(new { code = "PROPERTY_NOT_FOUND", propertyId });

    if (!TryParseDate(from, DateOnly.FromDateTime(DateTime.UtcNow), out var start) ||
        !TryParseDate(to, start.AddDays(29), out var end) ||
        end < start)
    {
        return Results.BadRequest(new { code = "INVALID_RANGE", from, to });
    }

    var calendar = new List<Night>();
    for (var day = start; day <= end; day = day.AddDays(1))
        calendar.Add(NightFor(property, day));

    return Results.Ok(new { propertyId = property.Id, calendar });
});

app.Run();

// Deterministic pseudo-availability: the same date always yields the same answer,
// so a demo or a test run is reproducible instead of flaky.
static Night NightFor(Property property, DateOnly day)
{
    var bucket = (int)(StableHash($"{property.Id}:{day.DayNumber}") % 100);

    var closed = bucket < 8;
    var closedToArrival = !closed && bucket is >= 8 and < 12;
    var units = closed ? 0 : 1 + (bucket % 4);
    var minimumStay = bucket is >= 90 ? 2 : 1;

    return new Night(
        day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        units,
        minimumStay,
        closed,
        closedToArrival);
}

// .NET randomises string hash codes per process, so a stable hash is required for
// "the same request always returns the same answer" to actually hold across runs.
static uint StableHash(string value)
{
    unchecked
    {
        uint hash = 2166136261;
        foreach (var c in value)
        {
            hash ^= c;
            hash *= 16777619;
        }
        return hash;
    }
}

static bool TryParseDate(string? value, DateOnly fallback, out DateOnly result)
{
    if (string.IsNullOrWhiteSpace(value))
    {
        result = fallback;
        return true;
    }

    return DateOnly.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture,
        DateTimeStyles.None, out result);
}

static class Fault
{
    /// <summary>
    /// Fault injection for the retry/error-handling tests.
    /// `?fail=timeout` stalls past any sane response timeout; `?fail=500` returns a
    /// server error. Returns null when the request should be served normally.
    /// </summary>
    public static async Task<IResult?> Apply(string? fail)
    {
        switch (fail?.ToLowerInvariant())
        {
            case "timeout":
                await Task.Delay(TimeSpan.FromSeconds(30));
                return Results.Ok(new { note = "you should never see this" });
            case "500":
                return Results.Json(new { code = "BACKEND_ERROR" }, statusCode: 500);
            default:
                return null;
        }
    }
}

record Address(string City, string CountryCode, string? PostalCode);

record Property(
    string Id,
    string Name,
    Address Address,
    int MaxOccupancy,
    int Bedrooms,
    string RatePlanCode,
    List<string> Amenities,
    string Status);

record Night(string Date, int UnitsAvailable, int MinimumStay, bool Closed, bool ClosedToArrival);

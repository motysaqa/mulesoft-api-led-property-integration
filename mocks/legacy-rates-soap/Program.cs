using System.Globalization;
using System.Text;
using System.Xml.Linq;

// Mock legacy rates service (SOAP 1.1, document/literal).
//
// Hand-rolled rather than built with WCF on purpose: the point is to reproduce the
// awkward parts of a real legacy endpoint - amounts in minor units, a SOAP fault
// for business errors, and a WSDL served from ?wsdl - with no framework magic in
// the way while troubleshooting the Web Service Consumer connector.

var builder = WebApplication.CreateBuilder(args);

// Fixed port so the Mule config and the run scripts agree; ASPNETCORE_URLS still wins.
if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("ASPNETCORE_URLS")))
    builder.WebHost.UseUrls("http://localhost:5082");

var app = builder.Build();

XNamespace soap = "http://schemas.xmlsoap.org/soap/envelope/";
XNamespace tns = "http://legacy.rates.portfolio.com/";

app.MapGet("/health", () => Results.Ok(new { status = "UP", service = "legacy-rates-soap-mock" }));

// The WSDL is served on GET so the connector can be pointed at the live endpoint.
app.MapGet("/LegacyRatesService", () =>
{
    var path = Path.Combine(AppContext.BaseDirectory, "wsdl", "LegacyRatesService.wsdl");
    return File.Exists(path)
        ? Results.Text(File.ReadAllText(path), "text/xml", Encoding.UTF8)
        : Results.NotFound("WSDL not found next to the binary");
});

app.MapPost("/LegacyRatesService", async (HttpRequest request) =>
{
    var raw = await new StreamReader(request.Body, Encoding.UTF8).ReadToEndAsync();

    XDocument envelope;
    try
    {
        envelope = XDocument.Parse(raw);
    }
    catch (System.Xml.XmlException ex)
    {
        return SoapFault(soap, "soap:Client", $"Malformed envelope: {ex.Message}");
    }

    var body = envelope.Root?.Element(soap + "Body");
    var call = body?.Element(tns + "GetRates");
    if (call is null)
        return SoapFault(soap, "soap:Client", "Expected a GetRates element in the SOAP body");

    var propertyId = (string?)call.Element(tns + "PropertyId") ?? "";
    var ratePlanCode = (string?)call.Element(tns + "RatePlanCode") ?? "STD";
    var fromRaw = (string?)call.Element(tns + "FromDate") ?? "";
    var toRaw = (string?)call.Element(tns + "ToDate") ?? "";

    if (string.IsNullOrWhiteSpace(propertyId))
        return SoapFault(soap, "soap:Client", "PropertyId is required");

    if (!DateOnly.TryParse(fromRaw, CultureInfo.InvariantCulture, DateTimeStyles.None, out var from) ||
        !DateOnly.TryParse(toRaw, CultureInfo.InvariantCulture, DateTimeStyles.None, out var to) ||
        to < from)
    {
        return SoapFault(soap, "soap:Client", "FromDate and ToDate must be dates with FromDate <= ToDate");
    }

    // A business error arrives as a SOAP fault, not an HTTP error - which is exactly
    // why the Mule app maps WSC:SOAP_FAULT separately from WSC:CONNECTIVITY.
    if (propertyId.StartsWith("UNKNOWN", StringComparison.OrdinalIgnoreCase))
        return SoapFault(soap, "soap:Server", $"No rate plan for property {propertyId}");

    // The premium plan is quoted in USD by the legacy system. That is what makes the
    // process layer's currency conversion a real code path rather than a no-op.
    var currency = ratePlanCode.Equals("PREMIUM", StringComparison.OrdinalIgnoreCase) ? "USD" : "EUR";

    var days = new List<XElement>();
    for (var day = from; day <= to; day = day.AddDays(1))
    {
        var amountMinor = AmountMinorFor(propertyId, ratePlanCode, day);
        var isWeekendNight = day.DayOfWeek is DayOfWeek.Friday or DayOfWeek.Saturday;

        var rate = new XElement(tns + "DailyRate",
            new XElement(tns + "Date", day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)),
            new XElement(tns + "AmountMinor", amountMinor),
            new XElement(tns + "TaxIncluded", false));

        // Empty-but-present elements are a classic legacy quirk; the DataWeave
        // transformation turns "" into null rather than a bogus promotion code.
        rate.Add(new XElement(tns + "PromotionCode", isWeekendNight ? "" : "EARLYBIRD"));
        days.Add(rate);
    }

    var response = new XDocument(
        new XElement(soap + "Envelope",
            new XAttribute(XNamespace.Xmlns + "soap", soap.NamespaceName),
            new XElement(soap + "Body",
                new XElement(tns + "GetRatesResponse",
                    new XAttribute(XNamespace.Xmlns + "tns", tns.NamespaceName),
                    new XElement(tns + "PropertyId", propertyId),
                    new XElement(tns + "RatePlanCode", ratePlanCode),
                    new XElement(tns + "Currency", currency),
                    new XElement(tns + "DailyRates", days)))));

    return Results.Text(response.ToString(), "text/xml", Encoding.UTF8);
});

app.Run();

// Deterministic pricing so demos and contract tests are reproducible:
// a base rate per property, a premium uplift, and a weekend uplift.
static long AmountMinorFor(string propertyId, string ratePlanCode, DateOnly day)
{
    var baseMinor = 9000 + (long)(StableHash(propertyId) % 60) * 100;
    if (ratePlanCode.Equals("PREMIUM", StringComparison.OrdinalIgnoreCase))
        baseMinor = (long)(baseMinor * 1.45);
    if (day.DayOfWeek is DayOfWeek.Friday or DayOfWeek.Saturday)
        baseMinor = (long)(baseMinor * 1.25);

    // Round to whole currency units, which is how most legacy rate engines store them.
    return baseMinor / 100 * 100;
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

static IResult SoapFault(XNamespace soap, string code, string message)
{
    var fault = new XDocument(
        new XElement(soap + "Envelope",
            new XAttribute(XNamespace.Xmlns + "soap", soap.NamespaceName),
            new XElement(soap + "Body",
                new XElement(soap + "Fault",
                    new XElement("faultcode", code),
                    new XElement("faultstring", message)))));

    // SOAP 1.1 faults travel with HTTP 500. The connector reports this as
    // WSC:SOAP_FAULT rather than a connectivity problem.
    return Results.Text(fault.ToString(), "text/xml", Encoding.UTF8, statusCode: 500);
}

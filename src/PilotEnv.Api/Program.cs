using System.Security.Claims;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Http.HttpResults;
using Microsoft.AspNetCore.Http.Extensions;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.Options;
using PilotEnv.Api;

if (args.Length == 2 && args[0] == "--platform-check-quiescent")
{
    var database = Path.Combine(Path.GetFullPath(args[1]), ".pilot-runtime", "api", "pilot-env.db");
    if (!File.Exists(database)) return;
    using var connection = new Microsoft.Data.Sqlite.SqliteConnection(new Microsoft.Data.Sqlite.SqliteConnectionStringBuilder { DataSource=database, Mode=Microsoft.Data.Sqlite.SqliteOpenMode.ReadOnly }.ToString());
    connection.Open();
    using var command = connection.CreateCommand();
    command.CommandText = "SELECT COUNT(*) FROM operations WHERE state IN ('queued','running')";
    var count = Convert.ToInt64(command.ExecuteScalar());
    Console.WriteLine(JsonSerializer.Serialize(new { activeOperations=count }));
    Environment.ExitCode = count == 0 ? 0 : 2;
    return;
}

var builder = WebApplication.CreateBuilder(args);
var detectedRepositoryRoot = Environment.GetEnvironmentVariable("PILOT_DATA_ROOT") ?? FindRepositoryRoot(builder.Environment.ContentRootPath);
if (detectedRepositoryRoot is not null)
{
    builder.Configuration.AddJsonFile(Path.Combine(detectedRepositoryRoot, ".pilot-runtime", "api", "hostsettings.json"), optional: true, reloadOnChange: false);
    builder.Configuration["PilotEnv:RepositoryRoot"] = detectedRepositoryRoot;
}
builder.Host.UseWindowsService(options => options.ServiceName = "Pilot Environment API");
builder.Services.AddOptions<PilotEnvOptions>()
    .Bind(builder.Configuration.GetSection(PilotEnvOptions.SectionName))
    .Validate(o => !string.IsNullOrWhiteSpace(o.PublicHost), "PublicHost is required.")
    .Validate(o => o.ControlPublicPort is > 0 and <= 65535, "ControlPublicPort is invalid.")
    .Validate(o => o.WebPublicPortEnd >= o.WebPublicPortStart && o.AdminPublicPortEnd >= o.AdminPublicPortStart,
        "Public port ranges are invalid.")
    .Validate(o => o.WebPublicPortEnd - o.WebPublicPortStart == o.AdminPublicPortEnd - o.AdminPublicPortStart,
        "Web and myAdmin public port ranges must have equal length.")
    .ValidateOnStart();
var initialOptions = builder.Configuration.GetSection(PilotEnvOptions.SectionName).Get<PilotEnvOptions>() ?? new PilotEnvOptions();
builder.WebHost.UseUrls(initialOptions.ListenUrl);

var repositoryRoot = initialOptions.ResolveRepositoryRoot(builder.Environment.ContentRootPath);
var keyPath = Path.Combine(repositoryRoot, ".pilot-runtime", "api", "keys");
Directory.CreateDirectory(keyPath);
var dataProtection = builder.Services.AddDataProtection().PersistKeysToFileSystem(new DirectoryInfo(keyPath));
if (OperatingSystem.IsWindows()) dataProtection.ProtectKeysWithDpapi(protectToLocalMachine: true);
builder.Services.AddSingleton<ProtectedSecretStore>();
builder.Services.AddSingleton<BrowserSessionService>();
builder.Services.AddAuthentication("PilotSharedToken")
    .AddScheme<AuthenticationSchemeOptions, SharedTokenAuthenticationHandler>("PilotSharedToken", _ => { });
builder.Services.AddAuthorization();
builder.Services.AddHttpForwarder();
builder.Services.AddSingleton<OperationStore>();
builder.Services.AddSingleton<PowerShellEngine>();
builder.Services.AddSingleton<IEnvironmentEngine>(sp => sp.GetRequiredService<PowerShellEngine>());
builder.Services.AddSingleton<PlatformDeployment>();
builder.Services.AddSingleton<PlatformActivity>();
builder.Services.AddSingleton<UiEndpoint>();
builder.Services.AddSingleton<CapacityService>();
builder.Services.AddSingleton<EnvironmentService>();
builder.Services.AddSingleton<OperationCoordinator>();
builder.Services.AddHostedService(sp => sp.GetRequiredService<OperationCoordinator>());
builder.Services.AddSingleton<ProxyEndpoint>();
builder.Services.AddProblemDetails();

var app = builder.Build();
await app.Services.GetRequiredService<OperationStore>().InitializeAsync();

app.UseExceptionHandler(errorApp => errorApp.Run(async context =>
{
    var exception = context.Features.Get<IExceptionHandlerFeature>()?.Error;
    var problem = exception as ApiProblemException;
    var status = problem?.StatusCode ?? StatusCodes.Status500InternalServerError;
    context.Response.StatusCode = status;
    await Results.Problem(
        statusCode: status,
        title: problem?.Code ?? "internal_error",
        detail: status == 500 ? "The server could not complete the request." : problem?.Message,
        extensions: problem is null ? null : new Dictionary<string, object?> { ["code"] = problem.Code })
        .ExecuteAsync(context);
}));

var forwardedOptions = new ForwardedHeadersOptions
{
    ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedHost | ForwardedHeaders.XForwardedProto,
    ForwardLimit = 1
};
// The API listener is private and firewall-restricted to the local reverse proxy.
// nginx overwrites these headers, so the client cannot select another route port.
forwardedOptions.KnownNetworks.Clear();
forwardedOptions.KnownProxies.Clear();
app.UseForwardedHeaders(forwardedOptions);
var runtimeOptions = app.Services.GetRequiredService<IOptions<PilotEnvOptions>>().Value;
app.UseAuthentication();
app.UseAuthorization();
app.Use(async (context, next) =>
{
    var maintenance = context.RequestServices.GetRequiredService<PlatformDeployment>().Maintenance;
    if (IsControlRequest(context, runtimeOptions) && maintenance?.Component is "control-api" or "all" &&
        maintenance.Phase == "activating" && context.Request.Path.StartsWithSegments("/api") &&
        context.Request.Method is not ("GET" or "HEAD"))
    {
        context.Response.Headers.RetryAfter = "10";
        await Results.Problem(statusCode:503, title:"platform_updating", extensions:new Dictionary<string,object?>{{"code","platform_updating"}}).ExecuteAsync(context);
        return;
    }
    await next();
});
app.Use(async (context, next) =>
{
    var unsafeMethod = HttpMethods.IsPost(context.Request.Method) || HttpMethods.IsPut(context.Request.Method) ||
                       HttpMethods.IsPatch(context.Request.Method) || HttpMethods.IsDelete(context.Request.Method);
    if (IsControlRequest(context, runtimeOptions) && context.User.Identity?.IsAuthenticated == true && unsafeMethod)
    {
        if (context.User.FindFirstValue("auth_source") == "cookie")
        {
            var expected = context.User.FindFirstValue("csrf");
            var actual = context.Request.Headers["X-Pilot-Csrf"].ToString();
            if (string.IsNullOrEmpty(expected) || !string.Equals(expected, actual, StringComparison.Ordinal))
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                await context.Response.WriteAsJsonAsync(new { error = "invalid_csrf" });
                return;
            }
        }
    }
    await next();
});

// Environment ports are a complete reverse-proxy surface. Branch before endpoint
// dispatch so Pilot paths such as /api/v1 are never captured by the control API.
app.Use(async (context, next) =>
{
    var options = context.RequestServices.GetRequiredService<IOptions<PilotEnvOptions>>().Value;
    if (IsControlRequest(context, options))
    {
        await next();
        return;
    }

    if (!string.Equals(context.Request.Host.Host, options.PublicHost, StringComparison.OrdinalIgnoreCase))
    {
        context.Response.StatusCode = StatusCodes.Status404NotFound;
        await context.Response.WriteAsJsonAsync(new { error = "unknown_public_host" });
        return;
    }

    if (context.User.Identity?.IsAuthenticated != true)
    {
        context.Response.Redirect(ControlUrl(options) + "/?returnUrl=" + Uri.EscapeDataString(context.Request.GetEncodedUrl()));
        return;
    }

    await context.RequestServices.GetRequiredService<ProxyEndpoint>().InvokeAsync(context);
});

app.MapPost("/api/v1/session", (SessionRequest request, ProtectedSecretStore secrets, BrowserSessionService sessions,
    EnvironmentService environments, IOptions<PilotEnvOptions> options, HttpContext context) =>
{
    if (!TokenHasher.Verify(request.Token, secrets.Value.TokenHash)) return Results.Unauthorized();
    var created = sessions.Create();
    context.Response.Cookies.Append(BrowserSessionService.CookieName, created.Cookie,
        sessions.CookieOptions(created.Session.ExpiresAt, context.Request.Host.Host, context.Request.IsHttps));
    var allowedPorts = new[] { options.Value.ControlPublicPort }
        .Concat(environments.GetConfiguredPublicPorts().SelectMany(x => new[] { x.Web, x.Admin })).Distinct().Order().ToArray();
    return Results.Ok(new { csrfToken = created.Session.CsrfToken, expiresAt = created.Session.ExpiresAt,
        publicHost = options.Value.PublicHost, allowedPorts });
}).AllowAnonymous();

app.MapDelete("/api/v1/session", (BrowserSessionService sessions, HttpContext context) =>
{
    context.Response.Cookies.Delete(BrowserSessionService.CookieName,
        sessions.CookieOptions(DateTimeOffset.UnixEpoch, context.Request.Host.Host, context.Request.IsHttps));
    return Results.NoContent();
}).RequireAuthorization();

var api = app.MapGroup("/api/v1").RequireAuthorization();
api.MapGet("/platform", (PlatformDeployment deployment) => Results.Ok(deployment.Status));
// Private loopback coordination endpoint: no secrets and no public update authority.
app.MapGet("/internal/platform/activity", (HttpContext context, PlatformActivity activity, PlatformDeployment deployment) =>
    context.Connection.RemoteIpAddress is { } address &&
        (System.Net.IPAddress.IsLoopback(address) || address.Equals(context.Connection.LocalIpAddress)) &&
        !context.Request.Headers.ContainsKey("X-Forwarded-For") && !context.Request.Headers.ContainsKey("X-Original-For")
        ? Results.Ok(new { activeOperations=activity.Active, maintenance=deployment.Maintenance }) : Results.StatusCode(403));
api.MapGet("/session", (ClaimsPrincipal user, EnvironmentService environments, IOptions<PilotEnvOptions> options) => Results.Ok(new {
    csrfToken = user.FindFirstValue("csrf"), publicHost = options.Value.PublicHost,
    allowedPorts = new[] { options.Value.ControlPublicPort }.Concat(environments.GetConfiguredPublicPorts().SelectMany(x => new[] { x.Web, x.Admin })).Distinct().Order()
}));
api.MapGet("/capacity", async (CapacityService capacity, CancellationToken ct) => Results.Ok(await capacity.GetAsync(ct)));
api.MapGet("/environments", async (EnvironmentService environments, CancellationToken ct) => Results.Ok(await environments.ListAsync(ct)));
api.MapGet("/environments/{name}", async Task<Results<Ok<EnvironmentStatus>, NotFound>> (string name, EnvironmentService environments, CancellationToken ct) =>
{
    var status = await environments.GetAsync(name, ct);
    return status is null ? TypedResults.NotFound() : TypedResults.Ok(status);
});
api.MapPost("/environments", async (CreateEnvironmentRequest request, HttpContext context, OperationCoordinator operations, CancellationToken ct) =>
    Accepted(await operations.QueueCreateAsync(request, IdempotencyKey(context), ct)));
api.MapPost("/environments/{name}/start", async (string name, HttpContext context, OperationCoordinator operations, CancellationToken ct) =>
    Accepted(await operations.QueueStartAsync(name, IdempotencyKey(context), ct)));
api.MapPost("/environments/{name}/stop", async (string name, HttpContext context, OperationCoordinator operations, CancellationToken ct) =>
    Accepted(await operations.QueueStopAsync(name, IdempotencyKey(context), ct)));
api.MapPost("/environments/{name}/components/{component}/restart", async (string name, string component, RestartComponentRequest? request,
    HttpContext context, OperationCoordinator operations, CancellationToken ct) =>
    Accepted(await operations.QueueRestartAsync(name, component, request?.Cascade ?? false, IdempotencyKey(context), ct)));
api.MapPost("/environments/{name}/recreate", async (string name, ConfirmRequest request, HttpContext context, OperationCoordinator operations, CancellationToken ct) =>
{
    Confirm(name, request.ConfirmName);
    return Accepted(await operations.QueueRecreateAsync(name, IdempotencyKey(context), ct));
});
api.MapDelete("/environments/{name}", async (string name, string? confirmName, HttpContext context, OperationCoordinator operations, CancellationToken ct) =>
{
    Confirm(name, confirmName);
    return Accepted(await operations.QueueDeleteAsync(name, IdempotencyKey(context), ct));
});
api.MapGet("/operations", async (string? environmentName, string? kind, string? state, int? limit, string? cursor, OperationStore store, CancellationToken ct) =>
    Results.Ok(await store.ListAsync(environmentName, kind, state, limit ?? 25, cursor, ct)));
api.MapGet("/operations/{id:guid}", async Task<Results<Ok<OperationRecord>, NotFound>> (Guid id, OperationStore store, CancellationToken ct) =>
{
    var operation = await store.GetAsync(id, ct);
    return operation is null ? TypedResults.NotFound() : TypedResults.Ok(operation);
});
api.MapGet("/environments/{name}/components/{component}/logs", async (string name, string component, int? tail, IEnvironmentEngine engine, CancellationToken ct) =>
{
    OperationCoordinator.ValidateName(name);
    if (!Components.Allowed.Contains(component)) throw new ApiProblemException("component_unavailable", "Unknown Pilot component.", 404);
    var value = Math.Clamp(tail ?? 200, 1, 2000);
    return Results.Text(await engine.GetLogsAsync(name, component, value, ct), "text/plain; charset=utf-8");
});
api.MapPost("/releases/refresh", async (HttpContext context, OperationCoordinator operations, CancellationToken ct) =>
    Accepted(await operations.QueueRefreshReleaseAsync(IdempotencyKey(context), ct)));

app.MapGet("/health/live", () => Results.Ok(new { status = "live" })).AllowAnonymous();
app.MapGet("/health/ready", async (CapacityService capacity, CancellationToken ct) =>
{
    var result = await capacity.GetAsync(ct);
    return result.Prerequisites.DockerReady ? Results.Ok(new { status = "ready" }) : Results.Json(new { status = "not_ready", result.Blockers }, statusCode: 503);
}).AllowAnonymous();

app.MapGet("/openapi/v1.json", () => Results.File(Path.Combine(AppContext.BaseDirectory, "Contracts", "openapi-v1.json"), "application/json")).AllowAnonymous();
app.MapGet("/ui-assets/{buildHash}/{file}", (HttpContext context, UiEndpoint ui) => ui.InvokeAsync(context)).AllowAnonymous();
app.MapFallback(async (HttpContext context, UiEndpoint ui) =>
{
    if (context.Request.Path.StartsWithSegments("/api") || context.Request.Path.StartsWithSegments("/internal") || context.Request.Path.StartsWithSegments("/health"))
        await Results.Problem(statusCode:404, title:"endpoint_not_found").ExecuteAsync(context);
    else await ui.InvokeAsync(context);
}).AllowAnonymous();

await app.RunAsync();

static IResult Accepted(OperationRecord operation) => Results.Accepted($"/api/v1/operations/{operation.Id}", new QueuedOperationResponse(operation.Id, operation.State));
static string? IdempotencyKey(HttpContext context) => context.Request.Headers["Idempotency-Key"].FirstOrDefault();
static bool IsControlRequest(HttpContext context, PilotEnvOptions options) =>
    (context.Request.Host.Host is "127.0.0.1" or "localhost" &&
     (context.Request.Host.Port is null || context.Request.Host.Port == options.ControlPublicPort ||
      context.Request.Host.Port == new Uri(options.ListenUrl).Port)) ||
    (string.Equals(context.Request.Host.Host, options.PublicHost, StringComparison.OrdinalIgnoreCase) &&
     context.Request.Host.Port == options.ControlPublicPort);
static string ControlUrl(PilotEnvOptions options) => $"{options.PublicScheme}://{options.PublicHost}:{options.ControlPublicPort}";
static void Confirm(string name, string? confirmation)
{
    if (!string.Equals(name, confirmation, StringComparison.Ordinal))
        throw new ApiProblemException("confirmation_required", "The exact environment name is required for this destructive operation.", 400);
}

static string? FindRepositoryRoot(string start)
{
    var directory = new DirectoryInfo(start);
    while (directory is not null)
    {
        if (File.Exists(Path.Combine(directory.FullName, ".pilot-runtime", "deployment-state.json")) ||
            (File.Exists(Path.Combine(directory.FullName, "docker-compose.yml")) && Directory.Exists(Path.Combine(directory.FullName, "scripts"))))
            return directory.FullName;
        directory = directory.Parent;
    }
    return null;
}

public partial class Program { }

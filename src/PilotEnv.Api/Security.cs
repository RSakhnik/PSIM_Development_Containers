using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Runtime.Versioning;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.Extensions.Options;

namespace PilotEnv.Api;

public sealed class HostSecrets
{
    public string TokenHash { get; init; } = "";
    public string AdminLogin { get; init; } = "pilotadmin";
    public string AdminPassword { get; init; } = "";
    public string BimLogin { get; init; } = "bimservice";
    public string BimPassword { get; init; } = "";
}

public sealed class ProtectedSecretStore
{
    private readonly HostSecrets _secrets;

    public ProtectedSecretStore(IOptions<PilotEnvOptions> options, IWebHostEnvironment environment)
    {
        var path = options.Value.ResolvePath(environment.ContentRootPath, options.Value.SecretFile);
        if (!File.Exists(path))
            throw new InvalidOperationException($"Secret file is missing: {path}. Run scripts/configure-api.ps1 first.");

        var document = JsonSerializer.Deserialize<SecretDocument>(File.ReadAllText(path), JsonDefaults.Options)
            ?? throw new InvalidOperationException("Secret file is empty or invalid.");
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("The v1 secret store requires Windows DPAPI LocalMachine.");

        _secrets = new HostSecrets
        {
            TokenHash = document.TokenHash,
            AdminLogin = document.AdminLogin,
            AdminPassword = Unprotect(document.AdminPasswordProtected),
            BimLogin = document.BimLogin,
            BimPassword = Unprotect(document.BimPasswordProtected)
        };
    }

    public HostSecrets Value => _secrets;

    [SupportedOSPlatform("windows")]
    private static string Unprotect(string encoded)
    {
        var bytes = Convert.FromBase64String(encoded);
        var clear = ProtectedData.Unprotect(bytes, null, DataProtectionScope.LocalMachine);
        try { return Encoding.UTF8.GetString(clear); }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }

    private sealed class SecretDocument
    {
        public int SchemaVersion { get; init; }
        public string TokenHash { get; init; } = "";
        public string AdminLogin { get; init; } = "pilotadmin";
        public string AdminPasswordProtected { get; init; } = "";
        public string BimLogin { get; init; } = "bimservice";
        public string BimPasswordProtected { get; init; } = "";
    }
}

public static class TokenHasher
{
    private const int Iterations = 210_000;

    public static string Hash(string token)
    {
        var salt = RandomNumberGenerator.GetBytes(32);
        var hash = Rfc2898DeriveBytes.Pbkdf2(token, salt, Iterations, HashAlgorithmName.SHA256, 32);
        return $"v1.{Iterations}.{Convert.ToBase64String(salt)}.{Convert.ToBase64String(hash)}";
    }

    public static bool Verify(string token, string encoded)
    {
        var parts = encoded.Split('.');
        if (parts.Length != 4 || parts[0] != "v1" || !int.TryParse(parts[1], out var iterations)) return false;
        try
        {
            var salt = Convert.FromBase64String(parts[2]);
            var expected = Convert.FromBase64String(parts[3]);
            var actual = Rfc2898DeriveBytes.Pbkdf2(token, salt, iterations, HashAlgorithmName.SHA256, expected.Length);
            return CryptographicOperations.FixedTimeEquals(actual, expected);
        }
        catch (FormatException) { return false; }
    }
}

public sealed record BrowserSession(DateTimeOffset ExpiresAt, string CsrfToken);

public sealed class BrowserSessionService(IDataProtectionProvider provider, IOptions<PilotEnvOptions> options)
{
    public const string CookieName = "pilot_env_session";
    private readonly IDataProtector _protector = provider.CreateProtector("PilotEnv.Api.BrowserSession.v1");
    private readonly PilotEnvOptions _options = options.Value;

    public (string Cookie, BrowserSession Session) Create()
    {
        var session = new BrowserSession(DateTimeOffset.UtcNow.AddHours(12), Convert.ToHexString(RandomNumberGenerator.GetBytes(24)));
        return (_protector.Protect(JsonSerializer.Serialize(session, JsonDefaults.Options)), session);
    }

    public BrowserSession? Read(string cookie)
    {
        try
        {
            var session = JsonSerializer.Deserialize<BrowserSession>(_protector.Unprotect(cookie), JsonDefaults.Options);
            return session is not null && session.ExpiresAt > DateTimeOffset.UtcNow ? session : null;
        }
        catch (CryptographicException) { return null; }
    }

    public CookieOptions CookieOptions(DateTimeOffset expires, string requestHost, bool secure)
    {
        return new CookieOptions
        {
            HttpOnly = true,
            Secure = secure,
            SameSite = SameSiteMode.Lax,
            Domain = null,
            Expires = expires,
            Path = "/"
        };
    }
}

public sealed class SharedTokenAuthenticationHandler : AuthenticationHandler<AuthenticationSchemeOptions>
{
    private readonly ProtectedSecretStore _secretStore;
    private readonly BrowserSessionService _sessions;
    private readonly PilotEnvOptions _pilotOptions;

    public SharedTokenAuthenticationHandler(
        IOptionsMonitor<AuthenticationSchemeOptions> options,
        ILoggerFactory logger,
        UrlEncoder encoder,
        ProtectedSecretStore secretStore,
        BrowserSessionService sessions,
        IOptions<PilotEnvOptions> pilotOptions) : base(options, logger, encoder)
    {
        _secretStore = secretStore;
        _sessions = sessions;
        _pilotOptions = pilotOptions.Value;
    }

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        var controlRequest = (Request.Host.Host is "127.0.0.1" or "localhost" &&
            (Request.Host.Port is null || Request.Host.Port == _pilotOptions.ControlPublicPort ||
             Request.Host.Port == new Uri(_pilotOptions.ListenUrl).Port)) ||
            (string.Equals(Request.Host.Host, _pilotOptions.PublicHost, StringComparison.OrdinalIgnoreCase) &&
             Request.Host.Port == _pilotOptions.ControlPublicPort);
        var authorization = Request.Headers.Authorization.ToString();
        if (controlRequest && authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            var token = authorization[7..].Trim();
            if (TokenHasher.Verify(token, _secretStore.Value.TokenHash))
                return Task.FromResult(Success("bearer", null));
            return Task.FromResult(AuthenticateResult.Fail("Invalid API token."));
        }

        if (Request.Cookies.TryGetValue(BrowserSessionService.CookieName, out var cookie))
        {
            var session = _sessions.Read(cookie);
            if (session is not null) return Task.FromResult(Success("cookie", session.CsrfToken));
        }

        return Task.FromResult(AuthenticateResult.NoResult());
    }

    private AuthenticateResult Success(string source, string? csrf)
    {
        var claims = new List<Claim> { new(ClaimTypes.Name, "shared-token"), new("auth_source", source) };
        if (csrf is not null) claims.Add(new Claim("csrf", csrf));
        var principal = new ClaimsPrincipal(new ClaimsIdentity(claims, Scheme.Name));
        return AuthenticateResult.Success(new AuthenticationTicket(principal, Scheme.Name));
    }
}

public static class JsonDefaults
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = false
    };
}

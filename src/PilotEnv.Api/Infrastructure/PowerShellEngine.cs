using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Options;

namespace PilotEnv.Api;

public sealed class PowerShellEngine : IEnvironmentEngine
{
    private readonly string _repositoryRoot;
    private readonly PlatformDeployment _deployment;
    private readonly AsyncLocal<string?> _pinnedPath = new();
    private readonly string _licensePath;
    private readonly string _configurationPath;
    private readonly HostSecrets _secrets;
    private readonly double _minimumFreeDiskGiB;
    private readonly string _powerShellExecutable;
    private readonly bool _disableMemoryAdmission;
    private readonly ILogger<PowerShellEngine> _logger;

    public PowerShellEngine(IOptions<PilotEnvOptions> options, IWebHostEnvironment environment, ProtectedSecretStore secretStore, ILogger<PowerShellEngine> logger, PlatformDeployment deployment)
    {
        _repositoryRoot = options.Value.ResolveRepositoryRoot(environment.ContentRootPath);
        _deployment = deployment;
        _licensePath = options.Value.ResolvePath(environment.ContentRootPath, options.Value.LicenseFile);
        _configurationPath = options.Value.ResolvePath(environment.ContentRootPath, options.Value.ConfigurationFile);
        _secrets = secretStore.Value;
        _minimumFreeDiskGiB = options.Value.MinimumFreeDiskGiB;
        _powerShellExecutable = options.Value.PowerShellExecutable;
        _disableMemoryAdmission = options.Value.DisableMemoryAdmission;
        _logger = logger;
    }

    public IDisposable PinBuild()
    {
        var previous = _pinnedPath.Value;
        _pinnedPath.Value = _deployment.ComponentPath("environment-engine");
        return new Scope(() => _pinnedPath.Value = previous);
    }
    private sealed class Scope(Action release) : IDisposable { public void Dispose() => release(); }

    public async Task<JsonDocument> GetEngineInfoAsync(CancellationToken ct)
    {
        var result = await RunAsync(["GetEngineInfo", "-Json"], TimeSpan.FromMinutes(1), ct);
        EnsureSuccess(result);
        return ParseLastJson(result.StandardOutput);
    }

    public Task<EngineResult> CreateAsync(string name, PublicPortPair ports, CancellationToken ct) =>
        RunAsync(["New", name, "-Mode", "bim-dev", "-PublicWebPort", ports.Web.ToString(),
            "-PublicAdminPort", ports.Admin.ToString(), "-Start"], TimeSpan.FromMinutes(30), ct);

    public Task<EngineResult> StartAsync(string name, CancellationToken ct) =>
        RunAsync(["Start", name], TimeSpan.FromMinutes(20), ct);

    public Task<EngineResult> StopAsync(string name, CancellationToken ct) =>
        RunAsync(["Stop", name], TimeSpan.FromMinutes(5), ct);

    public Task<EngineResult> DeleteAsync(string name, CancellationToken ct) =>
        RunAsync(["Remove", name, "-Force"], TimeSpan.FromMinutes(10), ct);

    public Task<EngineResult> RestartComponentAsync(string name, string component, bool cascade, CancellationToken ct)
    {
        var args = new List<string> { "RestartComponent", name, "-Service", component };
        if (cascade) args.Add("-Cascade");
        return RunAsync(args, TimeSpan.FromMinutes(10), ct);
    }

    public Task<EngineResult> RecreateAsync(string name, CancellationToken ct) =>
        RunAsync(["Recreate", name, "-Force"], TimeSpan.FromMinutes(30), ct);

    public Task<EngineResult> RefreshReleaseAsync(CancellationToken ct) =>
        RunAsync(["RefreshRelease"], TimeSpan.FromMinutes(45), ct);

    public async Task<JsonDocument> GetStatusAsync(string name, CancellationToken ct)
    {
        var result = await RunAsync(["GetStatus", name, "-Json"], TimeSpan.FromMinutes(2), ct);
        EnsureSuccess(result);
        return ParseLastJson(result.StandardOutput);
    }

    public async Task<JsonDocument> GetCapacityAsync(CancellationToken ct)
    {
        var result = await RunAsync(["GetCapacity", "-Json"], TimeSpan.FromMinutes(2), ct);
        EnsureSuccess(result);
        return ParseLastJson(result.StandardOutput);
    }

    public async Task<string> GetLogsAsync(string name, string component, int tail, CancellationToken ct)
    {
        var result = await RunAsync(["Logs", name, "-Service", component, "-Tail", tail.ToString()], TimeSpan.FromMinutes(2), ct);
        EnsureSuccess(result);
        return result.StandardOutput;
    }

    public async Task<EngineResult> RunAsync(IReadOnlyList<string> arguments, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var engineRoot = _pinnedPath.Value ?? _deployment.ComponentPath("environment-engine");
        var scriptPath = Path.Combine(engineRoot, "scripts", "pilot-env.ps1");
        if (!File.Exists(scriptPath)) throw new InvalidOperationException($"Pilot environment engine was not found: {scriptPath}");
        var startInfo = new ProcessStartInfo
        {
            FileName = _powerShellExecutable,
            WorkingDirectory = _repositoryRoot,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(scriptPath);
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
        startInfo.ArgumentList.Add("-Machine");
        startInfo.Environment["PILOT_DATA_ROOT"] = _repositoryRoot;
        startInfo.Environment["PILOT_ENGINE_ROOT"] = engineRoot;

        startInfo.Environment["PILOT_LICENSE_FILE"] = _licensePath;
        startInfo.Environment["PILOT_CONFIGURATION_FILE"] = _configurationPath;
        startInfo.Environment["PILOT_ADMIN_LOGIN"] = _secrets.AdminLogin;
        startInfo.Environment["PILOT_ADMIN_PASSWORD"] = _secrets.AdminPassword;
        startInfo.Environment["PILOT_BIM_LOGIN"] = _secrets.BimLogin;
        startInfo.Environment["PILOT_BIM_PASSWORD"] = _secrets.BimPassword;
        startInfo.Environment["PILOT_MIN_FREE_DISK_GIB"] = _minimumFreeDiskGiB.ToString(System.Globalization.CultureInfo.InvariantCulture);
        startInfo.Environment["PILOT_DISABLE_MEMORY_ADMISSION"] = _disableMemoryAdmission ? "1" : "0";

        using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) stdout.AppendLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) stderr.AppendLine(e.Data); };
        if (!process.Start()) throw new InvalidOperationException("Could not start PowerShell engine.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        using var timeoutSource = new CancellationTokenSource(timeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutSource.Token);
        try
        {
            await process.WaitForExitAsync(linked.Token);
            process.WaitForExit();
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch { }
            if (timeoutSource.IsCancellationRequested)
                throw new TimeoutException($"Pilot operation exceeded {timeout}.");
            throw;
        }

        JsonDocument parsedEnvelope;
        try { parsedEnvelope = JsonDocument.Parse(stdout.ToString().Trim()); }
        catch (JsonException ex)
        {
            var diagnostic = EngineResult.SanitizeDiagnostic(Redact(stderr.ToString()));
            if (diagnostic.Length > 4000) diagnostic = diagnostic[^4000..];
            throw new InvalidDataException($"Engine returned invalid protocol JSON (action {arguments.FirstOrDefault()}, exit {process.ExitCode}). Diagnostics: {diagnostic}", ex);
        }
        using var envelope = parsedEnvelope;
        var root = envelope.RootElement;
        if (root.GetProperty("protocolVersion").GetInt32() != 1) throw new InvalidDataException("Unsupported engine protocol.");
        var success = root.GetProperty("success").GetBoolean();
        var data = root.GetProperty("data");
        var result = new EngineResult(success && process.ExitCode == 0 ? 0 : 1,
            data.ValueKind == JsonValueKind.String ? Redact(data.GetString() ?? "") : RedactStructuredData(data),
            Redact(success ? stderr.ToString().Trim() : root.GetProperty("error").GetProperty("message").GetString() ?? "Engine failed."));
        _logger.LogInformation("Pilot engine action {Action} finished with exit code {ExitCode}", arguments.FirstOrDefault(), result.ExitCode);
        return result;
    }

    public static void EnsureSuccess(EngineResult result)
    {
        result.EnsureSuccess();
    }

    private string RedactStructuredData(JsonElement data)
    {
        var node = JsonNode.Parse(data.GetRawText());
        void Visit(JsonNode? current)
        {
            if (current is JsonObject obj)
            {
                foreach (var property in obj.ToArray())
                {
                    if (property.Key.Equals("password", StringComparison.OrdinalIgnoreCase) ||
                        property.Key.Equals("adminPassword", StringComparison.OrdinalIgnoreCase) ||
                        property.Key.Equals("bimPassword", StringComparison.OrdinalIgnoreCase) ||
                        property.Key.Equals("token", StringComparison.OrdinalIgnoreCase) ||
                        property.Key.Equals("apiToken", StringComparison.OrdinalIgnoreCase))
                        obj[property.Key] = "***";
                    else if ((property.Key.Equals("lastError", StringComparison.OrdinalIgnoreCase) ||
                              property.Key.Equals("message", StringComparison.OrdinalIgnoreCase)) &&
                              property.Value is JsonValue value && value.TryGetValue<string>(out var text))
                        obj[property.Key] = Redact(text);
                    else Visit(property.Value);
                }
            }
            else if (current is JsonArray array) foreach (var item in array) Visit(item);
        }
        Visit(node);
        return node?.ToJsonString() ?? "null";
    }

    private string Redact(string value)
    {
        foreach (var secret in new[] { _secrets.AdminPassword, _secrets.BimPassword })
            if (!string.IsNullOrEmpty(secret)) value = value.Replace(secret, "***", StringComparison.Ordinal);
        return value;
    }

    public static string SanitizeDiagnostic(string value)
    {
        return EngineResult.SanitizeDiagnostic(value);
    }

    private static JsonDocument ParseLastJson(string output)
    {
        foreach (var line in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).Reverse())
        {
            var trimmed = line.Trim();
            if (!trimmed.StartsWith('{') && !trimmed.StartsWith('[')) continue;
            try { return JsonDocument.Parse(trimmed); } catch (JsonException) { }
        }
        throw new InvalidOperationException("Pilot engine did not return machine-readable JSON.");
    }
}

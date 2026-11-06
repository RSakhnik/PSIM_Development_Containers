using System.Text.Json;

namespace PilotEnv.Api;

public sealed record EngineResult(int ExitCode, string StandardOutput, string StandardError)
{
    public string CombinedOutput => string.Join(Environment.NewLine, new[] { StandardOutput, StandardError }.Where(x => !string.IsNullOrWhiteSpace(x)));
    public void EnsureSuccess()
    {
        if (ExitCode != 0) throw new InvalidOperationException(SanitizeDiagnostic(CombinedOutput));
    }
    public static string SanitizeDiagnostic(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return "Pilot environment operation failed without diagnostic output.";
        var lines=value.Split(['\r','\n'],StringSplitOptions.RemoveEmptyEntries).TakeLast(80);
        return string.Join(Environment.NewLine,lines)
            .Replace(Environment.GetEnvironmentVariable("PILOT_ADMIN_PASSWORD") ?? "\0", "***")
            .Replace(Environment.GetEnvironmentVariable("PILOT_BIM_PASSWORD") ?? "\0", "***");
    }
}

public interface IEnvironmentEngine
{
    IDisposable PinBuild();
    Task<EngineResult> CreateAsync(string name, PublicPortPair ports, CancellationToken ct);
    Task<EngineResult> StartAsync(string name, CancellationToken ct);
    Task<EngineResult> StopAsync(string name, CancellationToken ct);
    Task<EngineResult> DeleteAsync(string name, CancellationToken ct);
    Task<EngineResult> RestartComponentAsync(string name, string component, bool cascade, CancellationToken ct);
    Task<EngineResult> RecreateAsync(string name, CancellationToken ct);
    Task<EngineResult> RefreshReleaseAsync(CancellationToken ct);
    Task<JsonDocument> GetStatusAsync(string name, CancellationToken ct);
    Task<JsonDocument> GetCapacityAsync(CancellationToken ct);
    Task<JsonDocument> GetEngineInfoAsync(CancellationToken ct);
    Task<string> GetLogsAsync(string name, string component, int tail, CancellationToken ct);
}

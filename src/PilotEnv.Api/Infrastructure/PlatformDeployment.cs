using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Options;

namespace PilotEnv.Api;

public sealed record ComponentSelection(string BuildHash);
public sealed class DeploymentState
{
    public int SchemaVersion { get; set; } = 2;
    public Dictionary<string, ComponentSelection> Components { get; set; } = new();
}

// Build identity is content, never a release number or assembly version.
public sealed class PlatformDeployment(IOptions<PilotEnvOptions> options, IWebHostEnvironment environment)
{
    public static readonly string[] ComponentNames = ["web-ui", "control-api", "environment-engine"];
    public string Root { get; } = options.Value.ResolveRepositoryRoot(environment.ContentRootPath);
    public string StatePath => Path.Combine(Root, ".pilot-runtime", "deployment-state.json");
    public string MaintenancePath => Path.Combine(Root, ".pilot-runtime", "platform-maintenance.json");
    public DeploymentState Read()
    {
        if (!File.Exists(StatePath)) return new();
        var state = JsonSerializer.Deserialize<DeploymentState>(File.ReadAllText(StatePath), JsonDefaults.Options)
            ?? throw new InvalidDataException("Invalid deployment state.");
        if (state.SchemaVersion != 2) throw new InvalidDataException("Deployment layout must be migrated using the current installer.");
        return state;
    }

    public string BuildHash(string component) => Read().Components.GetValueOrDefault(component)?.BuildHash ?? "workspace";
    public string ComponentPath(string component, string? buildHash = null)
    {
        if (!ComponentNames.Contains(component)) throw new InvalidDataException("Unknown platform component.");
        var selected = buildHash ?? Read().Components.GetValueOrDefault(component)?.BuildHash;
        if (selected is null || (selected == "workspace" && !File.Exists(StatePath)))
            return component == "web-ui" ? Path.Combine(Root, "src", "PilotEnv.Web") : Root;
        if (!Regex.IsMatch(selected, "^[a-f0-9]{64}$")) throw new InvalidDataException("Invalid component build hash.");
        return Path.Combine(Root, ".pilot-runtime", "builds", component, selected);
    }
    public MaintenanceRequest? Maintenance => File.Exists(MaintenancePath)
        ? JsonSerializer.Deserialize<MaintenanceRequest>(File.ReadAllText(MaintenancePath), JsonDefaults.Options) : null;
    public object Status
    {
        get
        {
            var state = Read();
            ComponentSelection Selection(string name) => state.Components.GetValueOrDefault(name) ?? new("workspace");
            var apiManifest = Path.Combine(AppContext.BaseDirectory, "component-manifest.json");
            var runningApiHash = File.Exists(apiManifest) ? Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(apiManifest))).ToLowerInvariant() : "workspace";
            return new { apiContractVersion = 2,
                components = new Dictionary<string, ComponentSelection> {
                    ["web-ui"] = Selection("web-ui"), ["control-api"] = new(runningApiHash), ["environment-engine"] = Selection("environment-engine") },
                capabilities = new[] { "component-updates-v1", "content-addressed-builds", "engine-protocol-v1", "port-routing", "restart-component", "operations-journal-v1" },
                update = Maintenance };
        }
    }
}

public sealed record MaintenanceRequest(string Component, string Phase = "draining");
public sealed class PlatformActivity(PlatformDeployment deployment)
{
    private readonly object _gate = new();
    private int _active;
    public int Active { get { lock (_gate) return _active; } }
    public IDisposable? TryEnter()
    {
        lock (_gate)
        {
            if (deployment.Maintenance is not null) return null;
            _active++;
            return new Lease(() => { lock (_gate) _active--; });
        }
    }
    private sealed class Lease(Action release) : IDisposable
    {
        private Action? _release = release;
        public void Dispose() => Interlocked.Exchange(ref _release, null)?.Invoke();
    }
}

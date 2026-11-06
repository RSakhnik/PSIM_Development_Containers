using System.Collections.Concurrent;
using System.Text.Json;
using Microsoft.Extensions.Options;

namespace PilotEnv.Api;

public sealed class EnvironmentService
{
    private readonly string _instancesRoot;
    private readonly string _publicHost;
    private readonly string _publicScheme;
    private readonly IEnvironmentEngine _engine;
    private readonly OperationStore _store;

    public EnvironmentService(IOptions<PilotEnvOptions> options, IWebHostEnvironment environment, IEnvironmentEngine engine, OperationStore store)
    {
        var repository = options.Value.ResolveRepositoryRoot(environment.ContentRootPath);
        _instancesRoot = Path.Combine(repository, ".pilot-instances");
        _publicHost = options.Value.PublicHost.Trim().TrimEnd('.');
        _publicScheme = options.Value.PublicScheme;
        _engine = engine;
        _store = store;
    }

    public bool Exists(string name) => File.Exists(Path.Combine(_instancesRoot, name, "instance.json"));

    public async Task<IReadOnlyList<EnvironmentStatus>> ListAsync(CancellationToken cancellationToken)
    {
        if (!Directory.Exists(_instancesRoot)) return [];
        var names = Directory.EnumerateDirectories(_instancesRoot)
            .Select(Path.GetFileName).Where(x => !string.IsNullOrWhiteSpace(x)).Cast<string>().OrderBy(x => x).ToArray();
        var metadata = await _store.GetMetadataAsync(cancellationToken);
        var latest = await _store.GetLatestByEnvironmentAsync(cancellationToken);
        var results = new ConcurrentBag<EnvironmentStatus>();
        await Parallel.ForEachAsync(names, new ParallelOptions { MaxDegreeOfParallelism = 4, CancellationToken = cancellationToken }, async (name, ct) =>
        {
            results.Add(await GetCoreAsync(name, metadata.GetValueOrDefault(name), latest.GetValueOrDefault(name), ct));
        });
        var existing = results.Select(x => x.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var operation in await _store.GetActiveAsync(cancellationToken))
        {
            if (operation.Kind != "create" || operation.EnvironmentName is null || operation.EnvironmentName.StartsWith('$') || existing.Contains(operation.EnvironmentName)) continue;
            var itemMetadata = metadata.GetValueOrDefault(operation.EnvironmentName);
            var publicPorts = await _store.GetPublicPortsForEnvironmentAsync(operation.EnvironmentName, cancellationToken);
            results.Add(new EnvironmentStatus
            {
                Name = operation.EnvironmentName, Mode = "bim-dev", Product = "Pilot-BIM", State = "provisioning",
                Owner = itemMetadata?.Owner, Description = itemMetadata?.Description, ActiveOperationId = operation.Id, LastOperation = OperationSummary.From(operation),
                PublicPorts = publicPorts,
                WebUrl = publicPorts is null ? null : PublicUrl(publicPorts.Web),
                AdminUrl = publicPorts is null ? null : PublicUrl(publicPorts.Admin)
            });
        }
        return results.OrderBy(x => x.Name).ToArray();
    }

    public async Task<EnvironmentStatus?> GetAsync(string name, CancellationToken cancellationToken)
    {
        if (!Exists(name)) return null;
        var metadata = await _store.GetMetadataAsync(cancellationToken);
        var latest = await _store.GetLatestByEnvironmentAsync(cancellationToken);
        return await GetCoreAsync(name, metadata.GetValueOrDefault(name), latest.GetValueOrDefault(name), cancellationToken);
    }

    public bool TryResolveProxy(int publicPort, out string? environmentName, out string? destination)
    {
        environmentName = null;
        destination = null;
        if (!Directory.Exists(_instancesRoot)) return false;
        foreach (var directory in Directory.EnumerateDirectories(_instancesRoot))
        {
            try
            {
                using var config = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "instance.json")));
                if (!config.RootElement.TryGetProperty("publicPorts", out var publicPorts)) continue;
                var webPublic = publicPorts.GetProperty("web").GetInt32();
                var adminPublic = publicPorts.GetProperty("admin").GetInt32();
                if (publicPort != webPublic && publicPort != adminPublic) continue;
                var internalPortName = publicPort == adminPublic ? "admin" : "web";
                var internalPort = config.RootElement.GetProperty("ports").GetProperty(internalPortName).GetInt32();
                environmentName = config.RootElement.GetProperty("name").GetString() ?? Path.GetFileName(directory);
                destination = $"http://127.0.0.1:{internalPort}/";
                return true;
            }
            catch { }
        }
        return false;
    }

    public IReadOnlyList<PublicPortPair> GetConfiguredPublicPorts()
    {
        var result = new List<PublicPortPair>();
        if (!Directory.Exists(_instancesRoot)) return result;
        foreach (var path in Directory.EnumerateFiles(_instancesRoot, "instance.json", SearchOption.AllDirectories))
        {
            try
            {
                using var config = JsonDocument.Parse(File.ReadAllText(path));
                if (!config.RootElement.TryGetProperty("publicPorts", out var ports)) continue;
                result.Add(new PublicPortPair(ports.GetProperty("web").GetInt32(), ports.GetProperty("admin").GetInt32()));
            }
            catch { }
        }
        return result;
    }

    private async Task<EnvironmentStatus> GetCoreAsync(string name, EnvironmentMetadata? metadata, OperationSummary? lastOperation, CancellationToken cancellationToken)
    {
        try
        {
            using var document = await _engine.GetStatusAsync(name, cancellationToken);
            var source = JsonSerializer.Deserialize<EnvironmentStatus>(document.RootElement.GetRawText(), JsonDefaults.Options)
                ?? throw new InvalidOperationException("Empty environment status.");
            var operation = lastOperation?.State is "queued" or "running" ? lastOperation : null;
            var state = operation is null ? source.State : operation.Kind switch
            {
                "create" => "provisioning", "start" => "starting", "stop" => "stopping",
                "recreate" => "recreating", "delete" => "deleting", _ => source.State
            };
            var publicPorts = ReadPublicPorts(name);
            return new EnvironmentStatus
            {
                Name = source.Name, Mode = source.Mode, Product = source.Product, State = state,
                ReadOnly = !string.Equals(source.Mode, "bim-dev", StringComparison.OrdinalIgnoreCase),
                Owner = metadata?.Owner, Description = metadata?.Description,
                WebPort = source.WebPort, AdminPort = source.AdminPort, ServerPort = source.ServerPort,
                PublicPorts = publicPorts,
                WebUrl = publicPorts is null ? null : PublicUrl(publicPorts.Web),
                AdminUrl = publicPorts is null ? null : PublicUrl(publicPorts.Admin),
                Images = source.Images, Versions = source.Versions, Components = source.Components,
                ActiveOperationId = operation?.Id, LastOperation = lastOperation, LastError = source.LastError
            };
        }
        catch (Exception ex)
        {
            var mode = "unknown";
            try
            {
                using var config = JsonDocument.Parse(File.ReadAllText(Path.Combine(_instancesRoot, name, "instance.json")));
                mode = config.RootElement.GetProperty("mode").GetString() ?? "unknown";
            }
            catch { }
            return new EnvironmentStatus
            {
                Name = name, Mode = mode, Product = mode == "bim-dev" ? "Pilot-BIM" : "Unknown",
                State = "failed", ReadOnly = mode != "bim-dev", Owner = metadata?.Owner,
                Description = metadata?.Description, LastOperation = lastOperation, LastError = ex.Message
            };
        }
    }

    private PublicPortPair? ReadPublicPorts(string name)
    {
        try
        {
            using var config = JsonDocument.Parse(File.ReadAllText(Path.Combine(_instancesRoot, name, "instance.json")));
            var ports = config.RootElement.GetProperty("publicPorts");
            return new PublicPortPair(ports.GetProperty("web").GetInt32(), ports.GetProperty("admin").GetInt32());
        }
        catch { return null; }
    }

    private string PublicUrl(int port) => $"{_publicScheme}://{_publicHost}:{port}";
}

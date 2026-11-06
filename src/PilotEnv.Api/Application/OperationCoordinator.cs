using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Channels;
using Microsoft.Extensions.Options;

namespace PilotEnv.Api;

public sealed partial class OperationCoordinator : BackgroundService
{
    private readonly Channel<Guid> _queue = Channel.CreateUnbounded<Guid>(new UnboundedChannelOptions { SingleWriter = false, SingleReader = false });
    private readonly ConcurrentDictionary<string, SemaphoreSlim> _environmentLocks = new(StringComparer.OrdinalIgnoreCase);
    private readonly SemaphoreSlim _admissionLock = new(1, 1);
    private readonly OperationStore _store;
    private readonly CapacityService _capacity;
    private readonly EnvironmentService _environments;
    private readonly IEnvironmentEngine _engine;
    private readonly PlatformActivity _activity;
    private readonly PilotEnvOptions _options;
    private readonly ILogger<OperationCoordinator> _logger;

    public OperationCoordinator(OperationStore store, CapacityService capacity, EnvironmentService environments,
        IEnvironmentEngine engine, IOptions<PilotEnvOptions> options, ILogger<OperationCoordinator> logger, PlatformActivity activity)
    {
        _store = store;
        _capacity = capacity;
        _environments = environments;
        _engine = engine;
        _activity = activity;
        _options = options.Value;
        _logger = logger;
    }

    public async Task<OperationRecord> QueueCreateAsync(CreateEnvironmentRequest request, string? idempotencyKey, CancellationToken cancellationToken)
    {
        ValidateName(request.Name);
        if (string.IsNullOrWhiteSpace(request.Owner) || request.Owner.Length > 80)
            throw new ApiProblemException("invalid_owner", "Owner is required and must not exceed 80 characters.");
        if (request.Description?.Length > 500)
            throw new ApiProblemException("invalid_description", "Description must not exceed 500 characters.");

        await _admissionLock.WaitAsync(cancellationToken);
        try
        {
            var json = JsonSerializer.Serialize(request, JsonDefaults.Options);
            var idempotent = await _store.GetByIdempotencyAsync("create", request.Name, null, idempotencyKey, json, cancellationToken);
            if (idempotent is not null) return idempotent;
            if (_environments.Exists(request.Name)) throw new ApiProblemException("environment_exists", "Environment already exists.", 409);
            await EnsureCapacityAsync(cancellationToken);
            var publicPorts = await AllocatePublicPortsAsync(cancellationToken);
            var record = await _store.CreateAsync("create", request.Name, null, json, idempotencyKey, true,
                _options.PerEnvironmentMemoryGiB, publicPorts, cancellationToken);
            await _store.SetMetadataAsync(new EnvironmentMetadata { Name = request.Name, Owner = request.Owner.Trim(), Description = request.Description?.Trim() }, cancellationToken);
            await _queue.Writer.WriteAsync(record.Id, cancellationToken);
            return record;
        }
        finally { _admissionLock.Release(); }
    }

    public Task<OperationRecord> QueueStartAsync(string name, string? key, CancellationToken ct) => QueueEnvironmentAsync("start", name, null, null, key, true, ct);
    public Task<OperationRecord> QueueStopAsync(string name, string? key, CancellationToken ct) => QueueEnvironmentAsync("stop", name, null, null, key, false, ct);
    public Task<OperationRecord> QueueDeleteAsync(string name, string? key, CancellationToken ct) => QueueEnvironmentAsync("delete", name, null, null, key, false, ct);
    public Task<OperationRecord> QueueRecreateAsync(string name, string? key, CancellationToken ct) => QueueEnvironmentAsync("recreate", name, null, null, key, true, ct);

    public Task<OperationRecord> QueueRestartAsync(string name, string component, bool cascade, string? key, CancellationToken ct)
    {
        if (!Components.Allowed.Contains(component)) throw new ApiProblemException("component_unavailable", "Unknown Pilot component.", 404);
        if (cascade && !component.Equals("pilot-server", StringComparison.OrdinalIgnoreCase))
            throw new ApiProblemException("invalid_cascade", "Cascade is supported only for pilot-server.");
        return QueueEnvironmentAsync("restart", name, component, JsonSerializer.Serialize(new RestartComponentRequest(cascade), JsonDefaults.Options), key, false, ct);
    }

    public async Task<OperationRecord> QueueRefreshReleaseAsync(string? key, CancellationToken ct)
    {
        await _admissionLock.WaitAsync(ct);
        try
        {
            const string reservationName = "$release-validation";
            var idempotent = await _store.GetByIdempotencyAsync("refresh-release", reservationName, null, key, null, ct);
            if (idempotent is not null) return idempotent;
            await EnsureCapacityAsync(ct, requirePreparedRelease: false);
            var record = await _store.CreateAsync("refresh-release", reservationName, null, null, key, true, _options.PerEnvironmentMemoryGiB, null, ct);
            await _queue.Writer.WriteAsync(record.Id, ct);
            return record;
        }
        finally { _admissionLock.Release(); }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        foreach (var id in await _store.GetQueuedIdsAsync(stoppingToken)) await _queue.Writer.WriteAsync(id, stoppingToken);
        var count = Math.Clamp(_options.OperationConcurrency, 1, 8);
        await Task.WhenAll(Enumerable.Range(0, count).Select(_ => WorkerLoopAsync(stoppingToken)));
    }

    private async Task WorkerLoopAsync(CancellationToken cancellationToken)
    {
        await foreach (var id in _queue.Reader.ReadAllAsync(cancellationToken))
        {
            try { await ExecuteOperationAsync(id, cancellationToken); }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
            catch (Exception ex) { _logger.LogError(ex, "Unhandled operation worker failure for {OperationId}", id); }
        }
    }

    private async Task ExecuteOperationAsync(Guid id, CancellationToken cancellationToken)
    {
        var operation = await _store.GetAsync(id, cancellationToken);
        if (operation is null || operation.State != "queued") return;
        IDisposable? activity;
        while ((activity = _activity.TryEnter()) is null) await Task.Delay(250, cancellationToken);
        using var activityLease = activity;
        using var engineBuild = _engine.PinBuild();
        var lockKey = operation.EnvironmentName ?? "$release";
        var gate = _environmentLocks.GetOrAdd(lockKey, _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(cancellationToken);
        try
        {
            await _store.MarkRunningAsync(id, cancellationToken);
            EngineResult result = operation.Kind switch
            {
                "create" => await _engine.CreateAsync(operation.EnvironmentName!,
                    await _store.GetPublicPortsForEnvironmentAsync(operation.EnvironmentName!, cancellationToken)
                        ?? throw new InvalidOperationException("Public port reservation is missing."), cancellationToken),
                "start" => await _engine.StartAsync(operation.EnvironmentName!, cancellationToken),
                "stop" => await _engine.StopAsync(operation.EnvironmentName!, cancellationToken),
                "delete" => await _engine.DeleteAsync(operation.EnvironmentName!, cancellationToken),
                "recreate" => await _engine.RecreateAsync(operation.EnvironmentName!, cancellationToken),
                "restart" => await RestartAsync(operation, cancellationToken),
                "refresh-release" => await _engine.RefreshReleaseAsync(cancellationToken),
                _ => throw new InvalidOperationException($"Unknown operation kind: {operation.Kind}")
            };
            result.EnsureSuccess();
            if (operation.Kind == "create") await _store.CommitPublicPortsAsync(operation.Id, cancellationToken);
            if (operation.Kind == "delete")
            {
                await _store.RemoveMetadataAsync(operation.EnvironmentName!, cancellationToken);
                await _store.ReleasePublicPortsAsync(operation.EnvironmentName!, cancellationToken);
            }
            var diagnostic = EngineResult.SanitizeDiagnostic(result.CombinedOutput);
            await _store.CompleteAsync(id, JsonSerializer.Serialize(new { message = diagnostic }, JsonDefaults.Options), cancellationToken);
        }
        catch (Exception ex)
        {
            if (operation.Kind == "create" && operation.EnvironmentName is not null)
            {
                if (_environments.Exists(operation.EnvironmentName)) await _store.CommitPublicPortsAsync(operation.Id, cancellationToken);
                else await _store.RemoveMetadataAsync(operation.EnvironmentName, cancellationToken);
            }
            await _store.FailAsync(id, EngineResult.SanitizeDiagnostic(ex.Message), cancellationToken);
        }
        finally { gate.Release(); }
    }

    private async Task<EngineResult> RestartAsync(OperationRecord operation, CancellationToken cancellationToken)
    {
        var request = operation.RequestJson is null
            ? new RestartComponentRequest()
            : JsonSerializer.Deserialize<RestartComponentRequest>(operation.RequestJson, JsonDefaults.Options) ?? new RestartComponentRequest();
        return await _engine.RestartComponentAsync(operation.EnvironmentName!, operation.Component!, request.Cascade, cancellationToken);
    }

    private async Task<OperationRecord> QueueEnvironmentAsync(string kind, string name, string? component, string? requestJson,
        string? idempotencyKey, bool reserveMemory, CancellationToken cancellationToken)
    {
        ValidateName(name);
        await _admissionLock.WaitAsync(cancellationToken);
        try
        {
            var idempotent = await _store.GetByIdempotencyAsync(kind, name, component, idempotencyKey, requestJson, cancellationToken);
            if (idempotent is not null) return idempotent;
            var status = await _environments.GetAsync(name, cancellationToken)
                ?? throw new ApiProblemException("not_found", "Environment was not found.", 404);
            if (status.ReadOnly) throw new ApiProblemException("legacy_read_only", "ICE-dev environments are read-only through this API.", 409);
            if (await _store.GetActiveForEnvironmentAsync(name, cancellationToken) is not null)
                throw new ApiProblemException("operation_conflict", "Another operation is already queued or running for this environment.", 409);
            if (kind == "start" && status.State == "running") throw new ApiProblemException("already_running", "Environment is already running.", 409);
            if (kind == "stop" && status.State == "stopped") throw new ApiProblemException("already_stopped", "Environment is already stopped.", 409);
            if (kind == "restart" && status.State is not ("running" or "degraded")) throw new ApiProblemException("environment_not_running", "Component restart requires a running or degraded environment.", 409);
            var needsReservation = reserveMemory && !(kind == "recreate" && status.State == "running");
            if (needsReservation) await EnsureCapacityAsync(cancellationToken);
            var record = await _store.CreateAsync(kind, name, component, requestJson, idempotencyKey, needsReservation,
                _options.PerEnvironmentMemoryGiB, null, cancellationToken);
            await _queue.Writer.WriteAsync(record.Id, cancellationToken);
            return record;
        }
        finally { _admissionLock.Release(); }
    }

    private async Task EnsureCapacityAsync(CancellationToken cancellationToken, bool requirePreparedRelease = true)
    {
        var capacity = await _capacity.GetAsync(cancellationToken);
        var infrastructureReady = capacity.Prerequisites.DockerReady && capacity.Prerequisites.LicenseReady &&
                                  capacity.AvailableSlots > 0 && capacity.Disk.FreeGiB >= capacity.Disk.MinimumFreeGiB &&
                                  capacity.Blockers.All(x => x.Code != "ports_unavailable");
        var ready = infrastructureReady && (!requirePreparedRelease ||
            (capacity.Prerequisites.ReleaseReady && capacity.Prerequisites.TemplateReady));
        if (!ready)
            throw new ApiProblemException("capacity_unavailable", string.Join("; ", capacity.Blockers.Select(x => x.Message)), 409);
    }

    private async Task<PublicPortPair> AllocatePublicPortsAsync(CancellationToken cancellationToken)
    {
        var webCount = _options.WebPublicPortEnd - _options.WebPublicPortStart + 1;
        var adminCount = _options.AdminPublicPortEnd - _options.AdminPublicPortStart + 1;
        if (webCount <= 0 || webCount != adminCount)
            throw new ApiProblemException("public_ports_unavailable", "Public Web and myAdmin port ranges must be non-empty and have equal length.", 409);

        var assigned = await _store.GetPublicPortAssignmentsAsync(cancellationToken);
        var used = assigned.Values.Concat(_environments.GetConfiguredPublicPorts()).ToArray();
        for (var offset = 0; offset < webCount; offset++)
        {
            var pair = new PublicPortPair(_options.WebPublicPortStart + offset, _options.AdminPublicPortStart + offset);
            if (used.All(x => x.Web != pair.Web && x.Admin != pair.Admin)) return pair;
        }
        throw new ApiProblemException("public_ports_unavailable", "No public Web/myAdmin port pairs are available.", 409);
    }

    public static void ValidateName(string name)
    {
        if (!EnvironmentNameRegex().IsMatch(name) || name is "control" or "api" || name.StartsWith("admin-", StringComparison.OrdinalIgnoreCase))
            throw new ApiProblemException("invalid_name", "Name must be a DNS-safe lowercase slug, must not be reserved, and may contain at most 40 characters.");
    }

    [GeneratedRegex("^[a-z0-9][a-z0-9-]{0,39}$", RegexOptions.CultureInvariant)]
    private static partial Regex EnvironmentNameRegex();
}

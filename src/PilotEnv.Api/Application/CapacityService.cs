using System.Text.Json;
using Microsoft.Extensions.Options;

namespace PilotEnv.Api;

public sealed class CapacityService(IEnvironmentEngine engine, OperationStore store, EnvironmentService environments, IOptions<PilotEnvOptions> options)
{
    private readonly PilotEnvOptions _options = options.Value;

    public async Task<CapacitySnapshot> GetAsync(CancellationToken cancellationToken)
    {
        CapacitySnapshot snapshot;
        try
        {
            using var document = await engine.GetCapacityAsync(cancellationToken);
            snapshot = JsonSerializer.Deserialize<CapacitySnapshot>(document.RootElement.GetRawText(), JsonDefaults.Options)
                ?? throw new InvalidOperationException("Empty capacity response.");
        }
        catch (Exception ex)
        {
            return new CapacitySnapshot
            {
                CanStart = false,
                AvailableSlots = 0,
                Blockers = [new CapacityBlocker("docker_unavailable", ex.Message)],
                Memory = new MemoryCapacity(0, 0, _options.SafetyReserveMemoryGiB, _options.PerEnvironmentMemoryGiB),
                Disk = new DiskCapacity(0, _options.MinimumFreeDiskGiB),
                Prerequisites = new CapacityPrerequisites(false, false, false, false),
                PublicPorts = BuildPublicPortCapacity(0)
            };
        }

        var pendingReservations = await store.GetReservedEnvironmentNamesAsync(cancellationToken);
        var extraReserved = _options.DisableMemoryAdmission ? 0 : pendingReservations.Count * _options.PerEnvironmentMemoryGiB;
        var reserved = snapshot.Memory.ReservedGiB + extraReserved;
        var availableSlots = _options.DisableMemoryAdmission ? int.MaxValue : Math.Max(0, (int)Math.Floor(
            (snapshot.Memory.DockerTotalGiB - snapshot.Memory.SafetyReserveGiB - reserved) /
            snapshot.Memory.PerEnvironmentGiB));
        var blockers = snapshot.Blockers.ToList();
        if (!_options.DisableMemoryAdmission && availableSlots == 0 && blockers.All(x => x.Code != "insufficient_memory"))
            blockers.Add(new CapacityBlocker("insufficient_memory", "All BIM memory slots are running or reserved by queued operations."));
        if (_options.DisableMemoryAdmission) blockers.RemoveAll(x => x.Code == "insufficient_memory");

        var assignments = await store.GetPublicPortAssignmentsAsync(cancellationToken);
        var usedPairs = assignments.Values.Concat(environments.GetConfiguredPublicPorts())
            .Distinct().Count();
        var configuredPairs = Math.Min(
            Math.Max(0, _options.WebPublicPortEnd - _options.WebPublicPortStart + 1),
            Math.Max(0, _options.AdminPublicPortEnd - _options.AdminPublicPortStart + 1));
        var availablePortPairs = Math.Max(0, configuredPairs - usedPairs);
        if (availablePortPairs == 0 && blockers.All(x => x.Code != "public_ports_unavailable"))
            blockers.Add(new CapacityBlocker("public_ports_unavailable", "All configured public Web/myAdmin port pairs are assigned."));

        return new CapacitySnapshot
        {
            CanStart = (snapshot.CanStart || (_options.DisableMemoryAdmission && snapshot.Blockers.All(x => x.Code == "insufficient_memory"))) && availableSlots > 0 && availablePortPairs > 0,
            AvailableSlots = Math.Min(availableSlots, availablePortPairs),
            Blockers = blockers,
            Memory = snapshot.Memory with { ReservedGiB = reserved },
            Disk = snapshot.Disk,
            Prerequisites = snapshot.Prerequisites,
            PublicPorts = BuildPublicPortCapacity(availablePortPairs)
        };
    }

    private PublicPortCapacity BuildPublicPortCapacity(int availablePairs) => new(availablePairs,
        _options.WebPublicPortStart, _options.WebPublicPortEnd,
        _options.AdminPublicPortStart, _options.AdminPublicPortEnd);
}

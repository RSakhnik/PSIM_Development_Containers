using System.Text.Json;

namespace PilotEnv.Api;

public static class Components
{
    public static readonly HashSet<string> Allowed = new(StringComparer.OrdinalIgnoreCase)
    {
        "pilot-server", "pilot-bim-server", "pilot-web-server", "pilot-web-myadmin"
    };
}

public sealed record CreateEnvironmentRequest(string Name, string Owner, string? Description);
public sealed record RestartComponentRequest(bool Cascade = false);
public sealed record ConfirmRequest(string ConfirmName);
public sealed record SessionRequest(string Token);

public sealed record QueuedOperationResponse(Guid OperationId, string State = "queued");
public sealed record PublicPortPair(int Web, int Admin);

public sealed class OperationRecord
{
    public Guid Id { get; init; }
    public string Kind { get; init; } = "";
    public string? EnvironmentName { get; init; }
    public string? Component { get; init; }
    public string State { get; set; } = "queued";
    public string? RequestJson { get; init; }
    public string? ResultJson { get; set; }
    public string? Error { get; set; }
    public DateTimeOffset CreatedAt { get; init; }
    public DateTimeOffset? StartedAt { get; set; }
    public DateTimeOffset? FinishedAt { get; set; }
}

public sealed record OperationSummary(Guid Id, string Kind, string? EnvironmentName, string? Component,
    string State, DateTimeOffset CreatedAt, DateTimeOffset? StartedAt, DateTimeOffset? FinishedAt)
{
    public static OperationSummary From(OperationRecord value) => new(value.Id, value.Kind, value.EnvironmentName,
        value.Component, value.State, value.CreatedAt, value.StartedAt, value.FinishedAt);
}
public sealed record OperationPage(IReadOnlyList<OperationSummary> Items, string? NextCursor);

public sealed class EnvironmentMetadata
{
    public string Name { get; init; } = "";
    public string Owner { get; init; } = "";
    public string? Description { get; init; }
}

public sealed class ComponentStatus
{
    public string Name { get; init; } = "";
    public string State { get; init; } = "unknown";
    public bool Healthy { get; init; }
    public string? ContainerId { get; init; }
    public int RestartCount { get; init; }
    public DateTimeOffset? StartedAt { get; init; }
    public string? LastError { get; init; }
}

public sealed class EnvironmentStatus
{
    public string Name { get; init; } = "";
    public string Mode { get; init; } = "";
    public string Product { get; init; } = "";
    public string State { get; init; } = "unknown";
    public bool ReadOnly { get; init; }
    public string? Owner { get; init; }
    public string? Description { get; init; }
    public int WebPort { get; init; }
    public int AdminPort { get; init; }
    public int ServerPort { get; init; }
    public PublicPortPair? PublicPorts { get; init; }
    public string? WebUrl { get; init; }
    public string? AdminUrl { get; init; }
    public JsonElement? Images { get; init; }
    public JsonElement? Versions { get; init; }
    public IReadOnlyList<ComponentStatus> Components { get; init; } = [];
    public Guid? ActiveOperationId { get; init; }
    public OperationSummary? LastOperation { get; init; }
    public string? LastError { get; init; }
}

public sealed class CapacitySnapshot
{
    public bool CanStart { get; init; }
    public int AvailableSlots { get; init; }
    public IReadOnlyList<CapacityBlocker> Blockers { get; init; } = [];
    public required MemoryCapacity Memory { get; init; }
    public required DiskCapacity Disk { get; init; }
    public required CapacityPrerequisites Prerequisites { get; init; }
    public PublicPortCapacity? PublicPorts { get; init; }
}

public sealed record CapacityBlocker(string Code, string Message);
public sealed record MemoryCapacity(double DockerTotalGiB, double ReservedGiB, double SafetyReserveGiB, double PerEnvironmentGiB);
public sealed record DiskCapacity(double FreeGiB, double MinimumFreeGiB);
public sealed record CapacityPrerequisites(bool DockerReady, bool LicenseReady, bool ReleaseReady, bool TemplateReady);
public sealed record PublicPortCapacity(int AvailablePairs, int WebStart, int WebEnd, int AdminStart, int AdminEnd);

public sealed class ApiProblemException(string code, string message, int statusCode = 400) : Exception(message)
{
    public string Code { get; } = code;
    public int StatusCode { get; } = statusCode;
}

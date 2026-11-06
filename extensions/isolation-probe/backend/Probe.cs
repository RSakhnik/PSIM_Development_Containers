using System.ComponentModel.Composition;
using System.Diagnostics;
using System.Text.Json;
using Pilot.WebServer.SDK;
namespace PilotEnvironment.IsolationProbe;
[Export(typeof(ICommandHost))]
public sealed class IsolationProbeBackend : ICommandHost
{
    private static readonly string BackendLaunchId = Guid.NewGuid().ToString("D");
    private static readonly DateTimeOffset BackendInitializedAt = DateTimeOffset.UtcNow;
    [Command]
    public string IsolationProbeStatus(string nonce) => JsonSerializer.Serialize(new {
        backendVersion = ProbeBuild.Marker,
        backendLaunchId = BackendLaunchId,
        backendInitializedAt = BackendInitializedAt,
        processId = Environment.ProcessId,
        processStartedAt = new DateTimeOffset(Process.GetCurrentProcess().StartTime.ToUniversalTime()),
        observedAt = DateTimeOffset.UtcNow,
        nonce
    });
}

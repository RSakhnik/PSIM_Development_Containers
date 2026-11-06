namespace PilotEnv.Api;

public sealed class PilotEnvOptions
{
    public const string SectionName = "PilotEnv";

    public string RepositoryRoot { get; set; } = "../..";
    public string ListenUrl { get; set; } = "http://127.0.0.1:17070";
    public string PublicHost { get; set; } = "360pilot.ru";
    public string PublicScheme { get; set; } = "https";
    public int ControlPublicPort { get; set; } = 17443;
    public int WebPublicPortStart { get; set; } = 18000;
    public int WebPublicPortEnd { get; set; } = 18049;
    public int AdminPublicPortStart { get; set; } = 19000;
    public int AdminPublicPortEnd { get; set; } = 19049;
    public double MinimumFreeDiskGiB { get; set; } = 20;
    public double PerEnvironmentMemoryGiB { get; set; } = 8;
    public double SafetyReserveMemoryGiB { get; set; } = 8;
    public int OperationConcurrency { get; set; } = 2;
    public bool DisableMemoryAdmission { get; set; }
    public string SecretFile { get; set; } = ".pilot-runtime/api/secrets.json";
    public string LicenseFile { get; set; } = ".pilot-runtime/api/license/current.pilotlic";
    public string ConfigurationFile { get; set; } = "configuration_pilot-bim_ru.pilotcfx";
    public string DatabaseFile { get; set; } = ".pilot-runtime/api/pilot-env.db";
    public string PowerShellExecutable { get; set; } = "powershell.exe";

    public string ResolveRepositoryRoot(string contentRoot)
    {
        var value = Path.IsPathRooted(RepositoryRoot)
            ? RepositoryRoot
            : Path.Combine(contentRoot, RepositoryRoot);
        return Path.GetFullPath(value);
    }

    public string ResolvePath(string contentRoot, string configuredPath)
    {
        if (Path.IsPathRooted(configuredPath)) return Path.GetFullPath(configuredPath);
        return Path.GetFullPath(Path.Combine(ResolveRepositoryRoot(contentRoot), configuredPath));
    }
}

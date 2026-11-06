using System.Text.Json;
using PilotEnv.Api;
using Xunit;

namespace PilotEnv.Api.Tests;

public sealed class SecurityAndContractTests
{
    [Fact]
    public void TokenHash_RoundTrips_AndRejectsAnotherToken()
    {
        var token = Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32));
        var hash = TokenHasher.Hash(token);

        Assert.True(TokenHasher.Verify(token, hash));
        Assert.False(TokenHasher.Verify(token + "x", hash));
        Assert.DoesNotContain(token, hash, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("feature-a")]
    [InlineData("a")]
    [InlineData("team7-bim-42")]
    public void EnvironmentName_AcceptsDnsSafeNames(string name) => OperationCoordinator.ValidateName(name);

    [Theory]
    [InlineData("Control")]
    [InlineData("control")]
    [InlineData("api")]
    [InlineData("admin-demo")]
    [InlineData("bad_name")]
    [InlineData("-bad")]
    public void EnvironmentName_RejectsUnsafeOrReservedNames(string name) =>
        Assert.Throws<ApiProblemException>(() => OperationCoordinator.ValidateName(name));

    [Fact]
    public void OpenApi_ContainsRequiredLifecycleEndpoints()
    {
        var path = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "src", "PilotEnv.Api", "Contracts", "openapi-v1.json"));
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var paths = document.RootElement.GetProperty("paths");
        Assert.True(paths.TryGetProperty("/api/v1/environments", out _));
        Assert.True(paths.TryGetProperty("/api/v1/environments/{name}/components/{component}/restart", out _));
        Assert.True(paths.TryGetProperty("/api/v1/capacity", out _));
        Assert.True(paths.TryGetProperty("/api/v1/operations/{id}", out _));
        Assert.Equal("https://360pilot.ru:17443", document.RootElement.GetProperty("servers")[0].GetProperty("url").GetString());
    }
}

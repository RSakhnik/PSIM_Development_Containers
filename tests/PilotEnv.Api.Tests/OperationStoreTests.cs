using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Options;
using Microsoft.AspNetCore.Hosting;
using PilotEnv.Api;
using Xunit;

namespace PilotEnv.Api.Tests;

public sealed class OperationStoreTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "pilot-env-tests", Guid.NewGuid().ToString("N"));

    [Fact]
    public async Task Idempotency_ReturnsOriginalOperation_AndRejectsChangedRequest()
    {
        Directory.CreateDirectory(_root);
        var store = CreateStore();
        await store.InitializeAsync();

        var first = await store.CreateAsync("create", "demo", null, "{\"name\":\"demo\"}", "same-key", true, 8, new PublicPortPair(18000, 19000), default);
        var second = await store.GetByIdempotencyAsync("create", "demo", null, "same-key", "{\"name\":\"demo\"}", default);

        Assert.NotNull(second);
        Assert.Equal(first.Id, second!.Id);
        await Assert.ThrowsAsync<ApiProblemException>(() =>
            store.GetByIdempotencyAsync("create", "demo", null, "same-key", "{\"name\":\"other\"}", default));
    }

    [Fact]
    public async Task CompletedOperation_ReleasesMemoryReservation()
    {
        Directory.CreateDirectory(_root);
        var store = CreateStore();
        await store.InitializeAsync();
        var operation = await store.CreateAsync("start", "demo", null, null, null, true, 8, null, default);
        Assert.Contains("demo", await store.GetReservedEnvironmentNamesAsync(default));

        await store.MarkRunningAsync(operation.Id, default);
        await store.CompleteAsync(operation.Id, "{}", default);

        Assert.DoesNotContain("demo", await store.GetReservedEnvironmentNamesAsync(default));
        Assert.Equal("succeeded", (await store.GetAsync(operation.Id, default))!.State);
    }

    [Fact]
    public async Task PublicPorts_AreUnique_AndRemainAssignedAfterCreateCompletes()
    {
        Directory.CreateDirectory(_root);
        var store = CreateStore();
        await store.InitializeAsync();
        var first = await store.CreateAsync("create", "first", null, null, null, true, 8, new PublicPortPair(18000, 19000), default);

        await Assert.ThrowsAsync<ApiProblemException>(() =>
            store.CreateAsync("create", "second", null, null, null, true, 8, new PublicPortPair(18000, 19000), default));

        await store.CommitPublicPortsAsync(first.Id, default);
        await store.CompleteAsync(first.Id, "{}", default);
        Assert.Equal(new PublicPortPair(18000, 19000), await store.GetPublicPortsForEnvironmentAsync("first", default));
    }

    [Fact]
    public async Task FailedCreate_ReleasesUncommittedPublicPorts()
    {
        Directory.CreateDirectory(_root);
        var store = CreateStore();
        await store.InitializeAsync();
        var failed = await store.CreateAsync("create", "failed", null, null, null, true, 8, new PublicPortPair(18000, 19000), default);
        await store.FailAsync(failed.Id, "failed", default);

        Assert.Null(await store.GetPublicPortsForEnvironmentAsync("failed", default));
        var retry = await store.CreateAsync("create", "retry", null, null, null, true, 8, new PublicPortPair(18000, 19000), default);
        Assert.NotEqual(failed.Id, retry.Id);
    }

    [Fact]
    public async Task Startup_ReconcilesPublicPortAssignmentsWithInstanceFiles()
    {
        Directory.CreateDirectory(_root);
        var store = CreateStore();
        await store.InitializeAsync();
        var completed = await store.CreateAsync("create", "gone", null, null, null, true, 8, new PublicPortPair(18000, 19000), default);
        await store.CommitPublicPortsAsync(completed.Id, default);
        await store.CompleteAsync(completed.Id, "{}", default);

        var interrupted = await store.CreateAsync("create", "present", null, null, null, true, 8, new PublicPortPair(18001, 19001), default);
        await store.MarkRunningAsync(interrupted.Id, default);
        var instance = Path.Combine(_root, ".pilot-instances", "present");
        Directory.CreateDirectory(instance);
        await File.WriteAllTextAsync(Path.Combine(instance, "instance.json"), "{}");

        var restarted = CreateStore();
        await restarted.InitializeAsync();
        Assert.Null(await restarted.GetPublicPortsForEnvironmentAsync("gone", default));
        Assert.Equal(new PublicPortPair(18001, 19001), await restarted.GetPublicPortsForEnvironmentAsync("present", default));
        Assert.Equal("failed", (await restarted.GetAsync(interrupted.Id, default))!.State);
    }

    [Fact]
    public async Task Startup_PreservesQueuedCreateAndItsPortAndMemoryReservations()
    {
        Directory.CreateDirectory(_root);
        var store=CreateStore();await store.InitializeAsync();
        var operation=await store.CreateAsync("create","queued",null,"{}","stable-key",true,8,new PublicPortPair(18002,19002),default);
        var restarted=CreateStore();await restarted.InitializeAsync();
        Assert.Equal("queued",(await restarted.GetAsync(operation.Id,default))!.State);
        Assert.Equal(new PublicPortPair(18002,19002),await restarted.GetPublicPortsForEnvironmentAsync("queued",default));
        Assert.Contains(operation.Id,await restarted.GetQueuedIdsAsync(default));
        Assert.Contains("queued",await restarted.GetReservedEnvironmentNamesAsync(default));
    }

    [Fact]
    public async Task History_FiltersPagesAndKeepsDeletedEnvironmentWithoutPayloads()
    {
        Directory.CreateDirectory(_root);var store=CreateStore();await store.InitializeAsync();
        var ids=new List<Guid>();
        for(var i=0;i<7;i++){
            var op=await store.CreateAsync(i%2==0?"restart":"start",i%2==0?"deleted-demo":"other","pilot-web-server","sensitive-request",null,false,8,null,default);
            ids.Add(op.Id);if(i%2==0)await store.CompleteAsync(op.Id,"sensitive-result",default);
        }
        // Exercise the tie-breaker, not only different timestamps.
        var db=new Microsoft.Data.Sqlite.SqliteConnection($"Data Source={Path.Combine(_root,"state.db")};Pooling=False");
        await db.OpenAsync();var sql=db.CreateCommand();sql.CommandText="UPDATE operations SET created_at='2026-10-26T00:00:00.0000000+00:00'";await sql.ExecuteNonQueryAsync();await db.DisposeAsync();
        var received=new List<Guid>();string? cursor=null;
        do{var page=await store.ListAsync(null,null,null,2,cursor);received.AddRange(page.Items.Select(x=>x.Id));cursor=page.NextCursor;}while(cursor is not null);
        Assert.Equal(7,received.Count);Assert.Equal(7,received.Distinct().Count());
        var history=await store.ListAsync("deleted-demo","restart","succeeded");Assert.Equal(4,history.Items.Count);
        var json=System.Text.Json.JsonSerializer.Serialize(history);
        Assert.DoesNotContain("sensitive",json);Assert.DoesNotContain("RequestJson",json);Assert.DoesNotContain("ResultJson",json);
        Assert.Equal(3,(await store.ListAsync(null,null,"active")).Items.Count);
        var latest=await store.GetLatestByEnvironmentAsync(default);Assert.Equal(2,latest.Count);Assert.Equal(history.Items[0].Id,latest["deleted-demo"].Id);
        var first=await store.ListAsync(null,null,null,1);
        await Assert.ThrowsAsync<ApiProblemException>(()=>store.ListAsync("other",null,null,1,first.NextCursor));
    }

    [Theory]
    [InlineData("bad_name",null,null,25,null)]
    [InlineData(null,"drop table",null,25,null)]
    [InlineData(null,null,"unknown",25,null)]
    [InlineData(null,null,null,0,null)]
    [InlineData(null,null,null,101,null)]
    [InlineData(null,null,null,25,"not-a-cursor")]
    public async Task History_RejectsInvalidFilters(string? environment,string? kind,string? state,int limit,string? cursor)
    {
        Directory.CreateDirectory(_root);var store=CreateStore();await store.InitializeAsync();
        await Assert.ThrowsAsync<ApiProblemException>(()=>store.ListAsync(environment,kind,state,limit,cursor));
    }

    private OperationStore CreateStore()
    {
        var options = Options.Create(new PilotEnvOptions { RepositoryRoot = _root, DatabaseFile = "state.db" });
        return new OperationStore(options, new TestEnvironment { ContentRootPath = _root });
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    private sealed class TestEnvironment : IWebHostEnvironment
    {
        public string ApplicationName { get; set; } = "tests";
        public IFileProvider WebRootFileProvider { get; set; } = new NullFileProvider();
        public string WebRootPath { get; set; } = "";
        public string EnvironmentName { get; set; } = "Test";
        public string ContentRootPath { get; set; } = "";
        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    }
}

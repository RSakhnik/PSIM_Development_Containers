using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Options;
using Microsoft.Extensions.Logging.Abstractions;
using System.Security.Cryptography;
using PilotEnv.Api;
using Xunit;

namespace PilotEnv.Api.Tests;

public sealed class PlatformUpdateTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "pilot-platform-" + Guid.NewGuid().ToString("N"));
    private readonly PlatformDeployment _deployment;
    public PlatformUpdateTests()
    {
        Directory.CreateDirectory(Path.Combine(_root, ".pilot-runtime"));
        _deployment = new PlatformDeployment(Options.Create(new PilotEnvOptions { RepositoryRoot=_root }), new TestEnvironment());
    }

    private void State(string buildHash) => File.WriteAllText(_deployment.StatePath, JsonSerializer.Serialize(new DeploymentState {
        Components = new() { ["web-ui"] = new(buildHash), ["environment-engine"] = new("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") }
    }, JsonDefaults.Options));
    private void Ui(string buildHash)
    {
        var path=Path.Combine(_root,".pilot-runtime","builds","web-ui",buildHash);
        Directory.CreateDirectory(path);
        File.WriteAllText(Path.Combine(path,"index.html"), "<script src='__ASSETS__/app.js'></script>");
        File.WriteAllText(Path.Combine(path,"app.js"), $"console.log('{buildHash}');");
    }
    private async Task<(int Status, string Body, string Cache)> Serve(string path)
    {
        var context=new DefaultHttpContext();
        context.Request.Method="GET"; context.Request.Path=path;
        context.Response.Body=new MemoryStream();
        await new UiEndpoint(_deployment).InvokeAsync(context);
        return (context.Response.StatusCode,Encoding.UTF8.GetString(((MemoryStream)context.Response.Body).ToArray()),context.Response.Headers.CacheControl.ToString());
    }

    [Fact]
    public async Task UiSwitch_ChangesHtmlAndKeepsOldBuildAssets()
    {
        Ui("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"); Ui("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"); State("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        var first=await Serve("/"); Assert.Contains("/ui-assets/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/app.js",first.Body); Assert.Equal("no-store",first.Cache);
        State("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
        var second=await Serve("/"); Assert.Contains("/ui-assets/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/app.js",second.Body);
        var old=await Serve("/ui-assets/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/app.js"); Assert.Equal(200,old.Status); Assert.Contains("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",old.Body); Assert.Contains("immutable",old.Cache);
        Assert.Equal(404,(await Serve("/api/v1/unknown")).Status);
        Assert.Equal(404,(await Serve("/ui-assets/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/secrets.json")).Status);
    }

    [Fact]
    public void Drain_PreservesInFlightLeaseAndPreventsNewOperationsUntilMaintenanceEnds()
    {
        var activity=new PlatformActivity(_deployment);
        var running=activity.TryEnter(); Assert.NotNull(running); Assert.Equal(1,activity.Active);
        File.WriteAllText(_deployment.MaintenancePath,"{\"component\":\"environment-engine\",\"phase\":\"draining\"}");
        Assert.Null(activity.TryEnter()); Assert.Equal(1,activity.Active);
        running.Dispose(); running.Dispose(); Assert.Equal(0,activity.Active);
        File.Delete(_deployment.MaintenancePath);
        using var next=activity.TryEnter(); Assert.NotNull(next); Assert.Equal(1,activity.Active);
    }

    [Theory]
    [InlineData("../outside")]
    [InlineData("C:\\outside")]
    [InlineData("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/../../outside")]
    public void ComponentPath_RejectsUntrustedBuild(string buildHash) =>
        Assert.Throws<InvalidDataException>(() => _deployment.ComponentPath("web-ui",buildHash));

    [Fact]
    public async Task PowerShellAdapter_PinsEngineForOperationWhileActiveBuildChanges()
    {
        if (!OperatingSystem.IsWindows()) return;
        var powershell=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"System32","WindowsPowerShell","v1.0","powershell.exe");
        var protectedValue=Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes("test-only"),null,DataProtectionScope.LocalMachine));
        File.WriteAllText(Path.Combine(_root,"secret.json"),JsonSerializer.Serialize(new {tokenHash="unused",adminPasswordProtected=protectedValue,bimPasswordProtected=protectedValue}));
        var options=Options.Create(new PilotEnvOptions {RepositoryRoot=_root,SecretFile="secret.json",PowerShellExecutable=powershell});
        foreach(var buildHash in new[]{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"})
        {
            var scripts=Path.Combine(_root,".pilot-runtime","builds","environment-engine",buildHash,"scripts"); Directory.CreateDirectory(scripts);
            File.WriteAllText(Path.Combine(scripts,"pilot-env.ps1"),"param($Action,[switch]$Json,[switch]$Machine)\n@{protocolVersion=1;success=$true;data=@{buildHash='"+buildHash+"'};error=$null}|ConvertTo-Json -Compress");
        }
        void Select(string buildHash)=>File.WriteAllText(_deployment.StatePath,JsonSerializer.Serialize(new DeploymentState {Components=new(){["environment-engine"]=new(buildHash)}},JsonDefaults.Options));
        Select("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        var environment=new TestEnvironment();
        var engine=new PowerShellEngine(options,environment,new ProtectedSecretStore(options,environment),NullLogger<PowerShellEngine>.Instance,_deployment);
        using(engine.PinBuild())
        {
            Select("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
            using var old=await engine.GetEngineInfoAsync(default); Assert.Equal("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",old.RootElement.GetProperty("buildHash").GetString());
        }
        using var next=await engine.GetEngineInfoAsync(default); Assert.Equal("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",next.RootElement.GetProperty("buildHash").GetString());
    }

    [Fact]
    public async Task Coordinator_DrainsRunningWorkAndKeepsNewWorkQueuedUntilEngineSwitch()
    {
        State("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        foreach(var name in new[]{"first","second"}){
            var directory=Path.Combine(_root,".pilot-instances",name);Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory,"instance.json"),"{\"mode\":\"bim-dev\",\"schemaVersion\":4}");
        }
        var options=Options.Create(new PilotEnvOptions {RepositoryRoot=_root,DatabaseFile="queue.db"});
        var environment=new TestEnvironment();
        var store=new OperationStore(options,environment);await store.InitializeAsync();
        var engine=new BlockingEngine(_deployment);
        var environments=new EnvironmentService(options,environment,engine,store);
        var capacity=new CapacityService(engine,store,environments,options);
        var activity=new PlatformActivity(_deployment);
        using var coordinator=new OperationCoordinator(store,capacity,environments,engine,options,NullLogger<OperationCoordinator>.Instance,activity);
        await coordinator.StartAsync(default);
        try{
            var first=await coordinator.QueueRestartAsync("first","pilot-web-server",false,null,default);
            await engine.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
            File.WriteAllText(_deployment.MaintenancePath,"{\"component\":\"environment-engine\"}");
            var second=await coordinator.QueueRestartAsync("second","pilot-web-server",false,null,default);
            engine.Release.TrySetResult();
            for(var i=0;i<100 && activity.Active!=0;i++)await Task.Delay(20);
            Assert.Equal(0,activity.Active);Assert.Equal("queued",(await store.GetAsync(second.Id,default))!.State);
            File.WriteAllText(_deployment.StatePath,JsonSerializer.Serialize(new DeploymentState {Components=new(){["environment-engine"]=new("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")}},JsonDefaults.Options));
            File.Delete(_deployment.MaintenancePath);
            await engine.SecondFinished.Task.WaitAsync(TimeSpan.FromSeconds(5));
            for(var i=0;i<100 && (await store.GetAsync(second.Id,default))!.State!="succeeded";i++)await Task.Delay(20);
            Assert.Equal("succeeded",(await store.GetAsync(first.Id,default))!.State);
            Assert.Equal("succeeded",(await store.GetAsync(second.Id,default))!.State);
            Assert.Equal(new[]{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},engine.Builds.ToArray());
        }finally{engine.Release.TrySetResult();if(File.Exists(_deployment.MaintenancePath))File.Delete(_deployment.MaintenancePath);await coordinator.StopAsync(default);}
    }

    private sealed class BlockingEngine(PlatformDeployment deployment) : IEnvironmentEngine
    {
        private readonly AsyncLocal<string?> _buildHash=new();
        public readonly TaskCompletionSource Started=new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource Release=new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource SecondFinished=new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly System.Collections.Concurrent.ConcurrentQueue<string> Builds=new();
        public IDisposable PinBuild(){_buildHash.Value=deployment.BuildHash("environment-engine");return new Pin();}
        private sealed class Pin : IDisposable{public void Dispose(){}}
        public async Task<EngineResult> RestartComponentAsync(string name,string component,bool cascade,CancellationToken ct){
            Builds.Enqueue(_buildHash.Value!);
            if(name=="first"){Started.TrySetResult();await Release.Task.WaitAsync(ct);}else SecondFinished.TrySetResult();
            return new(0,"ok","");
        }
        public Task<JsonDocument> GetStatusAsync(string name,CancellationToken ct)=>Task.FromResult(JsonDocument.Parse(JsonSerializer.Serialize(new {name,mode="bim-dev",state="running"})));
        public Task<JsonDocument> GetCapacityAsync(CancellationToken ct)=>throw new NotSupportedException();
        public Task<JsonDocument> GetEngineInfoAsync(CancellationToken ct)=>throw new NotSupportedException();
        public Task<EngineResult> CreateAsync(string name,PublicPortPair ports,CancellationToken ct)=>throw new NotSupportedException();
        public Task<EngineResult> StartAsync(string name,CancellationToken ct)=>throw new NotSupportedException();
        public Task<EngineResult> StopAsync(string name,CancellationToken ct)=>throw new NotSupportedException();
        public Task<EngineResult> DeleteAsync(string name,CancellationToken ct)=>throw new NotSupportedException();
        public Task<EngineResult> RecreateAsync(string name,CancellationToken ct)=>throw new NotSupportedException();
        public Task<EngineResult> RefreshReleaseAsync(CancellationToken ct)=>throw new NotSupportedException();
        public Task<string> GetLogsAsync(string name,string component,int tail,CancellationToken ct)=>throw new NotSupportedException();
    }

    public void Dispose() => Directory.Delete(_root,true);
    private sealed class TestEnvironment : IWebHostEnvironment
    {
        public string ApplicationName {get;set;}="tests";
        public IFileProvider WebRootFileProvider {get;set;}=new NullFileProvider();
        public string WebRootPath {get;set;}="";
        public string EnvironmentName {get;set;}="Test";
        public string ContentRootPath {get;set;}="";
        public IFileProvider ContentRootFileProvider {get;set;}=new NullFileProvider();
    }
}

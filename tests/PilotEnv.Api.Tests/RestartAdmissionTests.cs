using System.Text.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using PilotEnv.Api;
using Xunit;
namespace PilotEnv.Api.Tests;
public sealed class RestartAdmissionTests
{
 [Theory]
 [InlineData("running",true)]
 [InlineData("degraded",true)]
 [InlineData("stopped",false)]
 [InlineData("starting",false)]
 public async Task Restart_RecoversDegradedButDoesNotStartStoppedEnvironment(string state,bool allowed)
 {
  var root=Path.Combine(Path.GetTempPath(),"pilot-restart-"+Guid.NewGuid().ToString("N"));
  Directory.CreateDirectory(Path.Combine(root,".pilot-instances","demo"));
  await File.WriteAllTextAsync(Path.Combine(root,".pilot-instances","demo","instance.json"),"{}");
  try {
   var options=Options.Create(new PilotEnvOptions {RepositoryRoot=root,DatabaseFile="state.db"});
   var host=new Host {ContentRootPath=root};var engine=new Engine(state);
   var store=new OperationStore(options,host);await store.InitializeAsync();
   var environments=new EnvironmentService(options,host,engine,store);
   using var coordinator=new OperationCoordinator(store,new CapacityService(engine,store,environments,options),environments,engine,options,NullLogger<OperationCoordinator>.Instance,new PlatformActivity(new PlatformDeployment(options,host)));
   if(allowed){var operation=await coordinator.QueueRestartAsync("demo","pilot-bim-server",false,"recover",default);Assert.Equal("queued",operation.State);Assert.Equal("pilot-bim-server",operation.Component);var restored=await environments.GetAsync("demo",default);Assert.Equal(operation.Id,restored!.LastOperation!.Id);Assert.Equal(operation.Id,restored.ActiveOperationId);}
   else {var error=await Assert.ThrowsAsync<ApiProblemException>(()=>coordinator.QueueRestartAsync("demo","pilot-bim-server",false,"recover",default));Assert.Contains("running or degraded",error.Message);Assert.Empty(await store.GetQueuedIdsAsync(default));}
  } finally {Directory.Delete(root,true);}
 }
 private sealed class Host:IWebHostEnvironment {
  public string ApplicationName{get;set;}="tests";public string WebRootPath{get;set;}="";public IFileProvider WebRootFileProvider{get;set;}=new NullFileProvider();public string EnvironmentName{get;set;}="Test";public string ContentRootPath{get;set;}="";public IFileProvider ContentRootFileProvider{get;set;}=new NullFileProvider();
 }
 private sealed class Engine(string state):IEnvironmentEngine {
  public Task<JsonDocument> GetStatusAsync(string name,CancellationToken ct)=>Task.FromResult(JsonDocument.Parse(JsonSerializer.Serialize(new{name,mode="bim-dev",state})));
  public IDisposable PinBuild()=>throw new NotSupportedException();
  public Task<EngineResult> CreateAsync(string name,PublicPortPair ports,CancellationToken ct)=>throw new NotSupportedException();
  public Task<EngineResult> StartAsync(string name,CancellationToken ct)=>throw new NotSupportedException();
  public Task<EngineResult> StopAsync(string name,CancellationToken ct)=>throw new NotSupportedException();
  public Task<EngineResult> DeleteAsync(string name,CancellationToken ct)=>throw new NotSupportedException();
  public Task<EngineResult> RestartComponentAsync(string name,string component,bool cascade,CancellationToken ct)=>throw new NotSupportedException();
  public Task<EngineResult> RecreateAsync(string name,CancellationToken ct)=>throw new NotSupportedException();
  public Task<EngineResult> RefreshReleaseAsync(CancellationToken ct)=>throw new NotSupportedException();
  public Task<JsonDocument> GetCapacityAsync(CancellationToken ct)=>throw new NotSupportedException();
  public Task<JsonDocument> GetEngineInfoAsync(CancellationToken ct)=>throw new NotSupportedException();
  public Task<string> GetLogsAsync(string name,string component,int tail,CancellationToken ct)=>throw new NotSupportedException();
 }
}
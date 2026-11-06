using System.IO.Compression;
using System.Reflection;
using System.Runtime.Loader;
using System.Text.Json;
using Pilot.WebServer.SDK;
_ = typeof(ICommandHost).Assembly;
_ = typeof(System.ComponentModel.Composition.ExportAttribute).Assembly;
var folder=Path.GetFullPath(args[0]);
var temp=Path.Combine(Path.GetTempPath(),"isolation-probe-contract-"+Guid.NewGuid().ToString("N"));
var launches=new HashSet<string>();
try {
 foreach(var marker in new[]{"A1","B1","A2"}) {
  var stage=Path.Combine(temp,marker);ZipFile.ExtractToDirectory(Path.Combine(folder,$"IsolationProbe-{marker}.zip"),stage);
  using var manifest=JsonDocument.Parse(File.ReadAllText(Path.Combine(stage,"frontend","extensions.config.json")));
  if(manifest.RootElement.GetProperty("extension").GetProperty("name").GetString()!="pilot_environment_isolation_probe")throw new Exception("Extension identity differs");
  var entry=manifest.RootElement.GetProperty("extension").GetProperty("entry").GetString()!;
  var chunks=Directory.GetFiles(Path.Combine(stage,"frontend"),"*.js").Where(x=>Path.GetFileName(x)!=entry);
  if(!chunks.Any(x=>File.ReadAllText(x).Contains(marker)))throw new Exception("Frontend marker missing");
  var context=new AssemblyLoadContext("probe-"+marker,true);
  var assembly=context.LoadFromStream(new MemoryStream(File.ReadAllBytes(Path.Combine(stage,"backend","IsolationProbe.webext.dll"))));
  var type=assembly.GetType("PilotEnvironment.IsolationProbe.IsolationProbeBackend")!;
  if(!typeof(ICommandHost).IsAssignableFrom(type))throw new Exception("Not a Pilot backend command host");
  var instance=Activator.CreateInstance(type);var method=type.GetMethod("IsolationProbeStatus")!;
  var nonce=Guid.NewGuid().ToString();
  using var first=JsonDocument.Parse((string)method.Invoke(instance,new object[]{nonce})!);
  using var second=JsonDocument.Parse((string)method.Invoke(instance,new object[]{"another-nonce"})!);
  if(first.RootElement.GetProperty("backendVersion").GetString()!=marker || first.RootElement.GetProperty("nonce").GetString()!=nonce)throw new Exception("Backend marker/nonce mismatch");
  var launch=first.RootElement.GetProperty("backendLaunchId").GetString()!;
  if(second.RootElement.GetProperty("backendLaunchId").GetString()!=launch || !launches.Add(launch))throw new Exception("Invalid backend launch identity");
  Console.WriteLine($"PASS {marker}: same extension identity, distinct compiled backend, frontend marker, fresh nonce, stable loaded backend launch ID");
  context.Unload();
 }
} finally {Directory.Delete(temp,true);}

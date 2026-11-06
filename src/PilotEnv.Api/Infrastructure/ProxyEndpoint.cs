using System.Net;
using Yarp.ReverseProxy.Forwarder;

namespace PilotEnv.Api;

public sealed class ProxyEndpoint : IDisposable
{
    private readonly EnvironmentService _environments;
    private readonly IHttpForwarder _forwarder;
    private readonly HttpMessageInvoker _httpClient;
    private readonly ForwarderRequestConfig _requestConfig = new() { ActivityTimeout = TimeSpan.FromMinutes(10) };
    private readonly HttpTransformer _transformer = new PilotHttpTransformer();

    public ProxyEndpoint(EnvironmentService environments, IHttpForwarder forwarder)
    {
        _environments = environments;
        _forwarder = forwarder;
        _httpClient = new HttpMessageInvoker(new SocketsHttpHandler
        {
            UseProxy = false,
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.None,
            UseCookies = false,
            EnableMultipleHttp2Connections = true,
            ConnectTimeout = TimeSpan.FromSeconds(10)
        });
    }

    public async Task InvokeAsync(HttpContext context)
    {
        var publicPort = context.Request.Host.Port;
        if (publicPort is null || !_environments.TryResolveProxy(publicPort.Value, out var name, out var destination))
        {
            context.Response.StatusCode = StatusCodes.Status404NotFound;
            await context.Response.WriteAsJsonAsync(new { error = "environment_route_not_found" }, context.RequestAborted);
            return;
        }

        var error = await _forwarder.SendAsync(context, destination!, _httpClient, _requestConfig, _transformer);
        if (error == ForwarderError.None) return;
        var feature = context.GetForwarderErrorFeature();
        if (!context.Response.HasStarted)
        {
            context.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
            await context.Response.WriteAsJsonAsync(new
            {
                error = "environment_unavailable",
                environment = name,
                message = "The environment is stopped, starting, or unhealthy.",
                detail = feature?.Exception?.Message
            }, context.RequestAborted);
        }
    }

    public void Dispose() => _httpClient.Dispose();

}

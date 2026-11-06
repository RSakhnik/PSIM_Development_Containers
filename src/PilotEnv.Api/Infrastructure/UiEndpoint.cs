using Microsoft.AspNetCore.StaticFiles;

namespace PilotEnv.Api;

public sealed class UiEndpoint(PlatformDeployment deployment)
{
    private static readonly FileExtensionContentTypeProvider Types = new();
    public async Task InvokeAsync(HttpContext context)
    {
        if (!HttpMethods.IsGet(context.Request.Method) && !HttpMethods.IsHead(context.Request.Method))
        { context.Response.StatusCode = 405; return; }
        var parts = (context.Request.Path.Value ?? "/").Split('/', StringSplitOptions.RemoveEmptyEntries);
        string path;
        if (parts.Length == 3 && parts[0] == "ui-assets" && parts[2] is "app.js" or "api-client.js" or "labels.js" or "operation-state.js" or "cards.js" or "journal.js" or "styles.css" or "help.pdf")
        {
            var root = deployment.ComponentPath("web-ui", parts[1]);
            if (!Directory.Exists(root) && !File.Exists(deployment.StatePath)) root = deployment.ComponentPath("web-ui");
            path = Path.Combine(root, parts[2]);
            context.Response.Headers.CacheControl = parts[1] == "workspace" ? "no-store" : "public,max-age=31536000,immutable";
        }
        else if (parts.Length == 0 || (parts.Length == 1 && parts[0] == "index.html"))
        {
            var buildHash = deployment.BuildHash("web-ui");
            var directory = deployment.ComponentPath("web-ui", buildHash);
            path = Path.Combine(directory, "index.html");
            context.Response.Headers.CacheControl = "no-store";
            if (!File.Exists(path)) { context.Response.StatusCode = 503; return; }
            var html = await File.ReadAllTextAsync(path, context.RequestAborted);
            context.Response.ContentType = "text/html; charset=utf-8";
            await context.Response.WriteAsync(html.Replace("__ASSETS__", "/ui-assets/" + buildHash), context.RequestAborted);
            return;
        }
        else { context.Response.StatusCode = 404; return; }
        if (!File.Exists(path)) { context.Response.StatusCode = 404; return; }
        context.Response.ContentType = Types.TryGetContentType(path, out var type) ? type : "application/octet-stream";
        await context.Response.SendFileAsync(path, context.RequestAborted);
    }
}

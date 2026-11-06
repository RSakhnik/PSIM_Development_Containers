using System.Net;
using System.Net.Http.Headers;
using System.Text;
using Microsoft.AspNetCore.Http;
using PilotEnv.Api;
using Xunit;

namespace PilotEnv.Api.Tests;

public sealed class ManifestProxyTests
{
    private static readonly Uri Origin = new("https://360pilot.ru:18000/documents/example");
    [Theory]
    [InlineData("<link rel=\"manifest\" href=\"manifest.json\">", true)]
    [InlineData("<LINK HREF='/manifest.json' REL='manifest' crossorigin=anonymous/>", true)]
    [InlineData("<link rel='alternate manifest' href='/manifest.json' crossorigin>", true)]
    [InlineData("<link rel='manifest' href='https://360pilot.ru:18000/manifest.json'>", true)]
    [InlineData("<link rel='manifest' href='https://360pilot.ru:18001/manifest.json'>", false)]
    [InlineData("<link rel='manifest' href='https://external.example/manifest.json'>", false)]
    [InlineData("<link rel='manifest' href='http://360pilot.ru:18000/manifest.json'>", false)]
    [InlineData("<link rel='stylesheet' href='/manifest.json'>", false)]
    [InlineData("<!-- <link rel='manifest' href='/manifest.json'> -->", false)]
    [InlineData("<script>const text=\"<link rel='manifest' href='/manifest.json'>\";</script>", false)]
    [InlineData("<link data-rel='manifest' href='/manifest.json'>", false)]
    public void OnlySameOriginManifestGetsCredentials(string html, bool change)
    {
        var result = PilotHttpTransformer.RewriteManifestLinks(html, Origin);
        if(change) Assert.Contains("crossorigin=\"use-credentials\"",result);
        else Assert.Equal(html,result);
        Assert.Equal(result,PilotHttpTransformer.RewriteManifestLinks(result,Origin));
    }

    [Fact]
    public void ExternalBaseDoesNotExpandCredentials()
    {
        const string html="<base href='https://external.example/'><link rel='manifest' href='manifest.json'>";
        Assert.Equal(html,PilotHttpTransformer.RewriteManifestLinks(html,Origin));
    }
    [Fact]
    public void ReplacesExistingCredentialModeOnceAndPreservesOtherAttributes()
    {
        var result=PilotHttpTransformer.RewriteManifestLinks("<link id='pwa' rel='manifest' href='/manifest.json' crossorigin='anonymous'>",Origin);
        Assert.Contains("id='pwa'",result);Assert.Contains("href='/manifest.json'",result);
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(result,"crossorigin"));
    }

    [Fact]
    public async Task DocumentRequestDisablesCompressionAndValidatorsWithoutChangingHost()
    {
        var context=new DefaultHttpContext();context.Request.Method="GET";context.Request.Host=new HostString("360pilot.ru",18000);
        context.Request.Headers.Accept="text/html";context.Request.Headers.AcceptEncoding="gzip, br";context.Request.Headers.IfNoneMatch="old";
        var outgoing=new HttpRequestMessage();
        await new PilotHttpTransformer().TransformRequestAsync(context,outgoing,"http://127.0.0.1:18080",default);
        Assert.Equal("360pilot.ru:18000",outgoing.Headers.Host);
        Assert.Empty(outgoing.Headers.AcceptEncoding);Assert.Empty(outgoing.Headers.IfNoneMatch);
    }

    [Fact]
    public async Task HtmlIsRewrittenAndBodyBytesRemainIntact()
    {
        var tail="<body>Проверка 😀 "+new string('x',20000)+"</body>";
        var html="<html><head><link rel='manifest' href='/manifest.json'></head>"+tail;
        using var response=new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(html,Encoding.UTF8,"text/html")};
        response.Headers.ETag=new EntityTagHeaderValue("\"old\"");response.Headers.TryAddWithoutValidation("Content-Security-Policy","default-src 'self'");
        var context=Context();
        Assert.False(await new PilotHttpTransformer().TransformResponseAsync(context,response,default));
        var actual=Encoding.UTF8.GetString(((MemoryStream)context.Response.Body).ToArray());
        Assert.Contains("crossorigin=\"use-credentials\"",actual);Assert.EndsWith(tail,actual);
        Assert.Null(context.Response.ContentLength);Assert.False(context.Response.Headers.ContainsKey("ETag"));
        Assert.Equal("no-store",context.Response.Headers.CacheControl);Assert.Equal("default-src 'self'",context.Response.Headers.ContentSecurityPolicy);
        Assert.False(context.Response.Headers.ContainsKey("Access-Control-Allow-Origin"));
    }

    [Fact]
    public async Task HeadBoundariesInsideScriptOrAttributesAreNotRewritten()
    {
        var script="<script>const fake=\"</head><link rel='manifest' href='/fake.json'>\";"+new string('x',9000)+"</script>";
        var html="<head><meta data-test='</head>'>"+script+"<link rel='manifest' href='/manifest.json'></head >конец";
        using var response=new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(html,Encoding.UTF8,"text/html")};
        var context=Context();Assert.False(await new PilotHttpTransformer().TransformResponseAsync(context,response,default));
        var actual=Encoding.UTF8.GetString(((MemoryStream)context.Response.Body).ToArray());
        Assert.Contains(script,actual);Assert.Contains("href='/manifest.json' crossorigin=\"use-credentials\"",actual);Assert.EndsWith("конец",actual);
    }

    [Fact]
    public async Task OversizedHeadPassesThroughUnchanged()
    {
        var html="<head>"+new string('x',PilotHttpTransformer.MaximumHeadBytes)+"<link rel='manifest' href='/manifest.json'></head><body>данные</body>";
        using var response=new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(html,Encoding.UTF8,"text/html")};
        var context=Context();Assert.False(await new PilotHttpTransformer().TransformResponseAsync(context,response,default));
        Assert.Equal(html,Encoding.UTF8.GetString(((MemoryStream)context.Response.Body).ToArray()));
    }

    [Theory]
    [InlineData("GET","application/json",200,null)]
    [InlineData("POST","text/html",200,null)]
    [InlineData("HEAD","text/html",200,null)]
    [InlineData("GET","text/html",206,null)]
    [InlineData("GET","text/html",200,"gzip")]
    public async Task OtherResponsesRetainStreaming(string method,string media,int status,string? encoding)
    {
        using var response=new HttpResponseMessage((HttpStatusCode)status){Content=new StringContent("unchanged",Encoding.UTF8,media)};
        if(encoding is not null)response.Content.Headers.ContentEncoding.Add(encoding);
        var context=Context();context.Request.Method=method;
        Assert.True(await new PilotHttpTransformer().TransformResponseAsync(context,response,default));
        Assert.Equal(0,context.Response.Body.Length);
    }
    private static DefaultHttpContext Context()
    {
        var context=new DefaultHttpContext();context.Request.Method="GET";context.Request.Scheme="https";
        context.Request.Host=new HostString("360pilot.ru",18000);context.Request.Path="/documents/example";
        context.Response.Body=new MemoryStream();return context;
    }
}

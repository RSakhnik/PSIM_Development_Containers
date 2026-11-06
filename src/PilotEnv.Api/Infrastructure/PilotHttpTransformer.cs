using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using Yarp.ReverseProxy.Forwarder;

namespace PilotEnv.Api;

/// <summary>Preserves the external host and enables authenticated same-origin PWA manifests.</summary>
public sealed class PilotHttpTransformer : HttpTransformer
{
    public const int MaximumHeadBytes = 256 * 1024;
    private static readonly Regex HeadTags = new(
        @"<!--.*?-->|<script\b(?:[^>""']|""[^""]*""|'[^']*')*>.*?</script\s*>|<style\b(?:[^>""']|""[^""]*""|'[^']*')*>.*?</style\s*>|(?<tag><(?:link|base)\b(?:[^>""']|""[^""]*""|'[^']*')*>)",
        RegexOptions.IgnoreCase | RegexOptions.Singleline | RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(200));
    private static readonly Regex Attributes = new(
        @"\s+(?<name>[^\s=/>]+)(?:\s*=\s*(?:""(?<double>[^""]*)""|'(?<single>[^']*)'|(?<plain>[^\s>]+)))?",
        RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(200));

    public override async ValueTask TransformRequestAsync(HttpContext context, HttpRequestMessage request,
        string destinationPrefix, CancellationToken cancellationToken)
    {
        await base.TransformRequestAsync(context, request, destinationPrefix, cancellationToken);
        request.Headers.Host = context.Request.Host.Value;
        if (HttpMethods.IsGet(context.Request.Method) && context.Request.Headers.Accept.ToString().Contains("text/html", StringComparison.OrdinalIgnoreCase))
        {
            // Only documents need transformation. Binary assets, uploads and upgrades retain their negotiation.
            request.Headers.AcceptEncoding.Clear();
            request.Headers.IfNoneMatch.Clear();
            request.Headers.IfModifiedSince = null;
        }
    }

    public override async ValueTask<bool> TransformResponseAsync(HttpContext context, HttpResponseMessage? response,
        CancellationToken cancellationToken)
    {
        var forward = await base.TransformResponseAsync(context, response, cancellationToken);
        if (!forward || response is null || response.StatusCode != HttpStatusCode.OK ||
            !HttpMethods.IsGet(context.Request.Method) ||
            !string.Equals(response.Content.Headers.ContentType?.MediaType, "text/html", StringComparison.OrdinalIgnoreCase) ||
            response.Content.Headers.ContentEncoding.Count != 0) return forward;
        var charset = response.Content.Headers.ContentType?.CharSet?.Trim('"');
        if (!string.IsNullOrEmpty(charset) && !charset.Equals("utf-8", StringComparison.OrdinalIgnoreCase) &&
            !charset.Equals("utf8", StringComparison.OrdinalIgnoreCase)) return forward;

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var prefix = new MemoryStream();
        var buffer = new byte[8192];
        var headEnd = -1;
        while (prefix.Length < MaximumHeadBytes)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, MaximumHeadBytes - (int)prefix.Length)), cancellationToken);
            if (read == 0) break;
            prefix.Write(buffer, 0, read);
            headEnd = FindHeadEnd(prefix.GetBuffer().AsSpan(0, (int)prefix.Length));
            if (headEnd >= 0) break;
        }
        var original = prefix.GetBuffer().AsMemory(0, (int)prefix.Length);
        byte[]? rewritten = null;
        if (headEnd >= 0)
        {
            // The ASCII closing tag is a UTF-8 boundary; leave any partial character in the tail untouched.
            var head = Encoding.UTF8.GetString(original.Span[..headEnd]);
            var origin = new Uri($"{context.Request.Scheme}://{context.Request.Host}{context.Request.PathBase}{context.Request.Path}");
            var changed = RewriteManifestLinks(head, origin);
            if (!string.Equals(head, changed, StringComparison.Ordinal)) rewritten = Encoding.UTF8.GetBytes(changed);
        }
        if (rewritten is not null)
        {
            context.Response.ContentLength = null;
            context.Response.Headers.Remove("ETag");
            context.Response.Headers.Remove("Last-Modified");
            foreach (var header in new[] { "Content-MD5", "Digest", "Content-Digest", "Repr-Digest" }) context.Response.Headers.Remove(header);
            context.Response.Headers.CacheControl = "no-store";
            await context.Response.Body.WriteAsync(rewritten, cancellationToken);
            await context.Response.Body.WriteAsync(original[headEnd..], cancellationToken);
        }
        else await context.Response.Body.WriteAsync(original, cancellationToken);
        await stream.CopyToAsync(context.Response.Body, cancellationToken);
        return false;
    }

    private static int FindHeadEnd(ReadOnlySpan<byte> bytes)
    {
        // Ignore head-looking text in comments, attributes and raw-text elements.
        for (var i = 0; i < bytes.Length;)
        {
            if (bytes[i] != (byte)'<') { i++; continue; }
            if (At(bytes, i, "<!--"u8))
            {
                var end = Find(bytes, i + 4, "-->"u8);
                if (end < 0) return -1;
                i = end + 3; continue;
            }
            var tagEnd = TagEnd(bytes, i);
            if (tagEnd < 0) return -1;
            if (NamedTag(bytes, i, "</head"u8)) return tagEnd + 1;
            var raw = NamedTag(bytes, i, "<script"u8) ? "</script"u8 : NamedTag(bytes, i, "<style"u8) ? "</style"u8 : ReadOnlySpan<byte>.Empty;
            if (!raw.IsEmpty)
            {
                var close = tagEnd + 1;
                do { close = Find(bytes, close, raw); if (close < 0) return -1; if (NamedTag(bytes, close, raw)) break; close++; } while (true);
                tagEnd = TagEnd(bytes, close);
                if (tagEnd < 0) return -1;
            }
            i = tagEnd + 1;
        }
        return -1;
    }
    private static bool NamedTag(ReadOnlySpan<byte> bytes, int index, ReadOnlySpan<byte> tag)
    {
        if (!At(bytes, index, tag) || index + tag.Length >= bytes.Length) return false;
        return bytes[index + tag.Length] is (byte)'>' or (byte)'/' or (byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n';
    }
    private static int TagEnd(ReadOnlySpan<byte> bytes, int start)
    {
        byte quote = 0;
        for (var i = start; i < bytes.Length; i++)
        {
            var value = bytes[i];
            if (quote != 0) { if (value == quote) quote = 0; }
            else if (value is (byte)'\'' or (byte)'"') quote = value;
            else if (value == (byte)'>') return i;
        }
        return -1;
    }
    private static bool At(ReadOnlySpan<byte> bytes, int start, ReadOnlySpan<byte> value)
    {
        if (start + value.Length > bytes.Length) return false;
        for (var i = 0; i < value.Length; i++)
        {
            var actual = bytes[start + i];
            if (actual is >= (byte)'A' and <= (byte)'Z') actual += 32;
            if (actual != value[i]) return false;
        }
        return true;
    }
    private static int Find(ReadOnlySpan<byte> bytes, int start, ReadOnlySpan<byte> value)
    {
        for (var i = start; i <= bytes.Length - value.Length; i++) if (At(bytes, i, value)) return i;
        return -1;
    }

    public static string RewriteManifestLinks(string head, Uri documentUri)
    {
        try
        {
            var tags = HeadTags.Matches(head);
            var documentBase = documentUri;
            foreach (Match match in tags)
            {
                var tag = match.Groups["tag"].Value;
                if (!tag.StartsWith("<base", StringComparison.OrdinalIgnoreCase)) continue;
                var href = AttributeValue(tag, "href");
                if (href is not null && Uri.TryCreate(documentUri, href, out var resolved)) { documentBase = resolved; break; }
            }
            return HeadTags.Replace(head, match =>
            {
                var tag = match.Groups["tag"].Value;
                if (!tag.StartsWith("<link", StringComparison.OrdinalIgnoreCase)) return match.Value;
                var rel = AttributeValue(tag, "rel");
                var href = AttributeValue(tag, "href");
                if (rel is null || !rel.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Contains("manifest", StringComparer.OrdinalIgnoreCase) ||
                    href is null || !Uri.TryCreate(documentBase, href, out var target) ||
                    target.Scheme != documentUri.Scheme || target.IdnHost != documentUri.IdnHost || target.Port != documentUri.Port) return match.Value;
                if (string.Equals(AttributeValue(tag, "crossorigin"), "use-credentials", StringComparison.OrdinalIgnoreCase)) return tag;
                var clean = Attributes.Replace(tag, attribute => attribute.Groups["name"].Value.Equals("crossorigin", StringComparison.OrdinalIgnoreCase) ? "" : attribute.Value);
                var insert = clean.EndsWith("/>", StringComparison.Ordinal) ? clean.Length - 2 : clean.Length - 1;
                return clean.Insert(insert, " crossorigin=\"use-credentials\"");
            });
        }
        catch (RegexMatchTimeoutException) { return head; }
    }

    private static string? AttributeValue(string tag, string name)
    {
        foreach (Match attribute in Attributes.Matches(tag))
        {
            if (!attribute.Groups["name"].Value.Equals(name, StringComparison.OrdinalIgnoreCase)) continue;
            foreach (var value in new[] { "double", "single", "plain" })
                if (attribute.Groups[value].Success) return WebUtility.HtmlDecode(attribute.Groups[value].Value);
            return "";
        }
        return null;
    }
}

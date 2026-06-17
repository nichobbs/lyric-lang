// Bridge for Unix socket support in Std.Http.
// This is infrastructure code to handle async callback setup that's complex to express
// through Lyric's FFI. Once Lyric FFI gains better callback support, this can migrate
// to pure Lyric in lyric-stdlib/std/_kernel/http_host.l.

using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace Lyric.Stdlib.HttpHost;

/// <summary>
/// Infrastructure helpers for creating HttpClient instances with Unix domain socket support.
/// </summary>
public static class UnixSocketHttpClient
{
    /// <summary>
    /// Creates an HttpClient configured to connect to a Unix domain socket.
    /// </summary>
    /// <param name="socketPath">Path to the Unix domain socket (e.g., /var/run/docker.sock)</param>
    /// <returns>HttpClient configured for Unix socket connections</returns>
    public static HttpClient CreateWithUnixSocket(string socketPath)
    {
        var handler = new SocketsHttpHandler
        {
            ConnectCallback = CreateConnectCallback(socketPath)
        };
        return new HttpClient(handler);
    }

    /// <summary>
    /// Creates an HttpClient configured to connect to a Unix domain socket with redirect following.
    /// </summary>
    /// <param name="socketPath">Path to the Unix domain socket</param>
    /// <param name="maxRedirects">Maximum number of redirects to follow</param>
    /// <returns>HttpClient configured for Unix socket connections with redirects</returns>
    public static HttpClient CreateWithUnixSocketAndRedirects(string socketPath, int maxRedirects)
    {
        var handler = new SocketsHttpHandler
        {
            ConnectCallback = CreateConnectCallback(socketPath),
            AllowAutoRedirect = true,
            MaxAutomaticRedirections = maxRedirects
        };
        return new HttpClient(handler);
    }

    /// <summary>
    /// Creates an HttpClient configured to connect to a Unix domain socket without redirects.
    /// </summary>
    /// <param name="socketPath">Path to the Unix domain socket</param>
    /// <returns>HttpClient configured for Unix socket connections without redirects</returns>
    public static HttpClient CreateWithUnixSocketNoRedirects(string socketPath)
    {
        var handler = new SocketsHttpHandler
        {
            ConnectCallback = CreateConnectCallback(socketPath),
            AllowAutoRedirect = false
        };
        return new HttpClient(handler);
    }

    /// <summary>
    /// Creates a ConnectCallback that routes connections through a Unix domain socket.
    /// The callback ignores the standard DnsEndPoint and connects to the Unix socket instead.
    /// </summary>
    private static Func<SocketsHttpConnectionContext, ValueTask<Stream>> CreateConnectCallback(string socketPath)
    {
        return async context =>
        {
            var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            try
            {
                var endpoint = new UnixDomainSocketEndPoint(socketPath);
                await socket.ConnectAsync(endpoint, context.CancellationToken).ConfigureAwait(false);
                return new NetworkStream(socket, ownsSocket: true);
            }
            catch
            {
                socket.Dispose();
                throw;
            }
        };
    }
}

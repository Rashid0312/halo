using HaloWebsite.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Caching.Memory;

namespace HaloWebsite.Controllers;

/// <summary>
/// GET /download — redirects the browser to a short-lived R2 presigned URL.
/// The actual .dmg file is served directly from Cloudflare R2 (zero egress cost).
/// </summary>
[ApiController]
[Route("[controller]")]
public class DownloadController : ControllerBase
{
    private readonly DownloadService _downloads;
    private readonly IMemoryCache _cache;
    private readonly IConfiguration _config;
    private readonly ILogger<DownloadController> _logger;

    public DownloadController(
        DownloadService downloads,
        IMemoryCache cache,
        IConfiguration config,
        ILogger<DownloadController> logger)
    {
        _downloads = downloads;
        _cache = cache;
        _config = config;
        _logger = logger;
    }

    [HttpGet]
    public IActionResult Get()
    {
        // Basic per-IP rate limiting using MemoryCache
        var ip = HttpContext.Connection.RemoteIpAddress?.ToString() ?? "unknown";
        var cacheKey = $"dl:{ip}";
        var limit = int.Parse(_config["Download:RateLimitPerMinute"] ?? "30");

        var count = _cache.GetOrCreate(cacheKey, entry =>
        {
            entry.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(1);
            return 0;
        });

        if (count >= limit)
        {
            _logger.LogWarning("Rate limit hit for IP {IP}", ip);
            return StatusCode(429, "Too many download requests. Please try again in a minute.");
        }

        _cache.Set(cacheKey, count + 1, TimeSpan.FromMinutes(1));

        try
        {
            var url = _downloads.GetPresignedUrl();
            return Redirect(url);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to generate presigned download URL");
            return StatusCode(503, "Download temporarily unavailable. Please try again shortly.");
        }
    }
}

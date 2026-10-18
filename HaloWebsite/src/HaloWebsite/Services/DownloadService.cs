using Amazon.S3;
using Amazon.S3.Model;

namespace HaloWebsite.Services;

/// <summary>
/// Generates short-lived presigned download URLs pointing directly at Cloudflare R2.
/// The file bytes never pass through the web server — zero egress cost.
/// </summary>
public class DownloadService
{
    private readonly IAmazonS3 _s3;
    private readonly IConfiguration _config;
    private readonly ILogger<DownloadService> _logger;

    public DownloadService(IAmazonS3 s3, IConfiguration config, ILogger<DownloadService> logger)
    {
        _s3 = s3;
        _config = config;
        _logger = logger;
    }

    /// <summary>
    /// Returns a presigned URL valid for a short window (default 60 seconds).
    /// The browser is redirected here; the download comes straight from R2.
    /// </summary>
    public string GetPresignedUrl()
    {
        var bucket = _config["R2:Bucket"] ?? "halo-downloads";
        var fileName = _config["R2:FileName"] ?? "HaloAI.dmg";
        var expiry = int.Parse(_config["Download:PresignedUrlExpirySeconds"] ?? "60");

        var request = new GetPreSignedUrlRequest
        {
            BucketName = bucket,
            Key = fileName,
            Expires = DateTime.UtcNow.AddSeconds(expiry),
            Verb = HttpVerb.GET,
        };

        var url = _s3.GetPreSignedURL(request);
        _logger.LogInformation("Generated presigned URL for {File} (expires in {Expiry}s)", fileName, expiry);
        return url;
    }
}

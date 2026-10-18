using Amazon.S3;
using Amazon.S3.Model;
using HaloWebsite.Services;

var builder = WebApplication.CreateBuilder(args);

// Razor Pages
builder.Services.AddRazorPages();

// Controllers (for /download endpoint)
builder.Services.AddControllers();

// Rate limiting (basic — prevents download endpoint abuse)
builder.Services.AddMemoryCache();

// R2 / S3 client — reads R2_* environment variables at runtime
builder.Services.AddSingleton<IAmazonS3>(sp =>
{
    var config = new AmazonS3Config
    {
        ServiceURL = $"https://{builder.Configuration["R2:AccountId"]}.r2.cloudflarestorage.com",
        ForcePathStyle = true,
    };
    return new AmazonS3Client(
        builder.Configuration["R2:AccessKey"],
        builder.Configuration["R2:SecretKey"],
        config);
});

builder.Services.AddSingleton<DownloadService>();

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error");
    app.UseHsts();
}

app.UseStaticFiles();
app.UseRouting();

app.MapRazorPages();
app.MapControllers();

app.Run();

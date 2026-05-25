namespace DotnetOpenshiftDemo;

public class Program
{
    public static void Main(string[] args)
    {
        var builder = WebApplication.CreateBuilder(args);

        builder.WebHost.UseUrls("http://0.0.0.0:8080");

        builder.Services.AddAuthorization();
        builder.Services.AddOpenApi();

        var app = builder.Build();

        if (app.Environment.IsDevelopment())
        {
            app.MapOpenApi();
        }

        app.UseAuthorization();

        object BuildInfo() => new
        {
            name      = Environment.GetEnvironmentVariable("APP_NAME") ?? "dotnet-openshift-demo",
            version   = Environment.GetEnvironmentVariable("APP_VERSION") ?? "dev",
            gitSha    = Environment.GetEnvironmentVariable("APP_GIT_SHA") ?? "unknown",
            imageTag  = Environment.GetEnvironmentVariable("APP_IMAGE_TAG") ?? "unknown",
            buildTime = Environment.GetEnvironmentVariable("APP_BUILD_TIME") ?? "unknown",
            host      = Environment.MachineName
        };

        app.MapGet("/", () => Results.Ok(new
        {
            status = "running",
            message = "Hello from OpenShift BuildConfig pipeline!",
            build = BuildInfo()
        }));

        app.MapGet("/info", () => Results.Ok(BuildInfo()));

        app.MapGet("/health/live", () => Results.Ok(new { status = "live" }));
        app.MapGet("/health/ready", () => Results.Ok(new { status = "ready" }));

        var summaries = new[]
        {
            "Freezing", "Bracing", "Chilly", "Cool", "Mild", "Warm", "Balmy", "Hot", "Sweltering", "Scorching"
        };

        app.MapGet("/weatherforecast", () =>
        {
            return Enumerable.Range(1, 5).Select(index => new WeatherForecast
            {
                Date = DateOnly.FromDateTime(DateTime.Now.AddDays(index)),
                TemperatureC = Random.Shared.Next(-20, 55),
                Summary = summaries[Random.Shared.Next(summaries.Length)]
            }).ToArray();
        })
        .WithName("GetWeatherForecast");

        app.Run();
    }
}

# ── Stage 1: Build ────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Copy project file and restore dependencies first (layer cache friendly)
COPY src/HaloWebsite/HaloWebsite.csproj ./HaloWebsite/
RUN dotnet restore ./HaloWebsite/HaloWebsite.csproj

# Copy the rest of the source and publish
COPY src/HaloWebsite/ ./HaloWebsite/
RUN dotnet publish ./HaloWebsite/HaloWebsite.csproj \
    -c Release \
    -o /app/publish \
    --no-restore

# ── Stage 2: Runtime ──────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app

# Cloud Run injects PORT env var (default 8080)
ENV ASPNETCORE_URLS=http://+:${PORT:-8080}
ENV ASPNETCORE_ENVIRONMENT=Production

COPY --from=build /app/publish .

EXPOSE 8080
ENTRYPOINT ["dotnet", "HaloWebsite.dll"]

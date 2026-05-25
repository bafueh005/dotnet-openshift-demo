FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY *.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app ./

ENV ASPNETCORE_URLS=http://0.0.0.0:8080 \
    DOTNET_RUNNING_IN_CONTAINER=true \
    DOTNET_USE_POLLING_FILE_WATCHER=true

# OpenShift assigns a random non-root UID at runtime. Group 0 with g+rwX
# perms ensures the runtime user can still read the app files.
RUN chgrp -R 0 /app && chmod -R g=u /app
USER 1001

EXPOSE 8080
ENTRYPOINT ["dotnet", "DotnetOpenshiftDemo.dll"]

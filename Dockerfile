FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY *.csproj ./
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /app /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /app ./

ARG GIT_SHA=unknown
ARG BUILD_TIME=unknown
ARG IMAGE_TAG=latest
ENV APP_GIT_SHA=${GIT_SHA} \
    APP_BUILD_TIME=${BUILD_TIME} \
    APP_IMAGE_TAG=${IMAGE_TAG}

LABEL org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.source="https://github.com/bafueh005/dotnet-openshift-demo"

ENV ASPNETCORE_URLS=http://0.0.0.0:8080 \
    DOTNET_RUNNING_IN_CONTAINER=true \
    DOTNET_USE_POLLING_FILE_WATCHER=true

RUN chgrp -R 0 /app && chmod -R g=u /app
USER 1001

EXPOSE 8080
ENTRYPOINT ["dotnet", "DotnetOpenshiftDemo.dll"]

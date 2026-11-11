# The fleet hub for Linux. Build from the repository root, because the hub uses the root package's libraries:
#   docker build -f Hub/Dockerfile -t utm-watch-hub .
FROM swift:6.2-jammy AS build
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev pkg-config && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Package.swift ./
COPY Sources ./Sources
COPY Hub/Package.swift Hub/Package.resolved ./Hub/
COPY Hub/Sources ./Hub/Sources
RUN swift build --package-path Hub -c release --static-swift-stdlib

FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/Hub/.build/release/utmwatch-hub /usr/local/bin/utmwatch-hub
# The database lives on a volume so it survives image updates.
ENV UTMWATCH_HUB_DB=/data/hub.sqlite
VOLUME /data
EXPOSE 8787
ENTRYPOINT ["utmwatch-hub"]
CMD ["serve", "--host", "0.0.0.0", "--port", "8787"]

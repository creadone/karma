FROM crystallang/crystal:1.17.1-alpine AS build

WORKDIR /app
COPY shard.yml shard.lock ./
COPY lib/counter_tree ./lib/counter_tree
COPY src ./src

RUN shards install --production
RUN shards build --release --static

FROM alpine:3.21

RUN addgroup -S karma && adduser -S karma -G karma
WORKDIR /app

COPY --from=build /app/bin/karma /usr/local/bin/karma

RUN mkdir -p /data && chown -R karma:karma /data
USER karma

EXPOSE 8080
VOLUME ["/data"]

ENTRYPOINT ["karma"]
CMD ["--directory=/data", "--restore=true", "--wal=true", "--wal-fsync=true"]

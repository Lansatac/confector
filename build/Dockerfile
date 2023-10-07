FROM alpine:latest AS development
RUN apk update && apk add ldc dub gcc musl-dev openssl-dev zlib-dev bash git
WORKDIR /code
CMD ["tail", "-f", "/dev/null"]
# RUN dub build
# FROM development AS build
# FROM alpine:3.12
# EXPOSE 8080
# COPY --from=build /code/confector /confector
# CMD ["/confector"]
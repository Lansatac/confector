FROM alpine:latest AS development
RUN apk update && apk add dmd ldc dub gcc musl-dev openssl-dev zlib-dev bash git gcompat libc6-compat gdb
RUN addgroup developer
RUN adduser -D -s /bin/bash -g "dev" dev developer
RUN echo 'dev:developerpass' | chpasswd
USER dev
# RUN mkdir -p /home/dev/code
WORKDIR /home/dev
COPY --chown=dev:developer . /home/dev/code
CMD ["tail", "-f", "/dev/null"]
# RUN dub build
# FROM development AS build
# FROM alpine:3.12
# EXPOSE 8080
# COPY --from=build /code/confector /confector
# CMD ["/confector"]
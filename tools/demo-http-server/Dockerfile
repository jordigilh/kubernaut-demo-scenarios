FROM golang:1.25-alpine AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -ldflags="-s -w" -o /demo-http-server .

FROM registry.access.redhat.com/ubi9/ubi-micro:latest
COPY --from=builder /demo-http-server /demo-http-server
USER 65534
ENTRYPOINT ["/demo-http-server"]

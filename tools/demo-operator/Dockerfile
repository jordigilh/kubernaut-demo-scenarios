FROM golang:1.26-alpine AS builder

RUN apk add --no-cache git
WORKDIR /src
ARG GOPROXY=https://proxy.golang.org,direct
ENV GOPROXY=${GOPROXY}
COPY go.mod go.sum ./
RUN go mod download
COPY . .
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -ldflags="-s -w" -o /demo-operator .

FROM registry.access.redhat.com/ubi9/ubi-micro:latest
COPY --from=builder /demo-operator /demo-operator
USER 65534
ENTRYPOINT ["/demo-operator"]

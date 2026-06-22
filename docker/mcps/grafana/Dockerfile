FROM golang:1.26-alpine AS builder

RUN go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest

FROM alpine:3.19

COPY --from=builder /go/bin/mcp-grafana /usr/local/bin/mcp-grafana

EXPOSE 8080

# GRAFANA_URL and GRAFANA_API_KEY must be set via environment variables.
CMD ["mcp-grafana", "--transport", "sse", "--address", "0.0.0.0:8080"]

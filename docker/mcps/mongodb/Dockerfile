FROM node:20-slim

EXPOSE 3000

CMD ["npx", "-y", "mongodb-mcp-server@latest", \
     "--transport", "http", \
     "--httpHost", "0.0.0.0", \
     "--httpPort", "3000"]

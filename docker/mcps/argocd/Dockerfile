FROM node:20-slim

EXPOSE 3000

# ARGOCD_SERVER and ARGOCD_TOKEN must be set via environment variables.
CMD ["npx", "-y", "argocd-mcp@latest", "http"]

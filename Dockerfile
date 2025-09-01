# Use the official open-webui image as the base
FROM ghcr.io/open-webui/open-webui:main

# Copy the modified vite.config.ts into the container
COPY ./vite.config.ts /app/vite.config.ts

# Rebuild the frontend with the new base URL
RUN cd /app && \
    npm install && \
    npm run build

# Copy the built frontend to the static directory of the backend
RUN cp -r /app/build/. /app/backend/open_webui/static/

# The entrypoint and command are inherited from the base image,
# so we don't need to specify them again.
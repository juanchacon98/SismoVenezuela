# Usar la versión LTS de Node.js sobre Alpine Linux para reducir la superficie del contenedor
FROM node:20-alpine

# Instalar Python y Pip requeridos para el scraper inteligente con ScrapeGraphAI
RUN apk add --no-cache python3 py3-pip

# Pre-instalar dependencias de python en el sistema para evitar demoras y fallos en caliente (PEP 668 bypass)
RUN python3 -m pip install --no-cache-dir --break-system-packages scrapegraphai nest-asyncio langchain-google-genai langchain-google-vertexai

# Definir el directorio de trabajo
WORKDIR /app

# Copiar archivo de dependencias
COPY package.json ./

# Instalar solo las dependencias de producción
RUN npm install --omit=dev

# Copiar el código fuente, la base de datos y la carpeta del frontend
COPY index.js ./
COPY database/ ./database/
COPY frontend/ ./frontend/

# Exponer el puerto por defecto de Google Cloud Run
EXPOSE 8080

# Definir variable de entorno para producción
ENV NODE_ENV=production

# El comando de inicio ejecuta las migraciones antes de levantar el servidor Express
CMD ["sh", "-c", "npm run migrate && npm start"]

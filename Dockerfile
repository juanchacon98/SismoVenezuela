# Usar la versión LTS de Node.js sobre Alpine Linux para reducir la superficie del contenedor
FROM node:20-alpine

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
